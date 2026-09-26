/**
 * 传输任务模型：一次上传或下载的状态、进度、速度、并行路数与分段记录，可存入本地数据库。
 */
library;

/** 传输方向 */
enum Direction { up, down }

/** 任务状态 */
abstract final class TaskStatus {
  static const queued = 'queued';
  static const running = 'running';
  static const paused = 'paused';
  static const waiting = 'waiting';
  static const done = 'done';
  static const failed = 'failed';
  static const canceled = 'canceled';
}

/** Part：一个分段，上传时对应一个 tus 分段上传，下载时对应一段 Range */
class Part {
  Part({required this.index, required this.start, required this.end, this.url = '', this.confirmed = 0, this.status = TaskStatus.queued, this.fails = 0});

  final int index;
  final int start;
  final int end;
  String url;
  int confirmed;
  String status;
  int fails;

  int get length => end - start;
  bool get done => confirmed >= length;

  /** toRow：数据库行 */
  Map<String, Object?> toRow() => {'idx': index, 'offset_start': start, 'offset_end': end, 'tus_url': url, 'confirmed_offset': confirmed, 'status': status};

  /** fromRow：从数据库行恢复 */
  factory Part.fromRow(Map<String, Object?> r) => Part(
        index: r['idx']! as int,
        start: r['offset_start']! as int,
        end: r['offset_end']! as int,
        url: r['tus_url']! as String,
        confirmed: r['confirmed_offset']! as int,
        status: r['status']! as String,
      );
}

/**
 * TransferTask：一次传输
 */
class TransferTask {
  TransferTask({
    required this.id,
    required this.hostId,
    required this.direction,
    required this.source,
    required this.name,
    required this.size,
    required this.createdAt,
    required this.dateFolder,
    this.target = '',
    this.mime = '',
    this.fingerprint = '',
    this.sha256 = '',
    this.status = TaskStatus.queued,
    this.remote = '',
    this.result = '',
    this.error = '',
    this.doneBytes = 0,
    this.finishedAt = 0,
  });

  final String id;
  final String hostId;
  final Direction direction;

  /** 上传为本机文件路径；下载为电脑端资源（outbox:ID 或 ws:工作区ID:路径） */
  final String source;
  final String name;
  final int size;
  final int createdAt;
  final String dateFolder;

  /** 上传目标：inbox / assistant / session:会话ID */
  final String target;
  final String mime;
  String fingerprint;
  String sha256;
  String status;

  /** 单文件上传地址 */
  String remote;

  /** 完成后的文件名（上传）或本机路径（下载） */
  String result;
  String error;
  int doneBytes;
  int finishedAt;

  /** 运行时信息，不入库 */
  double speed = 0;
  int lanes = 0;
  List<Part> parts = [];
  int retries = 0;

  /** progress：0~1 */
  double get progress => size <= 0 ? (status == TaskStatus.done ? 1 : 0) : (doneBytes / size).clamp(0, 1).toDouble();

  /** remaining：预计剩余秒数，速度未知时为 -1 */
  int get remaining => speed <= 1 ? -1 : ((size - doneBytes) / speed).ceil();

  /** active：是否在进行中列表 */
  bool get active => status == TaskStatus.queued || status == TaskStatus.running || status == TaskStatus.paused || status == TaskStatus.waiting || status == TaskStatus.failed;

  /** toRow：数据库行 */
  Map<String, Object?> toRow() => {
        'id': id,
        'host_id': hostId,
        'direction': direction.name,
        'source_uri': source,
        'dest_name': name,
        'size': size,
        'fingerprint': fingerprint,
        'sha256': sha256,
        'status': status,
        'created_at': createdAt,
        'date_folder': dateFolder,
        'target': target,
        'remote': remote,
        'result': result,
        'error': error,
        'done_bytes': doneBytes,
        'finished_at': finishedAt,
        'mime': mime,
      };

  /** fromRow：从数据库行恢复，运行中的任务恢复为排队 */
  factory TransferTask.fromRow(Map<String, Object?> r) {
    final st = r['status']! as String;
    return TransferTask(
      id: r['id']! as String,
      hostId: r['host_id']! as String,
      direction: r['direction'] == 'down' ? Direction.down : Direction.up,
      source: r['source_uri']! as String,
      name: r['dest_name']! as String,
      size: r['size']! as int,
      createdAt: r['created_at']! as int,
      dateFolder: r['date_folder']! as String,
      target: r['target']! as String,
      mime: r['mime']! as String,
      fingerprint: r['fingerprint']! as String,
      sha256: r['sha256']! as String,
      status: st == TaskStatus.running || st == TaskStatus.waiting ? TaskStatus.queued : st,
      remote: r['remote']! as String,
      result: r['result']! as String,
      error: r['error']! as String,
      doneBytes: r['done_bytes']! as int,
      finishedAt: r['finished_at']! as int,
    );
  }
}
