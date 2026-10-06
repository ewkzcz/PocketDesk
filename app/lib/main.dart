/**
 * 手机端入口：初始化日志、设置、本地数据库、令牌保管、全局状态与身份验证，启动界面并接收系统分享。
 */
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:sqflite/sqflite.dart';

import 'core/app_log.dart';
import 'core/app_state.dart';
import 'core/auth_gate.dart';
import 'core/device_signals.dart';
import 'core/pairing_service.dart';
import 'core/settings.dart';
import 'core/vault.dart';
import 'data/local_db.dart';
import 'transfer/naming.dart' as naming;
import 'ui/notify_router.dart';
import 'ui/shell.dart';
import 'ui/styles.dart';
import 'ui/theme.dart';

/**
 * main：启动
 *
 * 处理流程：
 * 1、日志与全局错误记录
 * 2、设置、数据库、目录
 * 3、全局状态、身份验证、配对服务
 * 4、启动界面，后台连接电脑
 */
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 1、日志
  final support = await getApplicationSupportDirectory();
  final log = AppLog(Directory(p.join(support.path, 'logs')));
  AppLog.instance = log;
  unawaited(log.prune());
  FlutterError.onError = (d) {
    AppLog.e('ui', d.exception, d.stack);
    FlutterError.presentError(d);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    AppLog.e('app', e, st);
    return true;
  };
  // 2、设置、数据库与目录
  final settings = await AppSettings.load();
  final db = await LocalDb.open(databaseFactory, p.join(await getDatabasesPath(), 'pocketdesk.db'));
  final cache = Directory(p.join((await getTemporaryDirectory()).path, 'pocketdesk'));
  final received = await _receivedDir();
  // 3、全局状态
  final vault = SecureVault();
  final app = AppState(settings: settings, db: db, vault: vault, paths: AppPaths(temp: cache, received: received), signals: SystemSignals());
  final gate = AuthGate(auth: LocalAuthenticator(), enabled: () => settings.biometric, graceMinutes: () => settings.graceMinutes);
  final pairing = PairingService(db: db, vault: vault, deviceName: Platform.isIOS ? 'iPhone' : 'Android 手机', platform: Platform.operatingSystem, installId: settings.installId);
  AppLog.i('app', '启动 ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
  // 4、启动
  unawaited(app.init());
  runApp(PocketDeskApp(settings: settings, app: app, gate: gate, pairing: pairing, share: _shareSource()));
}

/**
 * _receivedDir：电脑发来的文件保存位置
 * Android 11 起存到系统「下载/PocketDesk」，更早的版本为 App 专属外部存储下的 PocketDesk 目录（文件管理器可见）；
 * iOS 为文档目录（「文件」App 中可见）
 */
Future<Directory> _receivedDir() async {
  if (Platform.isAndroid) {
    final ext = await getExternalStorageDirectory();
    if (ext != null) return Directory(p.join(ext.path, 'PocketDesk'));
  }
  return getApplicationDocumentsDirectory();
}

/** _shareSource：系统分享进来的内容 */
ShareSource _shareSource() {
  List<({String path, String mime, bool text})> map(List<SharedMediaFile> list) {
    unawaited(ReceiveSharingIntent.instance.reset());
    return [
      for (final f in list)
        (
          path: f.path,
          mime: f.mimeType ?? (f.type == SharedMediaType.text || f.type == SharedMediaType.url ? 'text/plain' : naming.mimeForName(f.path)),
          text: f.type == SharedMediaType.text || f.type == SharedMediaType.url,
        ),
    ];
  }

  return (
    initial: () async => map(await ReceiveSharingIntent.instance.getInitialMedia()),
    stream: ReceiveSharingIntent.instance.getMediaStream().map(map),
  );
}

/**
 * PocketDeskApp：根组件
 */
class PocketDeskApp extends StatelessWidget {
  const PocketDeskApp({super.key, required this.settings, required this.app, required this.gate, required this.pairing, this.share, this.home});

  final AppSettings settings;
  final AppState app;
  final AuthGate gate;
  final PairingService pairing;
  final ShareSource? share;

  /** 首页，默认为主框架（测试时可单独显示某个页面） */
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: app),
        ChangeNotifierProvider.value(value: gate),
        Provider.value(value: pairing),
      ],
      child: Consumer<AppSettings>(
        builder: (context, s, _) => MaterialApp(
          title: 'PocketDesk',
          navigatorKey: pdNavigator,
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light, PdThemes.byId(s.styleId)),
          darkTheme: buildTheme(Brightness.dark, PdThemes.byId(s.styleId)),
          themeMode: s.themeMode,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: home ?? HomeShell(share: share),
        ),
      ),
    );
  }
}
