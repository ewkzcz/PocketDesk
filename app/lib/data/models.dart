/**
 * 数据模型：电脑、工作区、文件、会话、事件、发件与已配对电脑，统一负责 JSON 解析。
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
  const Workspace({required this.id, required this.name, required this.rootPath, required this.readOnly});

  final String id;
  final String name;
  final String rootPath;
  final bool readOnly;

  /** fromJson：解析 */
  factory Workspace.fromJson(Map<String, dynamic> j) =>
      Workspace(id: _s(j['id']), name: _s(j['name']), rootPath: _s(j['rootPath']), readOnly: _b(j['readOnly']));
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
      );

  /** copyWith：复制并修改部分字段 */
  SessionInfo copyWith({String? title, String? state, bool? pinned, String? preview, int? updatedAt, String? model, String? cwd, int? lastSeq}) =>
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
  const FileChange({required this.path, required this.added, required this.removed, required this.status, this.binary = false});

  final String path;
  final int added;
  final int removed;
  final String status;
  final bool binary;

  /** fromJson：解析 */
  factory FileChange.fromJson(Map<String, dynamic> j) => FileChange(
        path: _s(j['path']),
        added: _i(j['added']),
        removed: _i(j['removed']),
        status: _s(j['status']),
        binary: _b(j['binary']),
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
