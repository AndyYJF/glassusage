import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../domain/models/settings_model.dart';
import '../../domain/models/output_speed.dart';
import '../../domain/models/usage_models.dart';
import '../database/app_database.dart';
import 'collector_base.dart';
import 'output_timing.dart';

class CumulativeTokens {
  final int input;
  final int cachedInput;
  final int cacheWrite;
  final int output;
  final int reasoning;

  const CumulativeTokens({
    this.input = 0,
    this.cachedInput = 0,
    this.cacheWrite = 0,
    this.output = 0,
    this.reasoning = 0,
  });

  factory CumulativeTokens.fromJson(Map<String, dynamic> v) {
    int n(String k) => (v[k] as num?)?.toInt() ?? 0;
    return CumulativeTokens(
      input: n('input_tokens'),
      cachedInput: n('cached_input_tokens'),
      cacheWrite: n('cache_write_input_tokens'),
      output: n('output_tokens'),
      reasoning: n('reasoning_output_tokens'),
    );
  }

  Map<String, dynamic> toJson() => {
        'input': input,
        'cached_input': cachedInput,
        'cache_write': cacheWrite,
        'output': output,
        'reasoning': reasoning,
      };

  factory CumulativeTokens.fromStateJson(Map<String, dynamic> v) {
    int n(String k) => (v[k] as num?)?.toInt() ?? 0;
    return CumulativeTokens(
      input: n('input'),
      cachedInput: n('cached_input'),
      cacheWrite: n('cache_write'),
      output: n('output'),
      reasoning: n('reasoning'),
    );
  }

  int get sum => input + output + cacheWrite;

  CumulativeTokens delta(CumulativeTokens prev) {
    return CumulativeTokens(
      input: math.max(0, input - prev.input),
      cachedInput: math.max(0, cachedInput - prev.cachedInput),
      cacheWrite: math.max(0, cacheWrite - prev.cacheWrite),
      output: math.max(0, output - prev.output),
      reasoning: math.max(0, reasoning - prev.reasoning),
    );
  }

  bool get isZero =>
      input == 0 && output == 0 && cachedInput == 0 && cacheWrite == 0;
}

class CodexState {
  int offset;
  int lineNo;
  CumulativeTokens prev;
  String model;
  String provider;
  String sessionId;
  String? project;
  OutputTurnState outputTiming;

  CodexState({
    this.offset = 0,
    this.lineNo = 0,
    this.prev = const CumulativeTokens(),
    this.model = '',
    this.provider = '',
    this.sessionId = '',
    this.project,
    OutputTurnState? outputTiming,
  }) : outputTiming = outputTiming ?? OutputTurnState();

  Map<String, dynamic> toJson() => {
        'offset': offset,
        'line_no': lineNo,
        'prev': prev.toJson(),
        'model': model,
        'provider': provider,
        'session_id': sessionId,
        'project': project,
        'outputTiming': outputTiming.toJson(),
      };

  factory CodexState.fromJson(Map<String, dynamic> json) {
    final prevRaw = json['prev'];
    return CodexState(
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      lineNo: (json['line_no'] as num?)?.toInt() ?? 0,
      prev: prevRaw is Map
          ? CumulativeTokens.fromStateJson(Map<String, dynamic>.from(prevRaw))
          : const CumulativeTokens(),
      model: json['model'] as String? ?? '',
      provider: json['provider'] as String? ?? '',
      sessionId: json['session_id'] as String? ?? '',
      project: json['project'] as String?,
      outputTiming: OutputTurnState.fromJson(json['outputTiming']),
    );
  }
}

class CodexCollector extends Collector {
  @override
  String get id => SourceIds.codex;

  @override
  String get label => 'Codex';

  static String home(AppSettings settings) {
    return resolveRoot(
      settings,
      SourceIds.codex,
      'CODEX_HOME',
      p.join(homeDir(), '.codex'),
    );
  }

  static List<String> roots(AppSettings settings) {
    final h = home(settings);
    return [p.join(h, 'sessions'), p.join(h, 'archived_sessions')]
        .where((dir) => Directory(dir).existsSync())
        .toList();
  }

  @override
  List<String> detect(AppSettings settings) => roots(settings);

  @override
  ScanReport scan(ScanCtx ctx) {
    final dirRoots =
        ctx.rootOverride != null ? [ctx.rootOverride!] : roots(ctx.settings);
    if (dirRoots.isEmpty) return ScanReport();

    final files = <String>[];
    for (final r in dirRoots) {
      files.addAll(findFiles(r, (f) => hasExt(f, 'jsonl')));
    }

    final report = ScanReport(
      filesSeen: files.length,
      detectedPaths: List.from(dirRoots),
    );

    for (final path in files) {
      final res = parseCodexFile(ctx, path, outputSpeeds: report.outputSpeeds);
      if (res == null) continue;
      final (state, events, skipped) = res;
      report.events.addAll(events);
      report.skipped += skipped;
      report.states.add(
        PendingScanState(
          source: SourceIds.codex,
          instance: ctx.instance,
          key: path,
          state: ScanState(
            offset: state.offset,
            mtimeMs: mtimeMs(path),
            extra: jsonEncode(state.toJson()),
          ),
        ),
      );
    }

    report.events = finalizeEvents(report.events, ctx.pricing);
    return report;
  }

