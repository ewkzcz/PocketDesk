/**
 * 传输执行：上传（大文件分段并行后拼接、弱网降块、源文件变化从头重传）与下载（Range 续传、分段并行、整文件校验）。
 */
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'policy.dart';
import 'task.dart';
import 'tus.dart';

/** CancelFlag：取消或暂停标记 */
class CancelFlag {
  bool canceled = false;
  bool paused = false;

  bool get stop => canceled || paused;
}

/** TransferFailure：不可自动恢复的失败（直接标记失败） */
class TransferFailure implements Exception {
  TransferFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/** Slots：所有文件合计的连接数上限 */
class Slots {
  Slots(this.limit);

  int limit;
  int _used = 0;
  final _waiters = <Completer<void>>[];

  /** acquire：取得一个连接名额 */
  Future<void> acquire() async {
    while (_used >= limit) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _used++;
  }

  /** release：归还名额 */
  void release() {
    _used = max(0, _used - 1);
    if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
  }
}

/** Hooks：执行过程中的回调 */
class Hooks {
  Hooks({required this.persist, required this.progress, this.notice});

  /** 保存任务与分段 */
  final Future<void> Function() persist;

  /** 进度变化 */
  final void Function() progress;

  /** 提示用户（如源文件已修改） */
  final void Function(String msg)? notice;
}

/**
 * UploadRunner：执行一次上传
 */
class UploadRunner {
  UploadRunner({required this.task, required this.tus, required this.lanes, required this.slots, required this.hooks, required this.flag});

  final TransferTask task;
  final TusClient tus;
  final LaneController lanes;
  final Slots slots;
  final Hooks hooks;
  final CancelFlag flag;
  final ChunkSizer _sizer = ChunkSizer();
  int _sentInPeriod = 0;

  /** meta：上传元数据；无名数据不传 filename，由电脑端按时间戳命名 */
  Map<String, String> get _meta => {
        if (!task.name.startsWith('\u0000')) 'filename': task.name,
        'filetype': task.mime,
        'target': task.target,
        'date': task.dateFolder,
        'sha256': task.sha256,
      };

  /**
   * run：执行上传直到完成、取消或遇到需要退避的网络错误
   *
   * 处理流程：
   * 1、检查源文件与指纹，变化则作废旧上传从头开始
   * 2、首次计算整文件 SHA-256
   * 3、小文件单路按块上传，大文件切段并行后拼接
   */
  Future<void> run() async {
    // 1、源文件与指纹
    final f = File(task.source);
    if (!await f.exists()) throw TransferFailure('源文件不存在');
    final fp = await fileFingerprint(f);
    if (task.fingerprint.isNotEmpty && task.fingerprint != fp) {
      await _discardRemote();
      hooks.notice?.call('「${task.name}」在传输期间被修改，已从头重传');
    }
    task.fingerprint = fp;
    // 2、整文件哈希
    if (task.sha256.isEmpty) task.sha256 = await sha256File(f);
    await hooks.persist();
    // 3、上传
    if (task.size > TransferLimits.splitAbove) {
      await _runParts(f);
    } else {
      await _runSingle(f);
    }
  }

  /** _discardRemote：作废服务端已有的上传与分段记录 */
  Future<void> _discardRemote() async {
    for (final u in [task.remote, ...task.parts.map((p) => p.url)]) {
      if (u.isEmpty) continue;
      try {
        await tus.terminate(Uri.parse(u));
      } on TusError {
        // 旧上传可能已过期，忽略
      }
    }
    task.remote = '';
    task.parts = [];
    task.doneBytes = 0;
    task.sha256 = '';
  }

