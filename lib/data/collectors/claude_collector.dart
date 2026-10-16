import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../database/app_database.dart';
import 'collector_base.dart';

class ClaudeCollector extends Collector {
  @override
  String get id => SourceIds.claude;

  @override
  String get label => 'Claude Code';

  @override
  WriteMode get writeMode => WriteMode.upsert;

  static String configRoot(AppSettings settings) {
    return resolveRoot(
      settings,
      SourceIds.claude,
      'CLAUDE_CONFIG_DIR',
      p.join(homeDir(), '.claude'),
    );
  }

  static List<String> transcriptRoots(AppSettings settings) {
    final base = configRoot(settings);
    return [p.join(base, 'projects'), p.join(base, 'transcripts')]
        .where((dir) => Directory(dir).existsSync())
        .toList();
  }

  static List<String> desktopMetaRoots() {
    final roots = <String>[];
    final cfg = configDir();
    if (cfg != null) {
      roots.add(p.join(cfg, 'Claude', 'claude-code-sessions'));
    }
    final local = localDataDir();
    if (local != null) {
      final packagesDir = Directory(p.join(local, 'Packages'));
      if (packagesDir.existsSync()) {
        try {
          for (final entry in packagesDir.listSync(followLinks: false)) {
            final name = p.basename(entry.path);
            if (name.startsWith('Claude_')) {
              roots.add(
                p.join(
                  entry.path,
                  'LocalCache',
                  'Roaming',
                  'Claude',
                  'claude-code-sessions',
                ),
              );
            }
          }
        } catch (_) {}
      }
    }
    return roots.where((dir) => Directory(dir).existsSync()).toList();
  }

  static Set<String> desktopSessionIds() {
    final ids = <String>{};
    for (final root in desktopMetaRoots()) {
      for (final file in findFiles(root, (f) => hasExt(f, 'json'))) {
        try {
          final v = jsonDecode(File(file).readAsStringSync());
          _collectCliSessionIds(v, ids);
        } catch (_) {}
      }
    }
    return ids;
  }

  static void _collectCliSessionIds(dynamic v, Set<String> out) {
    if (v is Map) {
      v.forEach((k, val) {
        if (k == 'cliSessionId' && val is String) {
          out.add(val);
        } else {
          _collectCliSessionIds(val, out);
        }
      });
    } else if (v is List) {
      for (final item in v) {
        _collectCliSessionIds(item, out);
      }
    }
  }

  @override
  List<String> detect(AppSettings settings) {
    return [
      ...transcriptRoots(settings),
      ...desktopMetaRoots(),
    ];
  }

  @override
  List<String> watchPaths(AppSettings settings) => transcriptRoots(settings);

  @override
  ScanReport scan(ScanCtx ctx) {
    final roots = ctx.rootOverride != null
        ? [ctx.rootOverride!]
        : transcriptRoots(ctx.settings);
    if (roots.isEmpty) return ScanReport();

    final desktopIds = desktopSessionIds();
    final files = <String>[];
    for (final r in roots) {
      files.addAll(findFiles(r, (f) => hasExt(f, 'jsonl')));
    }

    final report = ScanReport(
      filesSeen: files.length,
      detectedPaths: List.from(roots),
    );

    for (final path in files) {
      JsonlChunk chunk;
      try {
        chunk = readNewLines(ctx.store, SourceIds.claude, ctx.instance, path);
      } catch (_) {
        continue;
      }
      if (chunk.lines.isEmpty) continue;
      final (events, skipped) =
          parseClaudeLines(chunk, path, desktopIds, ctx.instance);
      report.events.addAll(events);
      report.skipped += skipped;
      report.states.add(
        pendingScanState(SourceIds.claude, ctx.instance, path, chunk),
      );
    }

    report.events = finalizeEvents(report.events, ctx.pricing);
    return report;
  }

  static (List<UsageEvent>, int) parseClaudeLines(
    JsonlChunk chunk,
    String path,
    Set<String> desktopIds,
    String instance,
  ) {
    final stem = fileStem(path);
    final byKey = <String, UsageEvent>{};
    final order = <String>[];
    var skipped = 0;

    for (final (_, line) in chunk.lines) {
      dynamic v;
      try {
        v = jsonDecode(line);
      } catch (_) {
        skipped += 1;
        continue;
      }
      if (v is! Map) continue;
      if (v['type'] != 'assistant') continue;
      final message = v['message'];
      if (message is! Map) continue;
      final usage = message['usage'];
      if (usage is! Map) continue;

      int numField(String k) {
        final x = usage[k];
        return (x is num) ? x.toInt() : 0;
      }

      final input = numField('input_tokens');
      final output = numField('output_tokens');
      final cacheWrite = numField('cache_creation_input_tokens');
      final cacheRead = numField('cache_read_input_tokens');
      if (input + output + cacheWrite + cacheRead == 0) continue;

      final messageId = (message['id'] as String?) ??
          (v['uuid'] as String?) ??
          '';
      final requestId = (v['requestId'] as String?) ??
          (v['request_id'] as String?) ??
          '';
      if (messageId.isEmpty && requestId.isEmpty) {
        skipped += 1;
        continue;
      }
      final dedupKey = '$stem:$messageId:$requestId';

      final sessionId = (v['sessionId'] as String?) ??
          (v['session_id'] as String?) ??
          stem;

      final surfaceLabel = desktopIds.contains(sessionId)
          ? SurfaceIds.desktop
          : SurfaceIds.cli;

      final event = UsageEvent(
        source: SourceIds.claude,
        surface: surfaceLabel,
        instance: instance,
        dedupKey: dedupKey,
        sessionId: sessionId,
        project: projectLabel(v['cwd'] as String?),
        model: (message['model'] as String?) ?? 'unknown',
        provider: 'anthropic',
        timestamp: parseTimestamp(v['timestamp']) ?? nowMs(),
        inputTokens: input,
        outputTokens: output,
        cacheReadTokens: cacheRead,
        cacheWriteTokens: cacheWrite,
      );

      if (!byKey.containsKey(dedupKey)) {
        order.add(dedupKey);
      }
      byKey[dedupKey] = event;
    }

    final events = [
      for (final k in order)
        if (byKey.containsKey(k)) byKey[k]!,
    ];
    return (events, skipped);
  }
}
