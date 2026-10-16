import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glassusage/domain/models/settings_model.dart';
import 'package:glassusage/domain/models/usage_models.dart';
import 'package:glassusage/presentation/pages/dashboard_page.dart';
import 'package:glassusage/presentation/providers/app_providers.dart';

OverviewStats overview(int tokens, double cost) => OverviewStats(
  today: const TokenBreakdown(totalTokens: 111, costUsd: 1.11),
  yesterday: const TokenBreakdown(),
  thisWeek: const TokenBreakdown(),
  lastWeek: const TokenBreakdown(),
  range: TokenBreakdown(totalTokens: tokens, costUsd: cost),
  perSource: const [],
);

void main() {
  for (final zh in [true, false]) {
    testWidgets(
      'banner period label and totals stay aligned (${zh ? "zh" : "en"})',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final container = ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWith(
              (ref) => AppSettings(locale: zh ? LocaleMode.zh : LocaleMode.en),
            ),
            selectedRangeProvider.overrideWith((ref) => RangePreset.today),
            liveRatesProvider.overrideWith(
              (ref) => const LiveRates(
                tokensToday: 111,
                costToday: 1.11,
                tpm: 123,
                rpm: 4,
              ),
            ),
            overviewStatsProvider.overrideWith((ref) => overview(777, 7.77)),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: Scaffold(body: DashboardPage())),
          ),
        );
        await tester.pumpAndSettle();
        String caption() =>
            tester
                .widget<Text>(find.byKey(const ValueKey('live-period-label')))
                .data!;
        String value() =>
            tester
                .widget<Text>(find.byKey(const ValueKey('live-period-total')))
                .data!;
        expect(caption(), zh ? '今日 Token 消耗' : 'Tokens Today');
        expect(value(), r'111 · $1.11');
        final captions = {
          RangePreset.d7: zh ? '近 7 天 Token 消耗' : '7D Token Usage',
          RangePreset.d14: zh ? '近 14 天 Token 消耗' : '14D Token Usage',
          RangePreset.d30: zh ? '近 30 天 Token 消耗' : '30D Token Usage',
          RangePreset.d90: zh ? '近 90 天 Token 消耗' : '90D Token Usage',
          RangePreset.all: zh ? '累计 Token 消耗' : 'All-time Token Usage',
        };
        for (final entry in captions.entries) {
          final tokens = 700 + entry.key.index;
          final cost = 7.0 + entry.key.index;
          container.read(selectedRangeProvider.notifier).state = entry.key;
          container.read(overviewStatsProvider.notifier).state = overview(
            tokens,
            cost,
          );
          await tester.pumpAndSettle();
          expect(caption(), entry.value);
          final expected = '$tokens · \$${cost.toStringAsFixed(2)}';
          expect(value(), expected);
          // A live tick must not replace the selected-period cumulative totals.
          container.read(liveRatesProvider.notifier).state = const LiveRates(
            tokensToday: 999,
            costToday: 9.99,
            tpm: 345,
            rpm: 7,
          );
          await tester.pumpAndSettle();
          expect(value(), expected);
          expect(find.text('Tokens / min'), findsOneWidget);
          expect(find.text('Requests / min'), findsOneWidget);
        }
        container.read(selectedRangeProvider.notifier).state =
            RangePreset.today;
        await tester.pumpAndSettle();
        expect(caption(), zh ? '今日 Token 消耗' : 'Tokens Today');
        expect(value(), r'999 · $9.99');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('missing period data does not fall back to today totals', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(
      overrides: [
        selectedRangeProvider.overrideWith((ref) => RangePreset.d7),
        liveRatesProvider.overrideWith(
          (ref) => const LiveRates(tokensToday: 111, costToday: 1.11),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: DashboardPage())),
      ),
    );
    await tester.pumpAndSettle();
    final total = find.byKey(const ValueKey('live-period-total'));
    expect(tester.widget<Text>(total).data, '—');
    container.read(overviewStatsProvider.notifier).state = overview(777, 7.77);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(total).data, r'777 · $7.77');
    expect(tester.takeException(), isNull);
  });
}