  /**
   * _runSingle：单路上传
   *
   * 处理流程：
   * 1、没有上传地址时创建
   * 2、查询服务端偏移，从断点继续
   * 3、按块上传；上传不存在时重新创建，校验失败重传本块
   */
  Future<void> _runSingle(File f) async {
    final raf = await f.open();
    try {
      while (true) {
        // 1、创建
        if (task.remote.isEmpty) {
          task.remote = (await tus.create(task.size, _meta)).toString();
          task.doneBytes = 0;
          await hooks.persist();
        }
        // 2、偏移
        int offset;
        try {
          final st = await tus.offset(Uri.parse(task.remote));
          offset = st.offset;
          if (st.name.isNotEmpty) {
            task.result = st.name;
            task.doneBytes = task.size;
            return;
          }
        } on TusError catch (e) {
          if (e.gone) {
            task.remote = '';
            continue;
          }
          rethrow;
        }
        task.doneBytes = offset;
        hooks.progress();
        // 3、按块上传
        final done = await _uploadRange(raf, Uri.parse(task.remote), 0, task.size, offset, (n) {
          task.doneBytes = n;
          hooks.progress();
        });
        if (done == null) {
          task.remote = '';
          continue;
        }
        task.result = done.name;
        task.doneBytes = task.size;
        return;
      }
    } finally {
      await raf.close();
    }
  }

  /**
   * _uploadRange：上传文件 [start, end) 区间，服务端已收 offset 字节
   *
   * 处理流程：
   * 1、空区间或已收齐时直接查询结果
   * 2、按当前块大小读取并上传，记录速度供弱网降块
   * 3、校验失败重传本块（最多 3 次），偏移不一致先查询，上传不存在返回 null 由调用方重建
   */
  Future<PatchResult?> _uploadRange(RandomAccessFile raf, Uri url, int start, int end, int offset, void Function(int confirmed) onConfirmed) async {
    // 1、已收齐
    final len = end - start;
    var off = offset;
    if (len == 0 || off >= len) return tus.offset(url);
    var last = PatchResult(off);
    var checksumFails = 0;
    // 2、按块上传
    while (off < len) {
      if (flag.stop) throw const _Stopped();
      final n = min(_sizer.size, len - off);
      await raf.setPosition(start + off);
      final chunk = await raf.read(n);
      final began = DateTime.now();
      final base = off;
      await slots.acquire();
      try {
        last = await tus.patch(url, off, chunk, onProgress: (sent) => onConfirmed(base + sent));
        final secs = DateTime.now().difference(began).inMilliseconds / 1000;
        _sizer.onResult(ok: true, rate: secs > 0 ? n / secs : 0);
        _sentInPeriod += n;
        off = last.offset;
        onConfirmed(off);
        checksumFails = 0;
      } on TusError catch (e) {
        // 3、错误处理
        _sizer.onResult(ok: false);
        task.retries++;
        onConfirmed(base);
        if (e.gone) return null;
        if (e.checksum && ++checksumFails < 3) continue;
        if (e.conflict) {
          off = (await tus.offset(url)).offset;
          onConfirmed(off);
          continue;
        }
        rethrow;
      } finally {
        slots.release();
      }
    }
    return last;
  }

  /**
   * _runParts：大文件分段并行上传
   *
   * 处理流程：
   * 1、首次切成 8 段并各自创建分段上传
   * 2、按自适应路数启动工作协程，每 10 秒评估一次吞吐调整路数
   * 3、某段连续失败 5 次则整体失败；全部完成后发起拼接
   */
  Future<void> _runParts(File f) async {
    // 1、分段
    if (task.parts.isEmpty) {
      var i = 0;
      task.parts = [for (final r in splitParts(task.size, 8)) Part(index: i++, start: r.$1, end: r.$2)];
      await hooks.persist();
    }
    // 2、工作协程（每个分段各自打开文件，RandomAccessFile 不支持并发读取）
    var active = 0;
    Object? fatal;
    final allDone = Completer<void>();
    late void Function() spawn;
    final timer = Timer.periodic(const Duration(seconds: 10), (_) {
      lanes.sample(_sentInPeriod / 10, task.retries);
      _sentInPeriod = 0;
      task.lanes = lanes.allowed;
      spawn();
    });
    void finish() {
      if (!allDone.isCompleted) allDone.complete();
    }

    spawn = () {
      while (active < lanes.allowed && fatal == null && !flag.stop) {
        final next = task.parts.where((p) => !p.done && p.status != TaskStatus.running).firstOrNull;
        if (next == null) break;
        active++;
        next.status = TaskStatus.running;
        _runPart(f, next).then((_) {
          next.status = TaskStatus.done;
        }).catchError((Object e) {
          next.status = TaskStatus.queued;
          if (e is _Stopped) return;
          if (e is TusError && e.status == 0) {
            fatal ??= e;
            return;
          }
          if (++next.fails >= TransferLimits.partFailLimit) {
            fatal ??= TransferFailure('第 ${next.index + 1} 段连续失败 ${TransferLimits.partFailLimit} 次');
          }
        }).whenComplete(() async {
          active--;
          task.lanes = active;
          await hooks.persist();
          if (task.parts.every((p) => p.done) || ((fatal != null || flag.stop) && active == 0)) {
            finish();
          } else {
            spawn();
          }
        });
      }
      task.lanes = active;
      if (active == 0 && (task.parts.every((p) => p.done) || fatal != null || flag.stop)) finish();
    };
    spawn();
    try {
      await allDone.future;
    } finally {
      timer.cancel();
    }
    if (flag.stop) throw const _Stopped();
    if (fatal != null) throw fatal!;
    // 3、拼接
    final res = await tus.concat(task.parts.map((p) => Uri.parse(p.url)).toList(), _meta);
    task.result = res.name;
    task.doneBytes = task.size;
  }

