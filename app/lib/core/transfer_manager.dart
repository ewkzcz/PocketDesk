/**
 * 传输队列：持久化任务、并发调度（小文件快速通道）、断网退避重试、仅 Wi-Fi 与低电量暂停、自动接收电脑发来的文件。
 */
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/local_db.dart';
import '../net/api.dart';
import '../transfer/naming.dart' as naming;
import '../transfer/policy.dart';
import '../transfer/runners.dart';
import '../transfer/task.dart';
import '../transfer/tus.dart';
import 'connection.dart';

/** FileSaver：下载完成后保存到手机的位置 */
abstract class FileSaver {
  /** save：把临时文件存到日期文件夹，返回最终路径 */
  Future<String> save(File temp, String dateFolder, String name);
}

/** DirSaver：保存到指定根目录下的 YYYYMMDD 子文件夹 */
class DirSaver implements FileSaver {
  DirSaver(this.root);

  final Future<Directory> Function() root;

  @override
  Future<String> save(File temp, String dateFolder, String name) async {
    final dir = Directory('${(await root()).path}${Platform.pathSeparator}$dateFolder');
    return (await naming.placeFile(temp, dir, name)).path;
  }
}

/** NetState：网络与电量条件 */
class NetState {
  const NetState({this.wifi = true, this.online = true, this.lowBattery = false, this.powerSave = false});

  final bool wifi;
  final bool online;
  final bool lowBattery;
  final bool powerSave;
}

/** QueueOptions：队列相关设置 */
class QueueOptions {
  const QueueOptions({this.concurrency = 3, this.wifiOnly = false, this.pauseOnLowBattery = true, this.autoReceive = true});

  final int concurrency;
  final bool wifiOnly;
  final bool pauseOnLowBattery;
  final bool autoReceive;
}

/**
 * TransferManager：一台电脑的传输队列
 */
class TransferManager extends ChangeNotifier {
  TransferManager({required this.db, required this.hostId, required this.conn, required this.saver, required this.tempDir, required this.options});

  final LocalDb db;
  final String hostId;
  final HostConnection conn;
  final FileSaver saver;
  final Future<Directory> Function() tempDir;
  QueueOptions Function() options;

  final List<TransferTask> tasks = [];
  final Map<String, CancelFlag> _running = {};
  final Map<String, Backoff> _backoff = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, Completer<TransferTask>> _waiters = {};
  final Slots _slots = Slots(TransferLimits.maxConnections);
  NetState net = const NetState();
  String notice = '';
  Timer? _poll;
  bool _polling = false;
  int _seq = 0;
  final _rand = Random();

  /** active / done：进行中与已完成（新的在前） */
  List<TransferTask> get active => tasks.where((t) => t.active).toList();
  List<TransferTask> get done => tasks.where((t) => t.status == TaskStatus.done).toList();

  /** blockedReason：整体暂停的原因，空表示可以传输 */
  String get blockedReason {
    final o = options();
    if (!net.online) return '网络不可用';
    if (o.wifiOnly && !net.wifi) return '等待 Wi-Fi';
    if (o.pauseOnLowBattery && net.lowBattery) return '电量低，已暂停';
    if (!conn.hasApi) return '等待电脑在线';
    return '';
  }

  /**
   * load：恢复任务，运行中的恢复为排队，清理 7 天前的失败任务
   */
  Future<void> load() async {
    final week = DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    for (final id in await db.purgeFailed(week)) {
      final f = File('${(await tempDir()).path}${Platform.pathSeparator}$id.part');
      if (await f.exists()) await f.delete();
    }
    for (final row in await db.transfers(hostId)) {
      final t = TransferTask.fromRow(row);
      t.parts = (await db.parts(t.id)).map(Part.fromRow).toList();
      tasks.add(t);
    }
    notifyListeners();
    pump();
  }

