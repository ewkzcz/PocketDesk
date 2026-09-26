/**
 * 生物识别门禁：打开 App、进入 Agent 会话或终端时验证身份，验证后在设定时间内免验证；设备不支持时直接放行。
 */
library;

import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/** Authenticator：系统身份验证接口，测试时替换 */
abstract class Authenticator {
  /** available：设备是否设置了生物识别或锁屏密码 */
  Future<bool> available();

  /** authenticate：弹出系统验证，成功返回 true */
  Future<bool> authenticate(String reason);
}

/** LocalAuthenticator：系统实现（允许回退到锁屏密码） */
class LocalAuthenticator implements Authenticator {
  final _auth = LocalAuthentication();

  @override
  Future<bool> available() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason);
    } catch (_) {
      return false;
    }
  }
}

/**
 * AuthGate：验证状态
 */
class AuthGate extends ChangeNotifier {
  AuthGate({required this.auth, required this.enabled, required this.graceMinutes, DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final Authenticator auth;
  final bool Function() enabled;
  final int Function() graceMinutes;
  final DateTime Function() _now;
  DateTime? _passedAt;
  Future<bool>? _pending;

  /** fresh：是否仍在免验证时间内 */
  bool get fresh {
    final at = _passedAt;
    if (at == null) return false;
    final grace = graceMinutes();
    return grace > 0 && _now().difference(at) < Duration(minutes: grace);
  }

  /**
   * ensure：需要时弹出验证
   *
   * 处理流程：
   * 1、未开启或仍在免验证时间内直接放行
   * 2、设备不支持验证时放行
   * 3、同时多处请求只弹一次
   */
  Future<bool> ensure(String reason) {
    // 1、免验证
    if (!enabled() || fresh) return Future.value(true);
    // 3、合并请求
    return _pending ??= () async {
      try {
        // 2、设备不支持
        if (!await auth.available()) return true;
        final ok = await auth.authenticate(reason);
        if (ok) {
          _passedAt = _now();
          notifyListeners();
        }
        return ok;
      } finally {
        _pending = null;
      }
    }();
  }

  /** touch：使用中延长免验证时间 */
  void touch() {
    if (_passedAt != null && fresh) _passedAt = _now();
  }

  /** lock：立即失效（手动锁定或关闭免验证） */
  void lock() {
    _passedAt = null;
    notifyListeners();
  }
}
