import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:glassusage/data/collectors/claude_collector.dart';
import 'package:glassusage/data/collectors/codex_collector.dart';
import 'package:glassusage/data/collectors/collector_base.dart';
import 'package:glassusage/data/collectors/opencode_collector.dart';
import 'package:glassusage/data/collectors/output_timing.dart';
import 'package:glassusage/data/database/app_database.dart';
import 'package:glassusage/data/live/output_speed_tracker.dart';
import 'package:glassusage/data/pricing/pricing_service.dart';
import 'package:glassusage/domain/models/output_speed.dart';
import 'package:glassusage/domain/models/settings_model.dart';
import 'package:glassusage/domain/models/usage_models.dart';
import 'package:glassusage/presentation/providers/app_providers.dart';
import 'package:glassusage/presentation/widgets/output_speed_card.dart';

final epoch = DateTime.utc(2026, 10, 16).millisecondsSinceEpoch;

extension _JsonlRows on List<String> {
  String get jsonl => '${join('\n')}\n';
}

extension _JsonlLine on String {
  String get jsonlLine => '$this\n';
}

String codexLine(String type, int ms, Map<String, dynamic> payload) =>
    jsonEncode({
      'type': type,
      'timestamp':
          DateTime.fromMillisecondsSinceEpoch(
            ms,
            isUtc: true,
          ).toIso8601String(),
      'payload': payload,
    });
String tokenLine(int output, int ms, {int input = 10000}) =>
    codexLine('event_msg', ms, {
      'type': 'token_count',
      'info': {
        'total_token_usage': {
          'input_tokens': input,
          'cached_input_tokens': input ~/ 2,
          'output_tokens': output,
          'reasoning_output_tokens': output ~/ 10,
        },
      },
    });
String claudeLine(String type, int ms, Map<String, dynamic> fields) =>
    jsonEncode({
      'type': type,
      'timestamp':
          DateTime.fromMillisecondsSinceEpoch(
            ms,
            isUtc: true,
          ).toIso8601String(),
      ...fields,
    });
String assistant(String id, int output, int ms, {String? stop}) =>
    claudeLine('assistant', ms, {
      'sessionId': 'fixture',
      'message': {
        'id': id,
        'model': 'claude-test',
        'stop_reason': stop,
        'usage': {
          'input_tokens': 10000,
          'cache_read_input_tokens': 20000,
          'output_tokens': output,
        },
      },
    });

OutputSpeedSample sample({
  String source = 'codex',
  String instance = 'local',
  String model = 'test-model',
  String id = 'one',
  int? duration = 10000,
  int output = 800,
  int? end,
  OutputTimingScope scope = OutputTimingScope.turn,
}) => OutputSpeedSample(
  source: source,
  instance: instance,
  model: model,
  requestId: id,
  outputTokens: output,
  completedAtMs: end ?? epoch + 10000,
  durationMs: duration,
  scope: scope,
);

