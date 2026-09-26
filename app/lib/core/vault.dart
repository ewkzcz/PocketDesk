/**
 * 令牌保管：设备令牌存入系统安全存储（Android Keystore / iOS 钥匙串），不写入数据库。
 */
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/** Vault：令牌存取接口，测试时使用内存实现 */
abstract class Vault {
  Future<String?> token(String hostId);
  Future<void> saveToken(String hostId, String token);
  Future<void> deleteToken(String hostId);
}

/** SecureVault：系统安全存储实现 */
class SecureVault implements Vault {
  SecureVault([FlutterSecureStorage? storage]) : _s = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _s;

  static String _key(String hostId) => 'pd.token.$hostId';

  @override
  Future<String?> token(String hostId) => _s.read(key: _key(hostId));

  @override
  Future<void> saveToken(String hostId, String token) => _s.write(key: _key(hostId), value: token);

  @override
  Future<void> deleteToken(String hostId) => _s.delete(key: _key(hostId));
}

/** MemoryVault：内存实现 */
class MemoryVault implements Vault {
  final Map<String, String> _m = {};

  @override
  Future<String?> token(String hostId) async => _m[hostId];

  @override
  Future<void> saveToken(String hostId, String token) async => _m[hostId] = token;

  @override
  Future<void> deleteToken(String hostId) async => _m.remove(hostId);
}
