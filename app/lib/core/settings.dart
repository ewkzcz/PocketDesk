/**
 * 手机端设置：外观、传输（仅 Wi-Fi、低电量暂停、同时传输数）、生物识别与当前电脑，保存在本地偏好里。
 */
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/** AppSettings：设置项，变化时通知界面 */
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);

  final SharedPreferences _prefs;

  /** load：读取偏好 */
  static Future<AppSettings> load() async => AppSettings(await SharedPreferences.getInstance());

  /** themeMode：跟随系统 / 浅色 / 深色 */
  ThemeMode get themeMode => switch (_prefs.getString('theme')) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  set themeMode(ThemeMode m) {
    _prefs.setString('theme', m.name);
    notifyListeners();
  }

  /** themeLabel：外观设置的展示文字 */
  String get themeLabel => switch (themeMode) {
        ThemeMode.light => '浅色',
        ThemeMode.dark => '深色',
        ThemeMode.system => '跟随系统',
      };

  /** wifiOnly：仅在 Wi-Fi 下传输 */
  bool get wifiOnly => _prefs.getBool('wifiOnly') ?? false;
  set wifiOnly(bool v) => _set('wifiOnly', v);

  /** pauseOnLowBattery：低电量时暂停传输 */
  bool get pauseOnLowBattery => _prefs.getBool('pauseLowBattery') ?? true;
  set pauseOnLowBattery(bool v) => _set('pauseLowBattery', v);

  /** concurrency：同时传输的文件数（1~6，默认 3） */
  int get concurrency => (_prefs.getInt('concurrency') ?? 3).clamp(1, 6);

  set concurrency(int v) {
    _prefs.setInt('concurrency', v.clamp(1, 6));
    notifyListeners();
  }

  /** autoReceive：电脑发来的文件自动下载到手机 */
  bool get autoReceive => _prefs.getBool('autoReceive') ?? true;
  set autoReceive(bool v) => _set('autoReceive', v);

  /** saveToGallery：图片与视频同时存入相册（iOS） */
  bool get saveToGallery => _prefs.getBool('saveToGallery') ?? false;
  set saveToGallery(bool v) => _set('saveToGallery', v);

  /** biometric：打开 App、进入 Agent 会话或终端时验证 */
  bool get biometric => _prefs.getBool('biometric') ?? true;
  set biometric(bool v) => _set('biometric', v);

  /** graceMinutes：验证后多少分钟内免验证（0 表示每次都验证） */
  int get graceMinutes => _prefs.getInt('grace') ?? 5;

  set graceMinutes(int v) {
    _prefs.setInt('grace', v);
    notifyListeners();
  }

  /** currentHost：当前使用的电脑 */
  String get currentHost => _prefs.getString('host') ?? '';

  set currentHost(String id) {
    _prefs.setString('host', id);
    notifyListeners();
  }

  /** onboardingDone：已提示过后台运行白名单 */
  bool get backgroundHintShown => _prefs.getBool('bgHint') ?? false;
  set backgroundHintShown(bool v) => _set('bgHint', v);

  /** _set：写布尔值并通知 */
  void _set(String k, bool v) {
    _prefs.setBool(k, v);
    notifyListeners();
  }
}