  /** _runPart：上传一个分段 */
  Future<void> _runPart(File f, Part p) async {
    final raf = await f.open();
    try {
      await _runPartWith(raf, p);
    } finally {
      await raf.close();
    }
  }

  /** _runPartWith：用独立的文件句柄上传一个分段 */
  Future<void> _runPartWith(RandomAccessFile raf, Part p) async {
    while (true) {
      if (p.url.isEmpty) {
        p.url = (await tus.create(p.length, const {}, partial: true)).toString();
        p.confirmed = 0;
        await hooks.persist();
      }
      try {
        p.confirmed = (await tus.offset(Uri.parse(p.url))).offset;
      } on TusError catch (e) {
        if (e.gone) {
          p.url = '';
          continue;
        }
        rethrow;
      }
      final res = await _uploadRange(raf, Uri.parse(p.url), p.start, p.end, p.confirmed, (n) {
        p.confirmed = n;
        task.doneBytes = task.parts.fold(0, (s, x) => s + x.confirmed);
        hooks.progress();
      });
      if (res == null) {
        p.url = '';
        continue;
      }
      p.confirmed = p.length;
      p.fails = 0;
      return;
    }
  }
}

/** _Stopped：暂停或取消 */
class _Stopped implements Exception {
  const _Stopped();
}

/** isStopped：判断是否为暂停或取消 */
bool isStopped(Object e) => e is _Stopped;

/** RangeSource：下载源 */
class RangeSource {
  const RangeSource({required this.url, required this.headers, this.sha256 = ''});

  final Uri url;
  final Map<String, String> headers;
  final String sha256;
}

/**
 * DownloadRunner：执行一次下载（写入预分配的临时文件）
 */
class DownloadRunner {
  DownloadRunner({required this.task, required this.source, required this.client, required this.temp, required this.lanes, required this.slots, required this.hooks, required this.flag});

  final TransferTask task;
  final RangeSource source;
  final HttpClient client;
  final File temp;
  final LaneController lanes;
  final Slots slots;
  final Hooks hooks;
  final CancelFlag flag;
  int _sentInPeriod = 0;

  /** 下载时 remote 字段保存文件的 ETag，重新开始任务后续传仍能带上 If-Range */
  String get _etag => task.remote;
  set _etag(String v) => task.remote = v;

