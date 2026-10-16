import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../database/app_database.dart';
import '../pricing/pricing_service.dart';

class ScanCtx {
  final AppDatabase store;
  final PricingService pricing;
  final AppSettings settings;
  final String instance;
  final String? rootOverride;

  const ScanCtx({
    required this.store,
    required this.pricing,
    required this.settings,
    this.instance = kLocalInstance,
    this.rootOverride,
  });

  factory ScanCtx.local({
    required AppDatabase store,
    required PricingService pricing,
    required AppSettings settings,
  }) {
    return ScanCtx(
      store: store,
      pricing: pricing,
      settings: settings,
      instance: kLocalInstance,
    );
  }
}

class ScanReport {
  List<UsageEvent> events;
  List<PendingScanState> states;
  int filesSeen;
  int skipped;
  List<String> detectedPaths;

  ScanReport({
    List<UsageEvent>? events,
    List<PendingScanState>? states,
    this.filesSeen = 0,
    this.skipped = 0,
    List<String>? detectedPaths,
  }) : events = events ?? [],
       states = states ?? [],
       detectedPaths = detectedPaths ?? [];

  void merge(ScanReport other) {
    events.addAll(other.events);
    states.addAll(other.states);
    filesSeen += other.filesSeen;
    skipped += other.skipped;
    detectedPaths.addAll(other.detectedPaths);
  }
}

abstract class Collector {
  String get id;
  String get label;

  /// Data roots that exist on this machine. Empty means "agent not installed".
  List<String> detect(AppSettings settings);

  /// Directories worth attaching a file watcher to.
  List<String> watchPaths(AppSettings settings) => detect(settings);

  bool get isRealtime => true;

  WriteMode get writeMode => WriteMode.insertOrIgnore;

  ScanReport scan(ScanCtx ctx);
}

// ------------------------------------------------------------------ shared helpers

String homeDir() {
  final env = Platform.environment;
  return env['USERPROFILE'] ?? env['HOME'] ?? '.';
}

String? configDir() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    return env['APPDATA'] ?? p.join(homeDir(), 'AppData', 'Roaming');
  }
  return env['XDG_CONFIG_HOME'] ?? p.join(homeDir(), '.config');
}

String? localDataDir() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    return env['LOCALAPPDATA'] ?? p.join(homeDir(), 'AppData', 'Local');
  }
  return env['XDG_DATA_HOME'] ?? p.join(homeDir(), '.local', 'share');
}

String resolveRoot(
  AppSettings settings,
  String source,
  String? envVar,
  String defaultPath,
) {
  final custom = settings.customPath(source);
  if (custom != null) return custom;
  if (envVar != null) {
    final val = Platform.environment[envVar]?.trim();
    if (val != null && val.isNotEmpty) {
      return val;
    }
  }
  return defaultPath;
}

int mtimeMs(String path) {
  try {
    return File(path).lastModifiedSync().millisecondsSinceEpoch;
  } catch (_) {
    return 0;
  }
}

int fileSize(String path) {
  try {
    return File(path).lengthSync();
  } catch (_) {
    return 0;
  }
}

int? parseTimestamp(dynamic v) {
  if (v == null) return null;
  if (v is num) {
    return normalizeEpoch(v.toDouble());
  }
  if (v is String) {
    final trimmed = v.trim();
    if (trimmed.isEmpty) return null;
    final asNum = double.tryParse(trimmed);
    if (asNum != null) {
      return normalizeEpoch(asNum);
    }
    final parsed = DateTime.tryParse(trimmed);
    if (parsed != null) {
      return parsed.millisecondsSinceEpoch;
    }
    final utcCandidate = DateTime.tryParse('${trimmed}Z');
    if (utcCandidate != null) {
      return utcCandidate.millisecondsSinceEpoch;
    }
  }
  return null;
}

int normalizeEpoch(double v) {
  if (v > 1e17) {
    return (v / 1e6).toInt(); // nanoseconds
  } else if (v > 1e14) {
    return (v / 1e3).toInt(); // microseconds
  } else if (v > 1e11) {
    return v.toInt(); // milliseconds
  } else {
    return (v * 1000.0).toInt(); // seconds
  }
}

String? projectLabel(String? cwd) {
  if (cwd == null) return null;
  var trimmed = cwd.trim();
  while (trimmed.endsWith('/') || trimmed.endsWith('\\')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed.isEmpty) return null;
  final base = p.basename(trimmed);
  return base.isEmpty ? trimmed : base;
}

List<UsageEvent> finalizeEvents(
  List<UsageEvent> events,
  PricingService pricing,
) {
  final out = <UsageEvent>[];
  for (final e in events) {
    if (e.isEmpty) continue;
    if (e.modelNorm.isEmpty) {
      e.modelNorm = pricing.normalize(e.model);
    }
    e.costIsNative ??= e.costUsd != null;
    e.costUsd ??= pricing.cost(
      e.modelNorm,
      e.inputTokens,
      e.outputTokens,
      e.cacheReadTokens,
      e.cacheWriteTokens,
    );
    out.add(e);
  }
  return out;
}

Database openSqliteReadOnly(String dbPath) {
  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  db.execute('PRAGMA busy_timeout = 2000;');
  return db;
}

