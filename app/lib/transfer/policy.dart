/**
 * 传输策略：文件指纹、指数退避、自适应并行路数与弱网分块大小。
 */
library;

import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/** 分块与分段常量 */
abstract final class TransferLimits {
  static const chunk = 8 * 1024 * 1024;
  static const weakChunk = 1024 * 1024;
  static const splitAbove = 64 * 1024 * 1024;
  static const fastLane = 8 * 1024 * 1024;
  static const maxLanesPerFile = 6;
  static const maxConnections = 8;
  static const partFailLimit = 5;
}

/**
 * fileFingerprint：大小 + 修改时间 + 首尾各 1MB 的哈希，用于判断源文件在传输期间是否被修改
 */
Future<String> fileFingerprint(File f) async {
  final stat = await f.stat();
  final raf = await f.open();
  try {
    const n = 1024 * 1024;
    final head = await raf.read(min(n, stat.size));
    var tail = <int>[];
    if (stat.size > n) {
      await raf.setPosition(max(n, stat.size - n));
      tail = await raf.read(n);
    }
    final digest = sha256.convert([...head, ...tail]);
    return '${stat.size}:${stat.modified.millisecondsSinceEpoch}:$digest';
  } finally {
    await raf.close();
  }
}

/** sha256File：整文件 SHA-256（流式计算，不占用大量内存） */
Future<String> sha256File(File f) async => (await sha256.bind(f.openRead()).first).toString();

/**
 * Backoff：指数退避，2 秒起，最长 5 分钟
 */
class Backoff {
  Backoff({this.start = const Duration(seconds: 2), this.max = const Duration(minutes: 5)});

  final Duration start;
  final Duration max;
  int attempts = 0;

  /** next：下一次等待时长 */
  Duration next() {
    final ms = start.inMilliseconds * pow(2, attempts).toInt();
    attempts++;
    return Duration(milliseconds: min(ms, max.inMilliseconds));
  }

  /** reset：成功后清零 */
  void reset() => attempts = 0;
}

/**
 * LaneController：单文件自适应并行路数
 *
 * 规则：从 2 路开始，每 10 秒测一次总吞吐，提升超过 10% 加 1 路（最多 6 路），
 * 吞吐不增或重试变多减 1 路；移动网络或省电模式固定单路。
 */
class LaneController {
  LaneController({int initial = 2, this.maxLanes = TransferLimits.maxLanesPerFile}) : lanes = initial;

  final int maxLanes;
  int lanes;
  double _lastRate = 0;
  int _lastRetries = 0;
  bool constrained = false;

  /** 当前允许的路数 */
  int get allowed => constrained ? 1 : lanes;

  /**
   * sample：输入最近一个周期的吞吐（字节/秒）与累计重试次数，返回调整后的路数
   */
  int sample(double rate, int retries) {
    if (constrained) return 1;
    final moreRetries = retries > _lastRetries;
    if (_lastRate > 0) {
      if (!moreRetries && rate > _lastRate * 1.1 && lanes < maxLanes) {
        lanes++;
      } else if (moreRetries || rate <= _lastRate) {
        lanes = max(1, lanes - 1);
      }
    }
    _lastRate = rate;
    _lastRetries = retries;
    return lanes;
  }
}

/**
 * ChunkSizer：弱网自动降低分块大小
 *
 * 规则：默认 8MB；连续失败 2 次或速度低于 200KB/s 时降到 1MB；连续成功 5 块且速度恢复后回到 8MB。
 */
class ChunkSizer {
  int size = TransferLimits.chunk;
  int _fails = 0;
  int _ok = 0;

  /** onResult：记录一块的结果 */
  void onResult({required bool ok, double rate = 0}) {
    if (!ok) {
      _ok = 0;
      if (++_fails >= 2) size = TransferLimits.weakChunk;
      return;
    }
    _fails = 0;
    if (rate > 0 && rate < 200 * 1024) {
      size = TransferLimits.weakChunk;
      _ok = 0;
      return;
    }
    if (++_ok >= 5) size = TransferLimits.chunk;
  }
}

/**
 * splitParts：把大文件切成若干分段，每段至少 16MB
 */
List<(int, int)> splitParts(int size, int count) {
  if (size <= TransferLimits.splitAbove) return [(0, size)];
  const minPart = 16 * 1024 * 1024;
  final n = max(1, min(count, (size / minPart).ceil()));
  final step = (size / n).ceil();
  final out = <(int, int)>[];
  for (var s = 0; s < size; s += step) {
    out.add((s, min(size, s + step)));
  }
  return out;
}