void main() {
  group('collector timing', () {
    late Directory temp;
    late AppDatabase store;
    late ScanCtx ctx;
    setUp(() {
      temp = Directory.systemTemp.createTempSync('glassusage-output-speed-');
      store = AppDatabase.inMemory();
      ctx = ScanCtx(
        store: store,
        pricing: PricingService.forTest(prices: const {}, tempDir: temp.path),
        settings: AppSettings(),
        rootOverride: temp.path,
      );
    });
    tearDown(() {
      store.dispose();
      temp.deleteSync(recursive: true);
    });
    void commit(ScanReport report, Collector collector) =>
        store.ingestScan(report.events, collector.writeMode, report.states);

    test('Codex persists timing across scans and emits only at completion', () {
      final log = File('${temp.path}/codex.jsonl');
      final collector = CodexCollector();
      log.writeAsStringSync(
        [
          codexLine('turn_context', epoch - 1000, {'model': 'gpt-test'}),
          tokenLine(200, epoch - 1000),
          codexLine('event_msg', epoch, {
            'type': 'task_started',
            'turn_id': 'turn-1',
            'started_at': epoch,
          }),
          tokenLine(250, epoch + 2000, input: 20000),
        ].jsonl,
      );
      final first = collector.scan(ctx);
      expect(first.outputSpeeds, isEmpty);
      commit(first, collector);
      log.writeAsStringSync(
        [
          tokenLine(1000, epoch + 9000, input: 30000),
          codexLine('event_msg', epoch + 10000, {
            'type': 'task_complete',
            'turn_id': 'turn-1',
            'started_at': epoch,
            'completed_at': epoch + 10000,
            'duration_ms': 10000,
          }),
        ].jsonl,
        mode: FileMode.append,
      );
      final second = collector.scan(ctx);
      expect(second.outputSpeeds.single.outputTokens, 800);
      expect(second.outputSpeeds.single.tokensPerSecond, 80);
      expect(second.outputSpeeds.single.scope, OutputTimingScope.turn);
      expect(
        second.events.single.outputTokens,
        750,
      ); // Billing deltas unchanged.
      commit(second, collector);
      log.writeAsStringSync(
        codexLine('event_msg', epoch + 10000, {
          'type': 'task_complete',
          'turn_id': 'turn-1',
        }).jsonlLine,
        mode: FileMode.append,
      );
      expect(collector.scan(ctx).outputSpeeds, isEmpty);
    });

    test(
      'completion-only scan still delivers a speed with no new billing row',
      () {
        final log = File('${temp.path}/codex.jsonl');
        final collector = CodexCollector();
        log.writeAsStringSync(
          [
            codexLine('turn_context', epoch, {'model': 'gpt-test'}),
            codexLine('event_msg', epoch, {
              'type': 'task_started',
              'turn_id': 't',
            }),
            tokenLine(100, epoch + 5000),
          ].jsonl,
        );
        commit(collector.scan(ctx), collector);
        log.writeAsStringSync(
          codexLine('event_msg', epoch + 10000, {
            'type': 'task_complete',
            'turn_id': 't',
            'duration_ms': 10000,
          }).jsonlLine,
          mode: FileMode.append,
        );
        final done = collector.scan(ctx);
        expect(done.events, isEmpty);
        expect(done.outputSpeeds.single.tokensPerSecond, 10);
      },
    );

    test(
      'Codex rejects aborted turns and does not guess missing-start duration',
      () {
        final log = File('${temp.path}/codex.jsonl');
        log.writeAsStringSync(
          [
            codexLine('turn_context', epoch, {'model': 'gpt-test'}),
            codexLine('event_msg', epoch, {
              'type': 'task_started',
              'turn_id': 'aborted',
            }),
            tokenLine(100, epoch + 2000),
            codexLine('event_msg', epoch + 3000, {
              'type': 'turn_aborted',
              'turn_id': 'aborted',
            }),
            tokenLine(300, epoch + 4000),
            codexLine('event_msg', epoch + 5000, {
              'type': 'task_complete',
              'turn_id': 'missing',
              'duration_ms': 5000,
            }),
          ].jsonl,
        );
        final result = CodexCollector().scan(ctx);
        expect(result.outputSpeeds, hasLength(1));
        expect(result.outputSpeeds.single.tokensPerSecond, isNull);
      },
    );

    test(
      'Claude cumulative message updates and tool results keep correct turn timing',
      () {
        final log = File('${temp.path}/claude.jsonl');
        final collector = ClaudeCollector();
        log.writeAsStringSync(
          [
            claudeLine('user', epoch, {
              'uuid': 'u1',
              'message': {'content': 'fixture'},
            }),
            assistant('m1', 50, epoch + 1000),
          ].jsonl,
        );
        final first = collector.scan(ctx);
        expect(first.outputSpeeds, isEmpty);
        commit(first, collector);
        log.writeAsStringSync(
          [
            claudeLine('user', epoch + 2000, {
              'message': {
                'content': [
                  {'type': 'tool_result'},
                ],
              },
            }),
            assistant('m1', 120, epoch + 3000),
            assistant('m2', 80, epoch + 10000, stop: 'end_turn'),
            claudeLine('system', epoch + 10100, {
              'subtype': 'turn_duration',
              'durationMs': 10000,
            }),
          ].jsonl,
          mode: FileMode.append,
        );
        final second = collector.scan(ctx);
        expect(second.outputSpeeds.single.outputTokens, 200);
        expect(second.outputSpeeds.single.durationMs, 10000);
        expect(second.outputSpeeds.single.tokensPerSecond, 20);
        commit(second, collector);
        expect(collector.scan(ctx).outputSpeeds, isEmpty);
      },
    );

    test(
      'OpenCode uses completed-created, never row updated or session lifetime',
      () {
        final path = '${temp.path}/opencode.db';
        final db = sqlite3.open(path);
        db.execute(
          'CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)',
        );
        for (final done in [true, false]) {
          db.execute('INSERT INTO message VALUES (?, ?, ?, ?, ?)', [
            done ? 'done' : 'streaming',
            's',
            epoch,
            epoch + 100000,
            jsonEncode({
              'role': 'assistant',
              'modelID': 'oc-test',
              'time': {'created': epoch, if (done) 'completed': epoch + 4000},
              'tokens': {
                'input': 50000,
                'output': 100,
                'cache': {'read': 60000},
              },
            }),
          ]);
        }
        db.dispose();
        final report = OpenCodeCollector.scanDb(ctx, path);
        expect(report.outputSpeeds, hasLength(1));
        expect(report.outputSpeeds.single.scope, OutputTimingScope.response);
        expect(report.outputSpeeds.single.tokensPerSecond, 25);
      },
    );
  });

  test(
    'turn state marks mixed models, resets and invalid durations unavailable',
    () {
      final state = OutputTurnState()..start(epoch, 'turn');
      state.add('a', 100);
      state.add('b', 100);
      final mixed = state.finish(
        source: 'codex',
        instance: 'local',
        fileId: 'f',
        completedAtMs: epoch + 1000,
      );
      expect(mixed, hasLength(2));
      expect(mixed.every((s) => s.tokensPerSecond == null), isTrue);
      state.start(epoch, 'reset');
      state.add('a', 100);
      state.valid = false;
      expect(
        state
            .finish(
              source: 'codex',
              instance: 'local',
              fileId: 'f',
              completedAtMs: epoch + 1000,
            )
            .single
            .tokensPerSecond,
        isNull,
      );
      expect(sample(duration: 0).tokensPerSecond, isNull);
      expect(sample(duration: -1).tokensPerSecond, isNull);
      expect(sample(duration: 86400001).tokensPerSecond, isNull);
    },
  );

  test(
    'tracker excludes polling, remote, startup history and future records',
    () {
      final tracker = OutputSpeedTracker(startedAtMs: epoch);
      tracker.observe(
        [sample(source: 'cursor')],
        source: 'cursor',
        instance: 'local',
        isRealtime: true,
        nowMs: epoch + 10000,
      );
      tracker.observe(
        [sample()],
        source: 'codex',
        instance: 'local',
        isRealtime: false,
        nowMs: epoch + 10000,
      );
      tracker.observe(
        [sample(instance: 'remote')],
        source: 'codex',
        instance: 'remote',
        isRealtime: true,
        nowMs: epoch + 10000,
      );
      tracker.observe(
        [sample(end: epoch - 1), sample(end: epoch + 20000)],
        source: 'codex',
        instance: 'local',
        isRealtime: true,
        nowMs: epoch + 10000,
      );
      expect(tracker.snapshot(nowMs: epoch + 10000), isEmpty);
      tracker.observe(
        [sample()],
        source: 'codex',
        instance: 'local',
        isRealtime: true,
        nowMs: epoch + 10000,
      );
      expect(tracker.snapshot(nowMs: epoch + 10000).single.tokensPerSecond, 80);
    },
  );

  test(
    'tracker deduplicates, upgrades corrected timing and never rolls back to an older reply',
    () {
      final tracker = OutputSpeedTracker(startedAtMs: epoch);
      void observe(List<OutputSpeedSample> samples) => tracker.observe(
        samples,
        source: 'codex',
        instance: 'local',
        isRealtime: true,
        nowMs: epoch + 20000,
      );
      observe([sample(duration: null), sample(duration: null)]);
      expect(tracker.snapshot(nowMs: epoch + 20000), hasLength(1));
      observe([sample()]);
      expect(tracker.snapshot(nowMs: epoch + 20000).single.tokensPerSecond, 80);
      observe([sample(id: 'new', end: epoch + 20000, output: 200)]);
      observe([sample(id: 'older')]);
      expect(tracker.snapshot(nowMs: epoch + 20000).single.requestId, 'new');
      observe(
        List.generate(
          30,
          (i) => sample(model: 'model-$i', id: 'shared', end: epoch + 20000),
        ),
      );
      expect(tracker.snapshot(nowMs: epoch + 20000), hasLength(12));
      expect(tracker.snapshot(nowMs: epoch + 2000000), isEmpty);
    },
  );

  test(
    'speed samples survive live-tick JSON and copyWith, old payloads remain valid',
    () {
      final rates = LiveRates(
        outputSpeeds: [sample()],
      ).copyWith(budgetTokensToday: 50);
      final parsed = LiveRates.fromJson(
        jsonDecode(jsonEncode(rates.toJson())) as Map<String, dynamic>,
      );
      expect(parsed.outputSpeeds.single.tokensPerSecond, 80);
      expect(parsed.outputSpeeds.single.model, 'test-model');
      expect(LiveRates.fromJson(const {}).outputSpeeds, isEmpty);
    },
  );

  testWidgets(
    'card displays model averages, missing timing and independent range behavior',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            (ref) => AppSettings(locale: LocaleMode.zh),
          ),
          liveRatesProvider.overrideWith(
            (ref) => LiveRates(
              outputSpeeds: [
                sample(end: DateTime.now().millisecondsSinceEpoch),
                sample(
                  source: 'opencode',
                  model: 'oc-test',
                  duration: 4000,
                  output: 130,
                  scope: OutputTimingScope.response,
                  end: DateTime.now().millisecondsSinceEpoch,
                ),
                sample(
                  model: 'no-timing',
                  duration: null,
                  end: DateTime.now().millisecondsSinceEpoch,
                ),
              ],
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(width: 760, child: OutputSpeedCard()),
            ),
          ),
        ),
      );
      expect(find.text('80.0 token/s'), findsOneWidget);
      expect(find.text('32.5 token/s'), findsOneWidget);
      expect(find.text('不可测：缺少可靠耗时'), findsOneWidget);
      expect(find.text('test-model'), findsOneWidget);
      container.read(selectedRangeProvider.notifier).state = RangePreset.all;
      await tester.pump();
      expect(find.text('80.0 token/s'), findsOneWidget);
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pump();
      expect(find.text('80.0 token/s'), findsOneWidget);
      expect(tester.takeException(), isNull);
      container.read(liveRatesProvider.notifier).state = const LiveRates();
      await tester.pump();
      expect(find.textContaining('等待本地 Codex'), findsOneWidget);
      expect(find.text('0.0 token/s'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
