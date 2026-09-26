/**
 * 传输引擎测试：命名规则、退避与自适应路数，以及对假电脑端的断点上传与分段下载（含断网、校验失败、过期、文件变化）。
 */
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/transfer/naming.dart';
import 'package:pocketdesk/transfer/policy.dart';
import 'package:pocketdesk/transfer/runners.dart';
import 'package:pocketdesk/transfer/task.dart';
import 'package:pocketdesk/transfer/tus.dart';

import '../support/fake_host.dart';

void main() {
  group('命名规则', () {
    test('非法字符与保留名', () {
      expect(sanitize('a:b*c?.txt'), 'a_b_c_.txt');
      expect(sanitize('dir/sub\\x.pdf'), 'x.pdf');
      expect(sanitize('CON.txt'), 'CON_.txt');
      expect(sanitize('name. '), 'name');
      expect(sanitize('...'), '_');
      expect(sanitize('.bashrc'), '.bashrc');
    });

    test('候选名与时间戳命名', () {
      expect(candidate('report.pdf', 0), 'report.pdf');
      expect(candidate('report.pdf', 2), 'report-2.pdf');
      expect(candidate('Makefile', 1), 'Makefile-1');
      final t = DateTime(2026, 10, 1, 9, 30, 15, 42);
      expect(dateFolder(t), '20261001');
      expect(timestampName(t, 'text/plain; charset=utf-8'), '20261001-093015-042.txt');
      expect(timestampName(t, 'image/png'), endsWith('.png'));
      expect(extForMime('application/x-zzz'), '.bin');
      expect(mimeForName('a.JPG'), 'image/jpeg');
    });

    test('重名不区分大小写且并发不覆盖', () async {
      final dir = await Directory.systemTemp.createTemp('pd-place');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/Report.PDF').writeAsString('old');
      final tmp = await File('${dir.path}/../pd-tmp-${DateTime.now().microsecondsSinceEpoch}').writeAsString('new');
      final placed = await placeFile(tmp, dir, 'report.pdf');
      expect(placed.path, endsWith('report-1.pdf'));
      expect(await File('${dir.path}/Report.PDF').readAsString(), 'old');
      final futures = <Future<File>>[];
      for (var i = 0; i < 20; i++) {
        final t = await File('${dir.path}/../pd-c-$i-${DateTime.now().microsecondsSinceEpoch}').writeAsString('$i');
        futures.add(placeFile(t, dir, 'name.txt'));
      }
      final names = (await Future.wait(futures)).map((f) => f.uri.pathSegments.last).toSet();
      expect(names.length, 20);
      expect(names, contains('name-19.txt'));
    });
  });

  group('传输策略', () {
    test('退避 2 秒起，最长 5 分钟', () {
      final b = Backoff();
      final seq = List.generate(10, (_) => b.next().inSeconds);
      expect(seq.take(5), [2, 4, 8, 16, 32]);
      expect(seq.last, 300);
      b.reset();
      expect(b.next().inSeconds, 2);
    });

    test('自适应路数', () {
      final l = LaneController();
      expect(l.allowed, 2);
      l.sample(100, 0);
      expect(l.sample(120, 0), 3, reason: '吞吐提升超过 10% 加一路');
      expect(l.sample(125, 0), 3, reason: '小幅增长时保持');
      expect(l.sample(125, 0), 2, reason: '吞吐不增时减一路');
      expect(l.sample(300, 1), 1, reason: '重试变多减一路');
      l.constrained = true;
      expect(l.allowed, 1);
      final m = LaneController(initial: 6);
      m.sample(100, 0);
      expect(m.sample(1000, 0), 6, reason: '最多 6 路');
    });

    test('弱网降块与恢复', () {
      final c = ChunkSizer();
      expect(c.size, TransferLimits.chunk);
      c.onResult(ok: false);
      c.onResult(ok: false);
      expect(c.size, TransferLimits.weakChunk);
      for (var i = 0; i < 5; i++) {
        c.onResult(ok: true, rate: 5e6);
      }
      expect(c.size, TransferLimits.chunk);
      c.onResult(ok: true, rate: 100 * 1024);
      expect(c.size, TransferLimits.weakChunk);
    });

    test('大于 64MB 才分段', () {
      expect(splitParts(10, 8), [(0, 10)]);
      final parts = splitParts(200 * 1024 * 1024, 8);
      expect(parts.length, 8);
      expect(parts.first.$1, 0);
      expect(parts.last.$2, 200 * 1024 * 1024);
      for (var i = 1; i < parts.length; i++) {
        expect(parts[i].$1, parts[i - 1].$2);
      }
    });
  });

  group('上传', () {
    late FakeHost host;
    late Directory dir;
    setUp(() async {
      host = FakeHost();
      await host.start();
      dir = await Directory.systemTemp.createTemp('pd-up');
    });
    tearDown(() async {
      await host.close();
      await dir.delete(recursive: true);
    });

    TransferTask newTask(File f, int size, {String name = 'a.bin'}) => TransferTask(
          id: 't1', hostId: 'h', direction: Direction.up, source: f.path, name: name, size: size,
          createdAt: 0, dateFolder: '20261001', target: 'assistant', mime: 'application/octet-stream');

    UploadRunner runner(TransferTask t, {List<String>? notices}) => UploadRunner(
          task: t,
          tus: TusClient(base: host.base, token: 'tok', client: HttpClient()),
          lanes: LaneController(),
          slots: Slots(8),
          hooks: Hooks(persist: () async {}, progress: () {}, notice: (m) => notices?.add(m)),
          flag: CancelFlag(),
        );

    test('断网后从服务端偏移续传，内容一致', () async {
      final data = randomBytes(3 * 1024 * 1024);
      final f = await File('${dir.path}/a.bin').writeAsBytes(data);
      final t = newTask(f, data.length);
      host.dropPatchAfter = 1024 * 1024;
      await expectLater(runner(t).run(), throwsA(isA<TusError>().having((e) => e.status, 'status', 0)));
      expect(t.remote, isNotEmpty);
      await runner(t).run();
      expect(t.result, 'a.bin');
      expect(host.completed['a.bin'], data);
    });

    test('校验失败自动重传本块', () async {
      final data = randomBytes(100000);
      final f = await File('${dir.path}/b.bin').writeAsBytes(data);
      host.checksumFailures = 2;
      final t = newTask(f, data.length, name: 'b.bin');
      await runner(t).run();
      expect(host.completed['b.bin'], data);
      expect(t.retries, 2);
    });

    test('上传过期后重新创建', () async {
      final data = randomBytes(5000);
      final f = await File('${dir.path}/c.bin').writeAsBytes(data);
      final t = newTask(f, data.length, name: 'c.bin');
      t.remote = host.base.resolve('/files/expired').toString();
      await runner(t).run();
      expect(host.completed['c.bin'], data);
    });

    test('源文件在传输期间被修改则从头重传并提示', () async {
      final f = await File('${dir.path}/d.bin').writeAsBytes(randomBytes(4000));
      final t = newTask(f, 4000, name: 'd.bin');
      host.dropPatchAfter = 100;
      await expectLater(runner(t).run(), throwsA(isA<TusError>()));
      final changed = randomBytes(4000, 99);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await f.writeAsBytes(changed);
      final notices = <String>[];
      await runner(t, notices: notices).run();
      expect(host.completed['d.bin'], changed);
      expect(notices.single, contains('被修改'));
    });

    test('大文件分段并行上传后拼接', () async {
      final data = randomBytes(70 * 1024 * 1024);
      final f = await File('${dir.path}/big.bin').writeAsBytes(data);
      final t = newTask(f, data.length, name: 'big.bin');
      await runner(t).run();
      expect(t.parts.length, greaterThan(1));
      expect(host.maxConcurrentPatch, greaterThanOrEqualTo(2), reason: '应至少 2 路并行');
      expect(host.completed['big.bin']!.length, data.length);
      expect(host.completed['big.bin'], data);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('空文件', () async {
      final f = await File('${dir.path}/empty.txt').writeAsBytes([]);
      final t = newTask(f, 0, name: 'empty.txt');
      await runner(t).run();
      expect(t.result, 'empty.txt');
    });
  });

  group('下载', () {
    late FakeHost host;
    late Directory dir;
    setUp(() async {
      host = FakeHost();
      await host.start();
      dir = await Directory.systemTemp.createTemp('pd-dl');
    });
    tearDown(() async {
      await host.close();
      await dir.delete(recursive: true);
    });

    DownloadRunner runner(TransferTask t, {String sha = '', List<String>? notices}) => DownloadRunner(
          task: t,
          source: RangeSource(url: host.base.resolve('/dl/${t.name}'), headers: const {}, sha256: sha),
          client: HttpClient(),
          temp: File('${dir.path}/${t.id}.part'),
          lanes: LaneController(),
          slots: Slots(8),
          hooks: Hooks(persist: () async {}, progress: () {}, notice: (m) => notices?.add(m)),
          flag: CancelFlag(),
        );

    TransferTask newTask(String name, int size) => TransferTask(id: 'd1', hostId: 'h', direction: Direction.down, source: 'outbox:1', name: name, size: size, createdAt: 0, dateFolder: '20261001');

    test('断线后用 Range 续传并校验', () async {
      final data = randomBytes(2 * 1024 * 1024);
      host.files['x.bin'] = data;
      final t = newTask('x.bin', data.length);
      host.dropDownloadAfter = 500000;
      final sha = await sha256File(await File('${dir.path}/src').writeAsBytes(data));
      await expectLater(runner(t, sha: sha).run(), throwsA(isA<TusError>()));
      expect(t.doneBytes, greaterThan(0));
      final out = await runner(t, sha: sha).run();
      expect(await out.readAsBytes(), data);
      expect(host.rangeRequests, greaterThanOrEqualTo(2));
    });

    test('电脑上的文件变化时从头下载', () async {
      final data = randomBytes(300000);
      host.files['y.bin'] = data;
      final t = newTask('y.bin', data.length);
      host.dropDownloadAfter = 100000;
      await expectLater(runner(t).run(), throwsA(isA<TusError>()));
      final changed = randomBytes(300000, 5);
      host.files['y.bin'] = changed;
      final out = await runner(t).run();
      expect(await out.readAsBytes(), changed);
    });

    test('整文件校验失败重下一次后报错', () async {
      host.files['z.bin'] = randomBytes(1000);
      final t = newTask('z.bin', 1000);
      final notices = <String>[];
      await expectLater(runner(t, sha: 'bad', notices: notices).run(), throwsA(isA<TransferFailure>()));
      expect(notices.single, contains('校验失败'));
    });

    test('大文件分段并行下载', () async {
      final data = randomBytes(70 * 1024 * 1024, 3);
      host.files['big.bin'] = data;
      final t = newTask('big.bin', data.length);
      final out = await runner(t).run();
      expect(t.parts.length, greaterThan(1));
      expect(await out.length(), data.length);
      expect(await out.readAsBytes(), data);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