bool tableExists(Database conn, String table) {
  try {
    final rows = conn.select(
      "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = ?1",
      [table],
    );
    return rows.isNotEmpty;
  } catch (_) {
    return false;
  }
}

bool columnExists(Database conn, String table, String column) {
  try {
    final rows = conn.select('PRAGMA table_info("$table")');
    final lower = column.toLowerCase();
    return rows.any((r) => (r['name'] as String?)?.toLowerCase() == lower);
  } catch (_) {
    return false;
  }
}

class JsonlChunk {
  final List<(int, String)> lines;
  final int newOffset;
  final int newLineNo;
  final int mtimeMs;

  const JsonlChunk({
    required this.lines,
    required this.newOffset,
    required this.newLineNo,
    required this.mtimeMs,
  });
}

JsonlChunk readNewLines(
  AppDatabase store,
  String source,
  String instance,
  String path,
) {
  final state = store.getScanState(source, instance, path) ?? const ScanState();
  final size = fileSize(path);
  final mtime = mtimeMs(path);

  var offset = size < state.offset ? 0 : state.offset;
  var lineNo = size < state.offset ? 0 : lineNoFromExtra(state.extra);

  if (offset >= size) {
    return JsonlChunk(
      lines: const [],
      newOffset: offset,
      newLineNo: lineNo,
      mtimeMs: mtime,
    );
  }

  return readLinesFromOffset(path, offset, lineNo, size: size, mtime: mtime);
}

JsonlChunk readLinesFromOffset(
  String path,
  int offset,
  int lineNo, {
  int? size,
  int? mtime,
}) {
  final actualSize = size ?? fileSize(path);
  final actualMtime = mtime ?? mtimeMs(path);
  if (offset >= actualSize) {
    return JsonlChunk(
      lines: const [],
      newOffset: offset,
      newLineNo: lineNo,
      mtimeMs: actualMtime,
    );
  }

  final raf = File(path).openSync(mode: FileMode.read);
  Uint8List buf;
  try {
    raf.setPositionSync(offset);
    final toRead = (actualSize - offset).clamp(0, 64 * 1024 * 1024);
    buf = raf.readSync(toRead);
  } finally {
    raf.closeSync();
  }

  var lastNewline = -1;
  for (var i = buf.length - 1; i >= 0; i--) {
    if (buf[i] == 0x0A /* \n */ ) {
      lastNewline = i + 1;
      break;
    }
  }
  if (lastNewline <= 0) {
    return JsonlChunk(
      lines: const [],
      newOffset: offset,
      newLineNo: lineNo,
      mtimeMs: actualMtime,
    );
  }

  final consumed = Uint8List.sublistView(buf, 0, lastNewline);
  final newOffset = offset + lastNewline;
  final text = utf8.decode(consumed, allowMalformed: true);

  final lines = <(int, String)>[];
  var currentLineNo = lineNo;
  for (final raw in const LineSplitter().convert(text)) {
    currentLineNo += 1;
    final t = raw.trim();
    if (t.isNotEmpty) {
      lines.add((currentLineNo, t));
    }
  }

  return JsonlChunk(
    lines: lines,
    newOffset: newOffset,
    newLineNo: currentLineNo,
    mtimeMs: actualMtime,
  );
}

int lineNoFromExtra(String? extra) {
  final s = extra?.trim();
  if (s == null || s.isEmpty) return 0;
  final direct = int.tryParse(s);
  if (direct != null) return direct;
  try {
    final decoded = jsonDecode(s);
    if (decoded is Map && decoded['line_no'] is num) {
      return (decoded['line_no'] as num).toInt();
    }
  } catch (_) {}
  return 0;
}

PendingScanState pendingScanState(
  String source,
  String instance,
  String path,
  JsonlChunk chunk,
) {
  return PendingScanState(
    source: source,
    instance: instance,
    key: path,
    state: ScanState(
      offset: chunk.newOffset,
      mtimeMs: chunk.mtimeMs,
      extra: chunk.newLineNo.toString(),
    ),
  );
}

List<String> findFiles(
  String rootPath,
  bool Function(String filePath) predicate, {
  int maxDepth = 8,
}) {
  final dir = Directory(rootPath);
  if (!dir.existsSync()) return const [];
  final out = <String>[];

  void walk(Directory current, int depth) {
    if (depth > maxDepth) return;
    List<FileSystemEntity> entries;
    try {
      entries = current.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final e in entries) {
      if (e is File) {
        if (predicate(e.path)) {
          out.add(e.path);
        }
      } else if (e is Directory) {
        walk(e, depth + 1);
      }
    }
  }

  walk(dir, 0);
  return out;
}

bool hasExt(String path, String ext) {
  final actual = p.extension(path);
  if (actual.isEmpty) return false;
  final stripped = actual.startsWith('.') ? actual.substring(1) : actual;
  return stripped.toLowerCase() == ext.toLowerCase();
}

String fileStem(String path) => p.basenameWithoutExtension(path);

String shaKey(List<String> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(utf8.encode(part));
    builder.addByte(0);
  }
  final digest = sha256.convert(builder.toBytes()).bytes;
  final buf = StringBuffer();
  for (var i = 0; i < 12 && i < digest.length; i++) {
    buf.write(digest[i].toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}
