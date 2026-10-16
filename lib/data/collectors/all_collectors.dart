import 'antigravity_collector.dart';
import 'claude_collector.dart';
import 'codex_collector.dart';
import 'collector_base.dart';
import 'cursor_collector.dart';
import 'dsh_collector.dart';
import 'hermes_collector.dart';
import 'kimi_collector.dart';
import 'openclaw_collector.dart';
import 'opencode_collector.dart';
import 'pi_collector.dart';

final List<Collector> _collectors = [
  ClaudeCollector(),
  CodexCollector(),
  CursorCollector(),
  AntigravityCollector(),
  OpenCodeCollector(),
  HermesCollector(),
  OpenClawCollector(),
  PiCollector(),
  KimiCollector(),
  DshCollector(),
];

List<Collector> allCollectors() => _collectors;

Collector? collectorById(String id) {
  for (final c in _collectors) {
    if (c.id == id) return c;
  }
  return null;
}
