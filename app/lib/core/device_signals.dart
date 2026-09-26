/**
 * 设备状态：网络类型（Wi-Fi / 移动网络 / 无网络）与电量、省电模式，合并为传输队列使用的 NetState。
 */
library;

import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'transfer_manager.dart';

/** DeviceSignals：设备状态来源，测试时替换 */
abstract class DeviceSignals {
  /** current：当前状态 */
  Future<NetState> current();

  /** changes：状态变化（网络变化时 networkChanged 为 true） */
  Stream<({NetState state, bool networkChanged})> changes();
}

/** netStateFrom：由网络类型与电量计算状态（电量低于 15% 且未充电视为低电量） */
NetState netStateFrom(List<ConnectivityResult> r, int level, BatteryState battery, bool saver) {
  final wifi = r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
  final online = r.any((x) => x != ConnectivityResult.none);
  final charging = battery == BatteryState.charging || battery == BatteryState.full;
  return NetState(wifi: wifi, online: online, lowBattery: !charging && level >= 0 && level < 15, powerSave: saver);
}

/**
 * SystemSignals：系统实现，电量每分钟刷新一次
 */
class SystemSignals implements DeviceSignals {
  final _conn = Connectivity();
  final _battery = Battery();
  List<ConnectivityResult> _net = const [ConnectivityResult.wifi];
  int _level = 100;
  BatteryState _state = BatteryState.unknown;
  bool _saver = false;

  /** _read：读取电量信息，平台不支持时保持默认 */
  Future<void> _read() async {
    try {
      _level = await _battery.batteryLevel;
      _state = await _battery.batteryState;
      _saver = await _battery.isInBatterySaveMode;
    } catch (_) {
      // 忽略
    }
  }

  @override
  Future<NetState> current() async {
    try {
      _net = await _conn.checkConnectivity();
    } catch (_) {
      // 忽略
    }
    await _read();
    return netStateFrom(_net, _level, _state, _saver);
  }

  @override
  Stream<({NetState state, bool networkChanged})> changes() {
    late StreamController<({NetState state, bool networkChanged})> out;
    final subs = <StreamSubscription<dynamic>>[];
    Timer? tick;
    void emit(bool net) => out.add((state: netStateFrom(_net, _level, _state, _saver), networkChanged: net));
    out = StreamController(
      onListen: () {
        subs.add(_conn.onConnectivityChanged.listen((r) {
          _net = r;
          emit(true);
        }, onError: (_) {}));
        subs.add(_battery.onBatteryStateChanged.listen((s) async {
          await _read();
          emit(false);
        }, onError: (_) {}));
        tick = Timer.periodic(const Duration(minutes: 1), (_) async {
          await _read();
          emit(false);
        });
      },
      onCancel: () {
        tick?.cancel();
        for (final s in subs) {
          s.cancel();
        }
      },
    );
    return out.stream;
  }
}
