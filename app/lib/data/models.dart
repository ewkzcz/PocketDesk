/**
 * 数据模型：电脑、工作区、文件、会话、事件、电脑待发给手机的文件与已配对电脑，统一负责 JSON 解析。
 */
library;

/** 读取工具：宽松地把动态值转成目标类型，缺失时给默认值 */
String _s(Object? v, [String d = '']) => v is String ? v : (v == null ? d : v.toString());
int _i(Object? v, [int d = 0]) => v is int ? v : (v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? d : d));
bool _b(Object? v, [bool d = false]) => v is bool ? v : d;
Map<String, dynamic> _m(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
List<dynamic> _l(Object? v) => v is List ? v : const [];

/** Features：电脑端功能开关 */
class Features {
  const Features({this.agents = true, this.terminal = false, this.fileEdit = true});

  final bool agents;
  final bool terminal;
  final bool fileEdit;

  /** fromJson：解析 */
  factory Features.fromJson(Map<String, dynamic> j) =>
      Features(agents: _b(j['agents'], true), terminal: _b(j['terminal']), fileEdit: _b(j['fileEdit'], true));
}

/** AgentInfo：电脑上某个 Agent 的安装情况 */
class AgentInfo {
  const AgentInfo({required this.kind, required this.label, required this.installed, this.version = ''});

  final String kind;
  final String label;
  final bool installed;
  final String version;

  /** fromJson：解析 */
  factory AgentInfo.fromJson(Map<String, dynamic> j) =>
      AgentInfo(kind: _s(j['kind']), label: _s(j['label']), installed: _b(j['installed']), version: _s(j['version']));
}

/** HostAddress：电脑的一个可达地址 */
class HostAddress {
  const HostAddress({required this.ip, required this.kind});

  final String ip;
  final String kind;

  /** fromJson：解析 */
  factory HostAddress.fromJson(Map<String, dynamic> j) => HostAddress(ip: _s(j['ip']), kind: _s(j['kind']));
}

/** HostStatus：/api/host 返回的电脑信息 */
class HostStatus {
  const HostStatus({
    required this.name,
    required this.os,
    required this.version,
    required this.apiVersion,
    required this.fingerprint,
    required this.agents,
    required this.features,
    required this.addresses,
    required this.port,
    required this.deviceId,
    this.remoteState = '',
    this.remoteAddresses = const [],
    this.pushKind = '',
    this.pushUrl = '',
    this.pushTopic = '',
  });

  final String name;
  final String os;
  final String version;
  final String apiVersion;
  final String fingerprint;
  final List<AgentInfo> agents;
  final Features features;
  final List<HostAddress> addresses;
  final int port;
  final String deviceId;

  /** 电脑端的后台推送设置（ntfy 或 Bark），手机 App 不在线时用它提醒 */
  final String pushKind;
  final String pushUrl;
  final String pushTopic;

  /** remoteState：电脑上的异地连接（Tailscale）：missing 未安装、offline 未登录、ready 已连通；旧版电脑端为空 */
  final String remoteState;

  /** remoteAddresses：电脑的 Tailscale 地址 */
  final List<String> remoteAddresses;

  /** fromJson：解析 */
  factory HostStatus.fromJson(Map<String, dynamic> j) => HostStatus(
        name: _s(j['name']),
        os: _s(j['os']),
        version: _s(j['version']),
        apiVersion: _s(j['apiVersion']),
        fingerprint: _s(j['fingerprint']),
        agents: _l(j['agents']).map((e) => AgentInfo.fromJson(_m(e))).toList(),
        features: Features.fromJson(_m(j['features'])),
        addresses: _l(j['addresses']).map((e) => HostAddress.fromJson(_m(e))).toList(),
        port: _i(j['port'], 8443),
        deviceId: _s(j['deviceId']),
        remoteState: _s(_m(j['remote'])['state']),
        remoteAddresses: _l(_m(j['remote'])['addresses']).map((e) => e.toString()).toList(),
        pushKind: _s(_m(j['push'])['kind']),
        pushUrl: _s(_m(j['push'])['url']),
        pushTopic: _s(_m(j['push'])['topic']),
      );

  /** agentInstalled：某个 Agent 是否已安装 */
  bool agentInstalled(String kind) => agents.any((a) => a.kind == kind && a.installed);
}

/** PairedHost：手机上保存的已配对电脑 */
class PairedHost {
  const PairedHost({
    required this.id,
    required this.name,
    required this.addresses,
    required this.port,
    required this.fingerprint,
    this.lastUsed = 0,
    this.deviceId = '',
  });

  final String id;
  final String name;
  final List<String> addresses;
  final int port;
  final String fingerprint;
  final int lastUsed;
  final String deviceId;

  /** copyWith：复制并修改部分字段 */
  PairedHost copyWith({String? name, List<String>? addresses, int? lastUsed}) => PairedHost(
        id: id,
        name: name ?? this.name,
        addresses: addresses ?? this.addresses,
        port: port,
        fingerprint: fingerprint,
        lastUsed: lastUsed ?? this.lastUsed,
        deviceId: deviceId,
      );
}

/** Workspace：电脑上授权的工作区 */
class Workspace {
  const Workspace({required this.id, required this.name, required this.rootPath, required this.readOnly, this.isDefault = false, this.system = false, this.home = ''});

  final String id;
  final String name;
  final String rootPath;
  final bool readOnly;

  /** isDefault：默认工作目录 */
  final bool isDefault;

  /** system：内置的「此电脑」，可访问电脑上的任意文件夹 */
  final bool system;

  /** home：「此电脑」中个人文件夹的相对路径，打开时定位到这里 */
  final String home;

  /** fromJson：解析 */
  factory Workspace.fromJson(Map<String, dynamic> j) => Workspace(
      id: _s(j['id']),
      name: _s(j['name']),
      rootPath: _s(j['rootPath']),
      readOnly: _b(j['readOnly']),
      isDefault: _b(j['isDefault']),
      system: _b(j['system']),
      home: _s(j['home']));

  /** relOf：电脑上的完整路径在本工作区中的相对路径，不在工作区内时为空 */
  String relOf(String abs) {
    final win = rootPath.contains('\\');
    final sep = win ? '\\' : '/';
    final root = rootPath.endsWith(sep) ? rootPath : rootPath + sep;
    if (!abs.startsWith(root)) return '';
    final rel = abs.substring(root.length);
    return win ? rel.replaceAll(sep, '/') : rel;
  }

  /** absPath：工作区内相对路径对应的电脑上的完整路径 */
  String absPath(String rel) {
    final r = rel == '.' ? '' : rel;
    if (r.isEmpty) return rootPath;
    final win = rootPath.contains('\\');
    final sep = win ? '\\' : '/';
    final root = rootPath.endsWith(sep) ? rootPath : rootPath + sep;
    return root + (win ? r.replaceAll('/', sep) : r);
  }

}

/** FileEntry：目录中的一项 */
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modTime,
    this.childCount = -1,
    this.dateFolder = false,
  });

  final String name;
  final String path;
  final bool isDir;
  final int size;
  final int modTime;
  final int childCount;
  final bool dateFolder;

  /** fromJson：解析 */
  factory FileEntry.fromJson(Map<String, dynamic> j) => FileEntry(
        name: _s(j['name']),
        path: _s(j['path']),
        isDir: _b(j['isDir']),
        size: _i(j['size']),
        modTime: _i(j['modTime']),
        childCount: _i(j['childCount'], -1),
        dateFolder: _b(j['dateFolder']),
      );

  /** ext：小写扩展名（不含点） */
  String get ext {
    final i = name.lastIndexOf('.');
    return i <= 0 ? '' : name.substring(i + 1).toLowerCase();
  }
}

