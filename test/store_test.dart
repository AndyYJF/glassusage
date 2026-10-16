import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glassusage/data/database/app_database.dart';
import 'package:glassusage/data/pricing/pricing_service.dart';
import 'package:glassusage/domain/models/usage_models.dart';

void main() {
  test('ingest_scan_commits_events_and_watermarks_together', () {
    final dir = Directory.systemTemp.createTempSync('glassusage-store-test-');
    try {
      final store = AppDatabase.open(dir.path);
      try {
        final now = AppDatabase.nowMs();
        final event = UsageEvent(
          source: SourceIds.claude,
          surface: SurfaceIds.cli,
          instance: kLocalInstance,
          model: 'claude-sonnet-4',
          modelNorm: 'claude-sonnet-4',
          timestamp: now,
          inputTokens: 12,
          outputTokens: 8,
          costUsd: 0.42,
          dedupKey: 'claude:1',
        );
        const state = PendingScanState(
          source: SourceIds.claude,
          instance: kLocalInstance,
          key: 'session.jsonl',
          state: ScanState(offset: 128, mtimeMs: 456, extra: '{"line_no":1}'),
        );

        final outcome = store.ingestScan(
          [event],
          WriteMode.insertOrIgnore,
          [state],
        );
        expect(outcome.changed, 1);
        expect(
          store.getScanState(SourceIds.claude, kLocalInstance, 'session.jsonl')?.offset,
          128,
        );
        final overview = store.overview(0, now + 60000);
        expect(overview.today.totalTokens, 20);
        expect(overview.today.events, 1);
      } finally {
        store.dispose();
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('upsert_refreshes_daily_rollup_without_double_counting', () {
    final dir = Directory.systemTemp.createTempSync('glassusage-store-upsert-');
    try {
      final store = AppDatabase.open(dir.path);
      try {
        final now = AppDatabase.nowMs();
        final ev1 = UsageEvent(
          source: SourceIds.opencode,
          surface: SurfaceIds.cli,
          instance: kLocalInstance,
          model: 'claude-sonnet-4',
          modelNorm: 'claude-sonnet-4',
          timestamp: now,
          inputTokens: 10,
          outputTokens: 5,
          costUsd: 0.10,
          dedupKey: 'oc:msg1',
        );
        final out1 = store.ingest([ev1], WriteMode.upsert);
        expect(out1.changed, 1);
        expect(store.overview(0, now + 60000).today.totalTokens, 15);

        final ev2 = ev1.copyWith(
          inputTokens: 10,
          outputTokens: 25,
          costUsd: 0.30,
        );
        final out2 = store.ingest([ev2], WriteMode.upsert);
        expect(out2.changed, 1);
        expect(out2.deltas.single.tokens, 20);
        expect(out2.deltas.single.isNewRequest, isFalse);

        final ov = store.overview(0, now + 60000);
        expect(ov.today.totalTokens, 35);
        expect(ov.today.events, 1);
      } finally {
        store.dispose();
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('reprice_recomputes_cost_and_rebuilds_daily_rollup', () {
    final dir = Directory.systemTemp.createTempSync('glassusage-store-reprice-');
    try {
      final store = AppDatabase.open(dir.path);
      try {
        final now = AppDatabase.nowMs();
        final ev = UsageEvent(
          source: SourceIds.claude,
          surface: SurfaceIds.cli,
          instance: kLocalInstance,
          model: 'custom-model',
          modelNorm: 'custom-model',
          timestamp: now,
          inputTokens: 1000,
          outputTokens: 500,
          costUsd: null,
          dedupKey: 'claude:unpriced1',
        );
        store.ingest([ev], WriteMode.insertOrIgnore);
        final ovBefore = store.overview(0, now + 60000);
        expect(ovBefore.today.unpricedEvents, 1);
        expect(ovBefore.today.costUsd, 0.0);

        final pricing = PricingService.forTest(
          prices: {
            'custom-model': const ModelPrice(
              inputCostPerToken: 0.001,
              outputCostPerToken: 0.002,
            ),
          },
          tempDir: dir.path,
        );
        final updated = store.reprice(pricing);
        expect(updated, 1);

        final ovAfter = store.overview(0, now + 60000);
        expect(ovAfter.today.unpricedEvents, 0);
        expect(ovAfter.today.costUsd, closeTo(2.0, 1e-6));
      } finally {
        store.dispose();
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
