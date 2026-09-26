/**
 * 安全通知：释放后到达的异步结果（如仍在进行的传输、网络请求）不再通知界面，避免使用已释放的对象。
 */
library;

import 'package:flutter/foundation.dart';

/** SafeNotifier：释放后忽略 notifyListeners */
mixin SafeNotifier on ChangeNotifier {
  bool _disposed = false;

  /** disposed：是否已释放 */
  bool get disposed => _disposed;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