/** 会话状态 */
abstract final class SessionState {
  static const idle = 'idle';
  static const running = 'running';
  static const awaiting = 'awaiting';
  static const interrupted = 'interrupted';
  static const error = 'error';
  static const exited = 'exited';
}

/** SessionInfo：会话列表中的一个会话 */
class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.kind,
    required this.title,
    required this.workspaceId,
    required this.cwd,
    required this.model,
    required this.state,
    required this.pinned,
    required this.lastSeq,
    required this.preview,
    required this.updatedAt,
    this.agentSessionId = '',
    this.autoApprove = false,
    this.muted = false,
    this.provider = '',
  });

  final String id;
  final String kind;
  final String title;
  final String workspaceId;
  final String cwd;
  final String model;
  final String state;
  final bool pinned;
  final int lastSeq;
  final String preview;
  final int updatedAt;
  final String agentSessionId;

  /** autoApprove：免审批会话，电脑上的操作全部自动放行 */
  final bool autoApprove;

  /** muted：关闭提醒，待审批与完成时不弹通知 */
  final bool muted;

  /** provider：本会话使用的模型供应商（CC Switch 中的供应商 ID），空为跟随电脑 */
  final String provider;

  /** fromJson：解析 */
  factory SessionInfo.fromJson(Map<String, dynamic> j) => SessionInfo(
        id: _s(j['id']),
        kind: _s(j['kind']),
        title: _s(j['title']),
        workspaceId: _s(j['workspaceId']),
        cwd: _s(j['cwd'], '.'),
        model: _s(j['model']),
        state: _s(j['state'], SessionState.idle),
        pinned: _b(j['pinned']),
        lastSeq: _i(j['lastSeq']),
        preview: _s(j['preview']),
        updatedAt: _i(j['updatedAt']),
        agentSessionId: _s(j['agentSessionId']),
        autoApprove: _b(j['autoApprove']),
        muted: _b(j['muted']),
        provider: _s(j['provider']),
      );

  /** copyWith：复制并修改部分字段 */
  SessionInfo copyWith({String? title, String? state, bool? pinned, String? preview, int? updatedAt, String? model, String? cwd, int? lastSeq, bool? muted}) =>
      SessionInfo(
        id: id,
        kind: kind,
        title: title ?? this.title,
        workspaceId: workspaceId,
        cwd: cwd ?? this.cwd,
        model: model ?? this.model,
        state: state ?? this.state,
        pinned: pinned ?? this.pinned,
        lastSeq: lastSeq ?? this.lastSeq,
        preview: preview ?? this.preview,
        updatedAt: updatedAt ?? this.updatedAt,
        agentSessionId: agentSessionId,
        autoApprove: autoApprove,
        muted: muted ?? this.muted,
        provider: provider,
      );

  /** isAgent：是否为 AI 编程工具会话 */
  bool get isAgent => kind == 'claude' || kind == 'codex' || kind == 'pi' || kind == 'dsh';

  /** isTerminal：是否为终端会话 */
  bool get isTerminal => kind == 'terminal';

  /** isAssistant：是否为文件传输助手 */
  bool get isAssistant => kind == 'assistant';

  /** busy：是否正在执行 */
  bool get busy => state == SessionState.running || state == SessionState.awaiting;
}

