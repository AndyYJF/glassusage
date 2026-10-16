import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glassusage/data/pricing/pricing_service.dart';

Map<String, ModelPrice> _prices(List<(String, double, double)> pairs) {
  final out = <String, ModelPrice>{};
  for (final (k, i, o) in pairs) {
    out[k] = ModelPrice(
      inputCostPerToken: i,
      outputCostPerToken: o,
    );
  }
  return out;
}

String? _norm(Map<String, ModelPrice> prices, String raw) {
  return PricingService.normalizeWith(
    prices: prices,
    overrides: const {},
    aliases: PricingService.builtinAliases(),
    raw: raw,
  );
}

void main() {
  test('normalizes_through_each_layer', () {
    final t = _prices([
      ('claude-sonnet-4', 1.0, 2.0),
      ('gpt-5-2025-08-07', 1.0, 2.0),
      ('gemini-2.5-pro', 1.0, 2.0),
    ]);

    expect(_norm(t, 'Claude-Sonnet-4'), 'claude-sonnet-4');
    expect(_norm(t, 'anthropic/claude-sonnet-4'), 'claude-sonnet-4');
    expect(_norm(t, 'claude-sonnet-4-20250514'), 'claude-sonnet-4');
    expect(_norm(t, 'gemini-pro-default'), 'gemini-2.5-pro');

    final tKimi = _prices([('kimi-k3', 3e-6, 1.5e-5)]);
    expect(_norm(tKimi, 'kimi-code/k3'), 'kimi-k3');
    expect(_norm(tKimi, 'k3'), 'kimi-k3');

    final tGrok = _prices([
      ('grok-4', 3e-6, 1.5e-5),
      ('grok-4.6', 2e-6, 6e-6),
    ]);
    expect(_norm(tGrok, 'grok-4.6'), 'grok-4.6');
    expect(_norm(tGrok, 'xai/grok-4.6'), 'grok-4.6');

    expect(_norm(_prices([('x-1234', 1.0, 1.0)]), 'gemini-pro-default'), isNull);
  });

  test('unknown_model_has_no_price_rather_than_zero', () {
    final t = _prices([('claude-sonnet-4', 1e-6, 2e-6)]);
    expect(_norm(t, 'some-unreleased-thing'), isNull);

    final dir = Directory.systemTemp.createTempSync('glassusage-pricing-test-');
    try {
      final pSvc = PricingService.forTest(
        prices: t,
        tempDir: dir.path,
      );
      expect(pSvc.normalize('some-unreleased-thing'), 'some-unreleased-thing');
      expect(pSvc.cost('some-unreleased-thing', 1000, 1000, 0, 0), isNull);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('cache_usage_without_explicit_rates_is_unpriced', () {
    final dir = Directory.systemTemp.createTempSync('glassusage-pricing-test-');
    try {
      final pSvc = PricingService.forTest(
        prices: _prices([('m', 10.0, 100.0)]),
        tempDir: dir.path,
      );
      expect(pSvc.cost('m', 1, 1, 1, 1), isNull);
      expect(pSvc.cost('m', 1, 1, 0, 0), 110.0);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('overrides_beat_the_fetched_table', () {
    final dir = Directory.systemTemp.createTempSync('glassusage-pricing-test-');
    try {
      final pSvc = PricingService.forTest(
        prices: _prices([('m', 10.0, 10.0)]),
        overrides: {
          'm': const ModelPrice(
            inputCostPerToken: 1.0,
            outputCostPerToken: 1.0,
          ),
        },
        tempDir: dir.path,
      );
      expect(pSvc.cost('m', 1, 0, 0, 0), 1.0);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('refresh_does_not_drop_models_only_the_fallback_knows', () {
    final bundled = PricingService.parseLiteLlm(kBundledFallbackPricingJson);
    expect(bundled, isNotEmpty);
    final onlyBundled = bundled.keys.first;

    final merged = PricingService.mergeOverFallback(const {});
    expect(merged.containsKey(onlyBundled), isTrue);

    final fetched = {
      onlyBundled: const ModelPrice(inputCostPerToken: 42.0),
    };
    expect(
      PricingService.mergeOverFallback(fetched)[onlyBundled]!.inputCostPerToken,
      42.0,
    );
  });

  test('free_models_are_not_indexed_as_priced', () {
    final parsed = PricingService.parseLiteLlm(
      r'{"free-thing":{"input_cost_per_token":0,"output_cost_per_token":0}}',
    );
    expect(parsed, isEmpty);
  });
}