  static (CodexState, List<UsageEvent>, int)? parseCodexFile(
    ScanCtx ctx,
    String path, {
    List<OutputSpeedSample>? outputSpeeds,
  }) {
    final stored = ctx.store.getScanState(SourceIds.codex, ctx.instance, path);
    final size = fileSize(path);

    var state = CodexState();
    if (stored?.extra != null) {
      try {
        final decoded = jsonDecode(stored!.extra!);
        if (decoded is Map) {
          state = CodexState.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {}
    }

    if (size < state.offset) {
      state = CodexState();
    }
    if (state.offset >= size) return null;

    JsonlChunk chunk;
    try {
      chunk = readLinesFromOffset(path, state.offset, state.lineNo, size: size);
    } catch (_) {
      return null;
    }
    if (chunk.lines.isEmpty) return null;

    final stem = fileStem(path);
    final events = <UsageEvent>[];
    var skipped = 0;

    for (final (lineNo, line) in chunk.lines) {
      dynamic v;
      try {
        v = jsonDecode(line);
      } catch (_) {
        skipped += 1;
        continue;
      }
      if (v is! Map) continue;
      final lineType = v['type'] as String? ?? '';
      final payload = v['payload'];

      switch (lineType) {
        case 'session_meta':
          if (payload is Map) {
            final sid =
                (payload['session_id'] as String?) ?? (payload['id'] as String?);
            if (sid != null) state.sessionId = sid;
            final mp = payload['model_provider'] as String?;
            if (mp != null) state.provider = mp;
            final cwd = payload['cwd'] as String?;
            if (cwd != null) state.project = projectLabel(cwd);
          }
        case 'turn_context':
          if (payload is Map) {
            final m = payload['model'] as String?;
            if (m != null) state.model = m;
          }
        case 'event_msg':
          if (payload is! Map) continue;
          final ptype = payload['type'] as String? ?? '';
          final rawTurnId = payload['turn_id'];
          final turnId = rawTurnId is String ? rawTurnId : null;
          if (ptype == 'task_started') {
            state.outputTiming.start(
              parseTimestamp(payload['started_at']) ?? parseTimestamp(v['timestamp']),
              turnId ?? '$lineNo',
            );
          } else if (ptype == 'task_complete') {
            if (state.outputTiming.turnId.isEmpty || turnId == null || turnId == state.outputTiming.turnId) {
              if (state.outputTiming.turnId.isEmpty) state.outputTiming.turnId = turnId ?? '$lineNo';
              final samples = state.outputTiming.finish(
                source: SourceIds.codex, instance: ctx.instance, fileId: stem,
                completedAtMs: parseTimestamp(payload['completed_at']) ?? parseTimestamp(v['timestamp']),
                nativeDurationMs: payload['duration_ms'] is num
                    ? (payload['duration_ms'] as num).toInt() : null,
              );
              outputSpeeds?.addAll(samples);
            }
          } else if (ptype == 'turn_aborted') {
            if (turnId == null || turnId == state.outputTiming.turnId) state.outputTiming.clear();
          } else if (ptype == 'thread_settings_applied') {
            final ts = payload['thread_settings'];
            if (ts is Map) {
              final m = ts['model'] as String?;
              if (m != null) state.model = m;
              final p = ts['model_provider_id'] as String?;
              if (p != null) state.provider = p;
              final c = ts['cwd'] as String?;
              if (c != null) state.project = projectLabel(c);
            }
          } else if (ptype == 'token_count') {
            final info = payload['info'];
            if (info is! Map) continue;
            CumulativeTokens delta;
            final total = info['total_token_usage'];
            if (total is Map) {
              final cum =
                  CumulativeTokens.fromJson(Map<String, dynamic>.from(total));
              if (cum.sum < state.prev.sum) {
                state.prev = cum;
                state.outputTiming.valid = false;
                continue;
              }
              delta = cum.delta(state.prev);
              state.prev = cum;
            } else {
              final last = info['last_token_usage'];
              if (last is Map) {
                delta =
                    CumulativeTokens.fromJson(Map<String, dynamic>.from(last));
              } else {
                continue;
              }
            }
            if (delta.isZero) continue;
            state.outputTiming.add(state.model.isEmpty ? 'unknown' : state.model, delta.output);

            events.add(
              UsageEvent(
                source: SourceIds.codex,
                surface: SurfaceIds.cli,
                instance: ctx.instance,
                dedupKey: '$stem:$lineNo',
                sessionId: state.sessionId.isEmpty ? stem : state.sessionId,
                project: state.project,
                model: state.model.isEmpty ? 'unknown' : state.model,
                provider: state.provider.isEmpty ? 'openai' : state.provider,
                timestamp: parseTimestamp(v['timestamp']) ?? nowMs(),
                inputTokens: math.max(0, delta.input - delta.cachedInput),
                cacheReadTokens: delta.cachedInput,
                cacheWriteTokens: delta.cacheWrite,
                outputTokens: delta.output,
                reasoningTokens: delta.reasoning,
              ),
            );
          }
      }
    }

    state.offset = chunk.newOffset;
    state.lineNo = chunk.newLineNo;
    return (state, events, skipped);
  }
}