  /**
   * run：下载到临时文件并校验，返回临时文件
   *
   * 处理流程：
   * 1、准备预分配的临时文件与分段
   * 2、按自适应路数并行下载各段，Range 续传并带 If-Range
   * 3、文件在电脑上被修改（返回 200）时从头下载
   * 4、校验整文件 SHA-256，失败删除临时文件重下一次
   */
  Future<File> run() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      // 1、准备
      if (task.parts.isEmpty || !await temp.exists()) {
        await temp.parent.create(recursive: true);
        final raf = await temp.open(mode: FileMode.write);
        await raf.truncate(task.size);
        await raf.close();
        var i = 0;
        task.parts = [for (final r in splitParts(task.size, 8)) Part(index: i++, start: r.$1, end: r.$2)];
        task.doneBytes = 0;
        _etag = '';
        await hooks.persist();
      }
      // 2、3、下载
      final restarted = await _download();
      if (restarted) {
        attempt--;
        continue;
      }
      // 4、校验
      final want = source.sha256.isNotEmpty ? source.sha256 : task.sha256;
      if (want.isEmpty || await sha256File(temp) == want) return temp;
      await temp.delete();
      task.parts = [];
      _etag = '';
      if (attempt == 0) hooks.notice?.call('「${task.name}」校验失败，正在重新下载');
    }
    throw TransferFailure('整文件校验失败');
  }

  /** _download：下载全部分段，文件变化时返回 true */
  Future<bool> _download() async {
    var restart = false;
    Object? fatal;
    var active = 0;
    final done = Completer<void>();
    final timer = Timer.periodic(const Duration(seconds: 10), (_) {
      lanes.sample(_sentInPeriod / 10, task.retries);
      _sentInPeriod = 0;
    });
    late void Function() spawn;
    spawn = () {
      while (active < lanes.allowed && fatal == null && !restart && !flag.stop) {
        final next = task.parts.where((p) => !p.done && p.status != TaskStatus.running).firstOrNull;
        if (next == null) break;
        active++;
        next.status = TaskStatus.running;
        _segment(next).then((changed) {
          next.status = TaskStatus.done;
          if (changed) restart = true;
        }).catchError((Object e) {
          next.status = TaskStatus.queued;
          if (e is _Stopped) return;
          if (++next.fails >= TransferLimits.partFailLimit || (e is TusError && e.status == 0)) fatal ??= e;
        }).whenComplete(() async {
          active--;
          task.lanes = active;
          await hooks.persist();
          if (active == 0 && (task.parts.every((p) => p.done) || fatal != null || restart || flag.stop)) {
            if (!done.isCompleted) done.complete();
          } else {
            spawn();
          }
        });
      }
      task.lanes = active;
      if (active == 0 && !done.isCompleted && (task.parts.every((p) => p.done) || fatal != null || restart || flag.stop)) done.complete();
    };
    spawn();
    await done.future;
    timer.cancel();
    if (restart) {
      await temp.delete();
      task.parts = [];
      _etag = '';
      return true;
    }
    if (flag.stop) throw const _Stopped();
    if (fatal != null) throw fatal!;
    return false;
  }

  /**
   * _segment：下载一段，返回文件是否已被修改
   */
  Future<bool> _segment(Part p) async {
    await slots.acquire();
    RandomAccessFile? raf;
    try {
      final req = await client.getUrl(source.url);
      source.headers.forEach(req.headers.set);
      req.headers.set('Range', 'bytes=${p.start + p.confirmed}-${p.end - 1}');
      if (_etag.isNotEmpty) req.headers.set('If-Range', _etag);
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode == 200 && (p.start + p.confirmed > 0 || p.end < task.size)) {
        await res.drain<void>();
        return true;
      }
      if (res.statusCode != 206 && res.statusCode != 200) {
        await res.drain<void>();
        throw TusError(res.statusCode, '下载失败（${res.statusCode}）');
      }
      _etag = res.headers.value('etag') ?? _etag;
      raf = await temp.open(mode: FileMode.append);
      var pos = p.start + p.confirmed;
      await for (final data in res.timeout(const Duration(seconds: 60))) {
        if (flag.stop) throw const _Stopped();
        await raf.setPosition(pos);
        await raf.writeFrom(data);
        pos += data.length;
        p.confirmed += data.length;
        _sentInPeriod += data.length;
        task.doneBytes = task.parts.fold(0, (s, x) => s + x.confirmed);
        hooks.progress();
      }
      if (!p.done) throw TusError(0, '连接中断');
      return false;
    } on SocketException catch (e) {
      task.retries++;
      throw TusError(0, '网络中断：${e.message}');
    } on HttpException catch (e) {
      task.retries++;
      throw TusError(0, '网络中断：${e.message}');
    } on TimeoutException {
      task.retries++;
      throw TusError(0, '连接超时');
    } finally {
      await raf?.close();
      slots.release();
    }
  }
}