  /** _newId：任务 ID */
  String _newId() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}${_rand.nextInt(1 << 20).toRadixString(36)}';

  /**
   * upload：登记上传任务
   *
   * name 为空表示无名数据（分享的纯文本、剪贴板图片），由电脑端按时间戳命名
   */
  Future<TransferTask> upload(String path, {String name = '', String mime = '', String target = 'inbox'}) async {
    final f = File(path);
    final size = await f.length();
    final now = DateTime.now();
    final displayName = name.isEmpty ? naming.timestampName(now, mime.isEmpty ? 'application/octet-stream' : mime) : name;
    final t = TransferTask(
      id: _newId(),
      hostId: hostId,
      direction: Direction.up,
      source: path,
      name: name.isEmpty ? '\u0000$displayName' : name,
      size: size,
      createdAt: now.millisecondsSinceEpoch,
      dateFolder: naming.dateFolder(now),
      target: target,
      mime: mime.isEmpty ? naming.mimeForName(displayName) : mime,
    );
    tasks.insert(0, t);
    await _persist(t);
    notifyListeners();
    pump();
    return t;
  }

  /** download：登记下载任务；source 为 outbox:ID 或 ws:工作区:路径 */
  Future<TransferTask> download(String source, String name, int size, {String sha = ''}) async {
    final existing = tasks.where((t) => t.source == source && t.status != TaskStatus.canceled && t.status != TaskStatus.failed).firstOrNull;
    if (existing != null) return existing;
    final now = DateTime.now();
    final t = TransferTask(id: _newId(), hostId: hostId, direction: Direction.down, source: source, name: name, size: size, createdAt: now.millisecondsSinceEpoch, dateFolder: naming.dateFolder(now), sha256: sha);
    tasks.insert(0, t);
    await _persist(t);
    notifyListeners();
    pump();
    return t;
  }

  /** wait：等待某个任务结束（上传附件后取得路径） */
  Future<TransferTask> wait(TransferTask t) {
    if (t.status == TaskStatus.done || t.status == TaskStatus.failed || t.status == TaskStatus.canceled) return Future.value(t);
    return (_waiters[t.id] ??= Completer<TransferTask>()).future;
  }

  /** displayName：去掉无名数据标记后的名字 */
  static String displayName(TransferTask t) => t.name.startsWith('\u0000') ? t.name.substring(1) : t.name;

  /**
   * pump：按并发上限启动排队中的任务
   *
   * 处理流程：
   * 1、整体暂停时把排队任务标记为等待
   * 2、普通任务不超过并发上限，小于 8MB 的任务额外占用一个快速通道
   */
  void pump() {
    // 1、暂停条件
    final reason = blockedReason;
    if (reason.isNotEmpty) {
      for (final t in tasks.where((t) => t.status == TaskStatus.queued)) {
        t.status = TaskStatus.waiting;
        t.error = reason;
      }
      notifyListeners();
      return;
    }
    // 2、调度
    final limit = options().concurrency;
    for (final t in tasks.reversed.where((t) => t.status == TaskStatus.queued || (t.status == TaskStatus.waiting && !_retryTimers.containsKey(t.id))).toList()) {
      final running = tasks.where((x) => x.status == TaskStatus.running).toList();
      final big = running.where((x) => x.size >= TransferLimits.fastLane).length;
      final small = running.length - big;
      final isSmall = t.size < TransferLimits.fastLane;
      final ok = isSmall ? (running.length < limit || small < 1) : big < limit && running.length < limit + 1;
      if (!ok) continue;
      unawaited(_run(t));
    }
  }

  /**
   * _run：执行一个任务
   *
   * 处理流程：
   * 1、标记运行并准备进度回调
   * 2、上传或下载
   * 3、成功：记录结果，下载确认收到；网络问题：退避重试；其他失败：标记失败
   */
  Future<void> _run(TransferTask t) async {
    // 1、准备
    final flag = CancelFlag();
    _running[t.id] = flag;
    t.status = TaskStatus.running;
    t.error = '';
    notifyListeners();
    final hooks = _hooks(t);
    final lanes = LaneController()..constrained = !net.wifi || net.powerSave;
    try {
      // 2、执行
      if (t.direction == Direction.up) {
        await UploadRunner(task: t, tus: conn.tus(), lanes: lanes, slots: _slots, hooks: hooks, flag: flag).run();
      } else {
        await _download(t, lanes, hooks, flag);
      }
      // 3、成功
      t.status = TaskStatus.done;
      t.finishedAt = DateTime.now().millisecondsSinceEpoch;
      t.speed = 0;
      _backoff.remove(t.id);
    } catch (e) {
      if (isStopped(e)) {
        t.status = flag.canceled ? TaskStatus.canceled : TaskStatus.paused;
      } else if (_retryable(e)) {
        _scheduleRetry(t, e is TusError && e.paused ? '电脑端已暂停传输' : '等待电脑在线');
      } else {
        t.status = TaskStatus.failed;
        t.error = e.toString();
      }
    } finally {
      _running.remove(t.id);
      t.lanes = 0;
      if (flag.canceled) {
        // 已被取消：不再写回数据库，避免重启后任务重新出现
        t.status = TaskStatus.canceled;
        await db.deleteTransfer(t.id);
      } else {
        await _persist(t);
      }
      if (t.status == TaskStatus.done || t.status == TaskStatus.failed || t.status == TaskStatus.canceled) {
        _waiters.remove(t.id)?.complete(t);
      }
      notifyListeners();
      pump();
    }
  }

  /** _retryable：网络中断、电脑离线或电脑端暂停时可自动重试 */
  static bool _retryable(Object e) =>
      (e is TusError && (e.status == 0 || e.paused || e.status >= 500)) || (e is ApiException && (e.offline || e.status >= 500)) || e is SocketException;

  /** _scheduleRetry：指数退避后重试 */
  void _scheduleRetry(TransferTask t, String reason) {
    final b = _backoff[t.id] ??= Backoff();
    final wait = b.next();
    t.status = TaskStatus.waiting;
    t.error = reason;
    t.speed = 0;
    _retryTimers[t.id]?.cancel();
    _retryTimers[t.id] = Timer(wait, () {
      _retryTimers.remove(t.id);
      if (t.status == TaskStatus.waiting) {
        t.status = TaskStatus.queued;
        pump();
      }
    });
  }

  /** _hooks：保存、进度与速度统计 */
  Hooks _hooks(TransferTask t) {
    var lastBytes = t.doneBytes;
    var lastAt = DateTime.now();
    var lastSave = DateTime.now();
    return Hooks(
      persist: () => _persist(t),
      progress: () {
        final now = DateTime.now();
        final ms = now.difference(lastAt).inMilliseconds;
        if (ms >= 1000) {
          final rate = (t.doneBytes - lastBytes) * 1000 / ms;
          t.speed = t.speed == 0 ? rate : t.speed * 0.6 + rate * 0.4;
          lastBytes = t.doneBytes;
          lastAt = now;
          notifyListeners();
        }
        if (now.difference(lastSave).inSeconds >= 2) {
          lastSave = now;
          unawaited(_persist(t));
        }
      },
      notice: (m) {
        notice = m;
        notifyListeners();
      },
    );
  }

  /**
   * _download：下载到临时文件、保存到手机、电脑发来的文件确认收到
   */
  Future<void> _download(TransferTask t, LaneController lanes, Hooks hooks, CancelFlag flag) async {
    final api = conn.api;
    final src = t.source;
    final Uri url;
    if (src.startsWith('outbox:')) {
      url = api.outboxUrl(src.substring(7));
    } else {
      final rest = src.substring(3);
      final i = rest.indexOf(':');
      url = api.fileUrl(rest.substring(0, i), rest.substring(i + 1));
    }
    final temp = File('${(await tempDir()).path}${Platform.pathSeparator}${t.id}.part');
    final file = await DownloadRunner(
      task: t,
      source: RangeSource(url: url, headers: api.headers(), sha256: t.sha256),
      client: conn.httpClient(),
      temp: temp,
      lanes: lanes,
      slots: _slots,
      hooks: hooks,
      flag: flag,
    ).run();
    t.result = await saver.save(file, t.dateFolder, t.name);
    if (src.startsWith('outbox:')) await api.ackOutbox(src.substring(7));
  }

  /** _persist：保存任务与分段 */
  Future<void> _persist(TransferTask t) async {
    await db.saveTransfer(t.toRow());
    if (t.parts.isNotEmpty) await db.saveParts(t.id, t.parts.map((p) => p.toRow()).toList());
  }

  /** pause：暂停 */
  void pause(TransferTask t) {
    final f = _running[t.id];
    if (f != null) {
      f.paused = true;
    } else if (t.status == TaskStatus.queued || t.status == TaskStatus.waiting) {
      _retryTimers.remove(t.id)?.cancel();
      t.status = TaskStatus.paused;
      unawaited(_persist(t));
    }
    notifyListeners();
  }

  /** resume：继续或重试 */
  void resume(TransferTask t) {
    if (t.status == TaskStatus.paused || t.status == TaskStatus.failed || t.status == TaskStatus.waiting) {
      _retryTimers.remove(t.id)?.cancel();
      _backoff.remove(t.id);
      t.status = TaskStatus.queued;
      t.error = '';
      notifyListeners();
      pump();
    }
  }

  /**
   * cancel：取消并清理（上传终止服务端临时文件，下载删除临时文件）
   */
  Future<void> cancel(TransferTask t) async {
    final f = _running[t.id];
    if (f != null) f.canceled = true;
    _retryTimers.remove(t.id)?.cancel();
    t.status = TaskStatus.canceled;
    tasks.remove(t);
    notifyListeners();
    if (t.direction == Direction.up && conn.hasApi) {
      final tus = conn.tus();
      for (final u in [t.remote, ...t.parts.map((p) => p.url)].where((u) => u.isNotEmpty)) {
        unawaited(tus.terminate(Uri.parse(u)).catchError((Object _) {}));
      }
    } else {
      final temp = File('${(await tempDir()).path}${Platform.pathSeparator}${t.id}.part');
      if (await temp.exists()) await temp.delete();
    }
    await db.deleteTransfer(t.id);
    _waiters.remove(t.id)?.complete(t);
  }

  /** clearDone：清空已完成记录 */
  Future<void> clearDone() async {
    for (final t in done) {
      await db.deleteTransfer(t.id);
    }
    tasks.removeWhere((t) => t.status == TaskStatus.done);
    notifyListeners();
  }

  /**
   * setNet：网络或电量变化后重新调度，移动网络降为单路
   */
  void setNet(NetState s) {
    final wasBlocked = blockedReason.isNotEmpty;
    net = s;
    final blocked = blockedReason;
    if (blocked.isNotEmpty) {
      for (final f in _running.values) {
        f.paused = true;
      }
      for (final t in tasks.where((t) => t.status == TaskStatus.queued)) {
        t.status = TaskStatus.waiting;
        t.error = blocked;
      }
    } else if (wasBlocked) {
      for (final t in tasks.where((t) => t.status == TaskStatus.waiting || (t.status == TaskStatus.paused && t.error.isNotEmpty))) {
        t.status = TaskStatus.queued;
        t.error = '';
      }
    }
    notifyListeners();
    pump();
  }

  /** onConnected：电脑在线后恢复等待中的任务并检查收件 */
  void onConnected() {
    for (final t in tasks.where((t) => t.status == TaskStatus.waiting)) {
      _retryTimers.remove(t.id)?.cancel();
      t.status = TaskStatus.queued;
    }
    pump();
    unawaited(pollOutbox());
    _poll ??= Timer.periodic(const Duration(minutes: 15), (_) => pollOutbox());
  }

  /**
   * pollOutbox：检查电脑待发文件，开启自动接收时加入下载队列
   */
  Future<List<String>> pollOutbox() async {
    if (_polling || !conn.hasApi) return const [];
    _polling = true;
    try {
      final items = await conn.api.outbox();
      if (!options().autoReceive) return items.map((e) => e.id).toList();
      for (final it in items) {
        await download('outbox:${it.id}', it.name, it.size, sha: it.sha256);
      }
      return items.map((e) => e.id).toList();
    } on ApiException {
      return const [];
    } finally {
      _polling = false;
    }
  }

  /** clearNotice：清除提示 */
  void clearNotice() {
    notice = '';
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    for (final t in _retryTimers.values) {
      t.cancel();
    }
    for (final f in _running.values) {
      f.paused = true;
    }
    super.dispose();
  }
}