/** PdEvent：会话事件或全局事件 */
class PdEvent {
  const PdEvent({required this.session, required this.seq, required this.type, required this.data, this.createdAt = 0});

  final String session;
  final int seq;
  final String type;
  final Map<String, dynamic> data;
  final int createdAt;

  /** fromJson：解析 */
  factory PdEvent.fromJson(Map<String, dynamic> j) =>
      PdEvent(session: _s(j['session']), seq: _i(j['seq']), type: _s(j['type']), data: _m(j['data']), createdAt: _i(j['createdAt']));

  /** toJson：序列化（用于本地缓存） */
  Map<String, dynamic> toJson() => {'session': session, 'seq': seq, 'type': type, 'data': data, 'createdAt': createdAt};
}

/** OutboxItem：电脑待发给手机的文件 */
class OutboxItem {
  const OutboxItem({required this.id, required this.name, required this.size, required this.sha256, required this.createdAt});

  final String id;
  final String name;
  final int size;
  final String sha256;
  final int createdAt;

  /** fromJson：解析 */
  factory OutboxItem.fromJson(Map<String, dynamic> j) =>
      OutboxItem(id: _s(j['id']), name: _s(j['name']), size: _i(j['size']), sha256: _s(j['sha256']), createdAt: _i(j['createdAt']));
}

/** HistoryItem：电脑上已有的 Agent 会话（/resume） */
class HistoryItem {
  const HistoryItem({required this.id, required this.title, required this.updatedAt});

  final String id;
  final String title;
  final int updatedAt;

  /** fromJson：解析 */
  factory HistoryItem.fromJson(Map<String, dynamic> j) =>
      HistoryItem(id: _s(j['id']), title: _s(j['title']), updatedAt: _i(j['updatedAt']));
}

/** FileChange：改动清单中的一项 */
class FileChange {
  const FileChange({required this.path, required this.added, required this.removed, required this.status, this.binary = false, this.abs = '', this.ref = ''});

  final String path;
  final String abs;

  /** ref：这一轮保存的差异编号，查看差异时带上 */
  final String ref;
  final int added;
  final int removed;
  final String status;
  final bool binary;

  /** fromJson：解析 */
  factory FileChange.fromJson(Map<String, dynamic> j) => FileChange(
        path: _s(j['path']),
        abs: _s(j['abs']),
        added: _i(j['added']),
        removed: _i(j['removed']),
        status: _s(j['status']),
        binary: _b(j['binary']),
        ref: _s(j['ref']),
      );
}

/** ProviderInfo：模型供应商（来自电脑上的 CC Switch，不含密钥） */
class ProviderInfo {
  const ProviderInfo({required this.id, required this.name, required this.current, required this.host, required this.models});

  final String id;
  final String name;

  /** current：电脑当前正在用的供应商 */
  final bool current;
  final String host;
  final List<String> models;

  /** fromJson：解析 */
  factory ProviderInfo.fromJson(Map<String, dynamic> j) => ProviderInfo(
        id: _s(j['id']),
        name: _s(j['name']),
        current: _b(j['current']),
        host: _s(j['host']),
        models: _l(j['models']).map((e) => e.toString()).toList(),
      );
}

/** 解析辅助：供其他模块复用 */
abstract final class Json {
  static String str(Object? v, [String d = '']) => _s(v, d);
  static int integer(Object? v, [int d = 0]) => _i(v, d);
  static bool boolean(Object? v, [bool d = false]) => _b(v, d);
  static Map<String, dynamic> map(Object? v) => _m(v);
  static List<dynamic> list(Object? v) => _l(v);
}
