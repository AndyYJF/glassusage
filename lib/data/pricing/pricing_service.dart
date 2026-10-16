import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../domain/models/usage_models.dart';

const String kLiteLlmUrl =
    'https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json';
const int kCacheTtlMs = 24 * 60 * 60 * 1000;

/// Bundled offline fallback prices so a first run with no network still costs
/// models accurately.
const String kBundledFallbackPricingJson = r'''
{
  "_comment": "Offline fallback subset of LiteLLM model_prices_and_context_window.json.",
  "claude-opus-4-1": { "input_cost_per_token": 1.5e-5, "output_cost_per_token": 7.5e-5, "cache_creation_input_token_cost": 1.875e-5, "cache_read_input_token_cost": 1.5e-6 },
  "claude-opus-4-20250514": { "input_cost_per_token": 1.5e-5, "output_cost_per_token": 7.5e-5, "cache_creation_input_token_cost": 1.875e-5, "cache_read_input_token_cost": 1.5e-6 },
  "claude-opus-4-5": { "input_cost_per_token": 5e-6, "output_cost_per_token": 2.5e-5, "cache_creation_input_token_cost": 6.25e-6, "cache_read_input_token_cost": 5e-7 },
  "claude-sonnet-4-20250514": { "input_cost_per_token": 3e-6, "output_cost_per_token": 1.5e-5, "cache_creation_input_token_cost": 3.75e-6, "cache_read_input_token_cost": 3e-7 },
  "claude-sonnet-4-5": { "input_cost_per_token": 3e-6, "output_cost_per_token": 1.5e-5, "cache_creation_input_token_cost": 3.75e-6, "cache_read_input_token_cost": 3e-7 },
  "claude-sonnet-4-5-20250929": { "input_cost_per_token": 3e-6, "output_cost_per_token": 1.5e-5, "cache_creation_input_token_cost": 3.75e-6, "cache_read_input_token_cost": 3e-7 },
  "claude-haiku-4-5": { "input_cost_per_token": 1e-6, "output_cost_per_token": 5e-6, "cache_creation_input_token_cost": 1.25e-6, "cache_read_input_token_cost": 1e-7 },
  "claude-3-5-sonnet-20241022": { "input_cost_per_token": 3e-6, "output_cost_per_token": 1.5e-5, "cache_creation_input_token_cost": 3.75e-6, "cache_read_input_token_cost": 3e-7 },
  "claude-3-5-haiku-20241022": { "input_cost_per_token": 8e-7, "output_cost_per_token": 4e-6, "cache_creation_input_token_cost": 1e-6, "cache_read_input_token_cost": 8e-8 },
  "claude-3-7-sonnet-20250219": { "input_cost_per_token": 3e-6, "output_cost_per_token": 1.5e-5, "cache_creation_input_token_cost": 3.75e-6, "cache_read_input_token_cost": 3e-7 },
  "gpt-5-2025-08-07": { "input_cost_per_token": 1.25e-6, "output_cost_per_token": 1e-5, "cache_read_input_token_cost": 1.25e-7 },
  "gpt-5-mini": { "input_cost_per_token": 2.5e-7, "output_cost_per_token": 2e-6, "cache_read_input_token_cost": 2.5e-8 },
  "gpt-5-nano": { "input_cost_per_token": 5e-8, "output_cost_per_token": 4e-7, "cache_read_input_token_cost": 5e-9 },
  "gpt-5-codex": { "input_cost_per_token": 1.25e-6, "output_cost_per_token": 1e-5, "cache_read_input_token_cost": 1.25e-7 },
  "gpt-4.1": { "input_cost_per_token": 2e-6, "output_cost_per_token": 8e-6, "cache_read_input_token_cost": 5e-7 },
  "gpt-4o": { "input_cost_per_token": 2.5e-6, "output_cost_per_token": 1e-5, "cache_read_input_token_cost": 1.25e-6 },
  "gpt-4o-mini": { "input_cost_per_token": 1.5e-7, "output_cost_per_token": 6e-7, "cache_read_input_token_cost": 7.5e-8 },
  "o3": { "input_cost_per_token": 2e-6, "output_cost_per_token": 8e-6, "cache_read_input_token_cost": 5e-7 },
  "o4-mini": { "input_cost_per_token": 1.1e-6, "output_cost_per_token": 4.4e-6, "cache_read_input_token_cost": 2.75e-7 },
  "gemini-2.5-pro": { "input_cost_per_token": 1.25e-6, "output_cost_per_token": 1e-5, "cache_read_input_token_cost": 3.125e-7 },
  "gemini-2.5-flash": { "input_cost_per_token": 3e-7, "output_cost_per_token": 2.5e-6, "cache_read_input_token_cost": 7.5e-8 },
  "gemini-2.5-flash-lite": { "input_cost_per_token": 1e-7, "output_cost_per_token": 4e-7, "cache_read_input_token_cost": 2.5e-8 },
  "gemini-3-pro-preview": { "input_cost_per_token": 2e-6, "output_cost_per_token": 1.2e-5, "cache_read_input_token_cost": 2e-7 },
  "deepseek-chat": { "input_cost_per_token": 2.7e-7, "output_cost_per_token": 1.1e-6, "cache_read_input_token_cost": 7e-8 },
  "deepseek-reasoner": { "input_cost_per_token": 5.5e-7, "output_cost_per_token": 2.19e-6, "cache_read_input_token_cost": 1.4e-7 },
  "kimi-k2-0905-preview": { "input_cost_per_token": 6e-7, "output_cost_per_token": 2.5e-6, "cache_read_input_token_cost": 1.5e-7 },
  "kimi-k3": { "input_cost_per_token": 3e-6, "output_cost_per_token": 1.5e-5, "cache_read_input_token_cost": 3e-7 },
  "grok-4": { "input_cost_per_token": 3e-6, "output_cost_per_token": 1.5e-5, "cache_read_input_token_cost": 7.5e-7 },
  "grok-4.6": { "input_cost_per_token": 2e-6, "output_cost_per_token": 6e-6, "cache_read_input_token_cost": 5e-7 },
  "grok-code-fast-1": { "input_cost_per_token": 2e-7, "output_cost_per_token": 1.5e-6, "cache_read_input_token_cost": 2e-8 },
  "qwen3-coder-plus": { "input_cost_per_token": 1e-6, "output_cost_per_token": 5e-6, "cache_read_input_token_cost": 1e-7 },
  "glm-4.6": { "input_cost_per_token": 6e-7, "output_cost_per_token": 2.2e-6, "cache_read_input_token_cost": 1.1e-7 },
  "glm-5.2": { "input_cost_per_token": 1.4e-6, "output_cost_per_token": 4.4e-6, "cache_read_input_token_cost": 2.6e-7 },
  "gemini-3-flash": { "input_cost_per_token": 5e-7, "output_cost_per_token": 3e-6, "cache_read_input_token_cost": 5e-8 },
  "gpt-5.5": { "input_cost_per_token": 5e-6, "output_cost_per_token": 3e-5, "cache_read_input_token_cost": 5e-7 },
  "gpt-5.6-sol": { "input_cost_per_token": 5e-6, "output_cost_per_token": 3e-5, "cache_read_input_token_cost": 5e-7 },
  "gpt-5.6-terra": { "input_cost_per_token": 2.5e-6, "output_cost_per_token": 1.5e-5, "cache_read_input_token_cost": 2.5e-7 },
  "ark-code-latest": { "input_cost_per_token": 3.4e-7, "output_cost_per_token": 3.4e-6, "cache_read_input_token_cost": 3.4e-8 },
  "codex-auto-review": { "input_cost_per_token": 2.5e-7, "output_cost_per_token": 2e-6, "cache_read_input_token_cost": 2.5e-8 }
}
''';

class ModelPrice {
  final double inputCostPerToken;
  final double outputCostPerToken;
  final double cacheCreationInputTokenCost;
  final double cacheReadInputTokenCost;

  const ModelPrice({
    this.inputCostPerToken = 0.0,
    this.outputCostPerToken = 0.0,
    this.cacheCreationInputTokenCost = 0.0,
    this.cacheReadInputTokenCost = 0.0,
  });

  Map<String, dynamic> toJson() => {
    'input_cost_per_token': inputCostPerToken,
    'output_cost_per_token': outputCostPerToken,
    'cache_creation_input_token_cost': cacheCreationInputTokenCost,
    'cache_read_input_token_cost': cacheReadInputTokenCost,
  };

  factory ModelPrice.fromJson(Map<String, dynamic> json) {
    return ModelPrice(
      inputCostPerToken:
          (json['input_cost_per_token'] as num?)?.toDouble() ?? 0.0,
      outputCostPerToken:
          (json['output_cost_per_token'] as num?)?.toDouble() ?? 0.0,
      cacheCreationInputTokenCost:
          (json['cache_creation_input_token_cost'] as num?)?.toDouble() ?? 0.0,
      cacheReadInputTokenCost:
          (json['cache_read_input_token_cost'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class PricingInfo {
  final int modelCount;
  final String source;
  final Map<String, ModelPrice> overrides;

  const PricingInfo({
    required this.modelCount,
    required this.source,
    required this.overrides,
  });
}

/// Sources that report authoritative money amounts, which must not be overwritten by the
/// estimated price table.
bool sourceHasNativeCost(String source) {
  return source == SourceIds.cursor ||
      source == SourceIds.hermes ||
      source == SourceIds.pi ||
      source == SourceIds.openclaw ||
      source == SourceIds.opencode;
}

class PricingService {
  final String cachePath;
  final String overridesPath;
  Map<String, ModelPrice> _prices = {};
  Map<String, ModelPrice> _overrides = {};
  Map<String, String> _aliases = builtinAliases();
  String _sourceLabel = 'builtin';

  PricingService(String dataDir)
    : cachePath = p.join(dataDir, 'pricing-cache.json'),
      overridesPath = p.join(dataDir, 'pricing_overrides.json') {
    _loadFromDisk();
  }

  /// Test constructor for unit testing custom price tables without network.
  PricingService.forTest({
    required Map<String, ModelPrice> prices,
    Map<String, ModelPrice>? overrides,
    Map<String, String>? aliases,
    required String tempDir,
  }) : cachePath = p.join(tempDir, 'cache.json'),
       overridesPath = p.join(tempDir, 'overrides.json'),
       _prices = Map.from(prices),
       _overrides = Map.from(overrides ?? const {}),
       _aliases = Map.from(aliases ?? builtinAliases()),
       _sourceLabel = 'test';

  void _loadFromDisk() {
    _aliases = builtinAliases();
    String? cached;
    final cacheFile = File(cachePath);
    if (cacheFile.existsSync()) {
      try {
        final modified = cacheFile.lastModifiedSync();
        final ageMs = DateTime.now().difference(modified).inMilliseconds;
        if (ageMs < kCacheTtlMs) {
          cached = cacheFile.readAsStringSync();
        }
      } catch (_) {}
    }

    if (cached != null) {
      _prices = mergeOverFallback(parseLiteLlm(cached));
      _sourceLabel = 'cache';
    } else {
      _prices = mergeOverFallback(const {});
      _sourceLabel = 'builtin';
    }

    final overridesFile = File(overridesPath);
    if (overridesFile.existsSync()) {
      try {
        final decoded = jsonDecode(overridesFile.readAsStringSync());
        if (decoded is Map) {
          _overrides = {
            for (final e in decoded.entries)
              if (e.key is String && e.value is Map)
                e.key as String: ModelPrice.fromJson(
                  Map<String, dynamic>.from(e.value as Map),
                ),
          };
        }
      } catch (_) {}
    }
  }

  Future<int> refresh() async {
    final response = await http
        .get(
          Uri.parse(kLiteLlmUrl),
          headers: {'User-Agent': 'GlassUsage/0.1 (+https://github.com/)'},
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'LiteLLM refresh returned HTTP ${response.statusCode}',
      );
    }
    final parsed = parseLiteLlm(response.body);
    if (parsed.isEmpty) {
      throw const FormatException('price table parsed to zero entries');
    }
    try {
      final f = File(cachePath);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(response.body);
    } catch (_) {}
    final merged = mergeOverFallback(parsed);
    _prices = merged;
    _sourceLabel = 'litellm';
    return merged.length;
  }

  void setOverrides(Map<String, ModelPrice> overrides) {
    _overrides.addAll(overrides);
    _persistOverrides();
  }

  bool removeOverride(String model) {
    final removed = _overrides.remove(model) != null;
    if (removed) {
      _persistOverrides();
    }
    return removed;
  }

  void _persistOverrides() {
    final f = File(overridesPath);
    f.parent.createSync(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    f.writeAsStringSync(
      encoder.convert({
        for (final e in _overrides.entries) e.key: e.value.toJson(),
      }),
    );
  }

  Map<String, ModelPrice> get overrides => Map.unmodifiable(_overrides);

  PricingInfo get info => PricingInfo(
    modelCount: _prices.length,
    source: _sourceLabel,
    overrides: overrides,
  );

  /// Resolve a raw model string to the canonical billing name used for grouping.
  String normalize(String raw) {
    return normalizeWith(
          prices: _prices,
          overrides: _overrides,
          aliases: _aliases,
          raw: raw,
        ) ??
        simplifyModelName(raw);
  }

  ModelPrice? priceFor(String modelNorm) {
    final direct = _overrides[modelNorm] ?? _prices[modelNorm];
    if (direct != null) return direct;
    final alias = _aliases[modelNorm];
    if (alias != null) {
      return _overrides[alias] ?? _prices[alias];
    }
    return null;
  }

  /// Cost in USD, or `null` when the model has no price entry (rendered greyed out).
  double? cost(
    String modelNorm,
    int input,
    int output,
    int cacheRead,
    int cacheWrite,
  ) {
    final p = priceFor(modelNorm);
    if (p == null) return null;
    if ((cacheWrite > 0 && p.cacheCreationInputTokenCost <= 0.0) ||
        (cacheRead > 0 && p.cacheReadInputTokenCost <= 0.0)) {
      return null;
    }
    return input * p.inputCostPerToken +
        output * p.outputCostPerToken +
        cacheWrite * p.cacheCreationInputTokenCost +
        cacheRead * p.cacheReadInputTokenCost;
  }

  static String? normalizeWith({
    required Map<String, ModelPrice> prices,
    required Map<String, ModelPrice> overrides,
    required Map<String, String> aliases,
    required String raw,
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    bool known(String k) => overrides.containsKey(k) || prices.containsKey(k);

    final lower = trimmed.toLowerCase();
    if (known(lower)) return lower;

    final alias1 = aliases[lower];
    if (alias1 != null && known(alias1)) {
      return alias1;
    }

    // Strip provider prefix ("anthropic/claude-...", "openai/gpt-...").
    final stripped = lower.split('/').last;
    if (known(stripped)) return stripped;

    final alias2 = aliases[stripped];
    if (alias2 != null && known(alias2)) {
      return alias2;
    }

    // Version separator variants: claude-3-5-sonnet <-> claude-3.5-sonnet.
    for (final cand in versionVariants(stripped)) {
      if (known(cand)) return cand;
    }

    // Trailing date stamps and vendor suffixes: claude-sonnet-4-20250514 -> claude-sonnet-4.
    final dateTrimmed = stripDateSuffix(stripped);
    if (dateTrimmed != stripped && known(dateTrimmed)) {
      return dateTrimmed;
    }

    // Longest known family that the raw name extends (length >= 6).
    String? best;
    for (final key in prices.keys) {
      if (key.length >= 6 &&
          stripped.startsWith(key) &&
          (best == null || key.length > best.length)) {
        best = key;
      }
    }
    return best;
  }

  static List<String> versionVariants(String s) {
    final out = <String>[];
    if (s.contains('.')) {
      out.add(s.replaceAll('.', '-'));
    }
    final chars = s.codeUnits;
    final buf = StringBuffer();
    var i = 0;
    while (i < chars.length) {
      if (i + 2 < chars.length &&
          _isDigit(chars[i]) &&
          chars[i + 1] == 0x2d /* '-' */ &&
          _isDigit(chars[i + 2])) {
        buf.writeCharCode(chars[i]);
        buf.write('.');
        i += 2;
      } else {
        buf.writeCharCode(chars[i]);
        i += 1;
      }
    }
    final swapped = buf.toString();
    if (swapped != s) {
      out.add(swapped);
    }
    return out;
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static String stripDateSuffix(String s) {
    final parts = s.split('-');
    if (parts.isNotEmpty) {
      final last = parts.last;
      if (last.length >= 6 && last.codeUnits.every(_isDigit)) {
        return parts.sublist(0, parts.length - 1).join('-');
      }
    }
    return s;
  }

  static String simplifyModelName(String raw) {
    final s = raw.trim().toLowerCase();
    if (s.isEmpty) return 'unknown';
    return s.split('/').last;
  }

  static Map<String, ModelPrice> mergeOverFallback(
    Map<String, ModelPrice> fetched,
  ) {
    final out = parseLiteLlm(kBundledFallbackPricingJson);
    out.addAll(fetched);
    return out;
  }

  static Map<String, ModelPrice> parseLiteLlm(String jsonStr) {
    dynamic root;
    try {
      root = jsonDecode(jsonStr);
    } catch (_) {
      return {};
    }
    if (root is! Map) return {};
    final out = <String, ModelPrice>{};
    root.forEach((rawName, val) {
      if (rawName is! String || val is! Map) return;
      if (rawName == 'sample_spec' || rawName.startsWith('_')) return;
      double getNum(String k) {
        final v = val[k];
        return (v is num) ? v.toDouble() : 0.0;
      }

      final price = ModelPrice(
        inputCostPerToken: getNum('input_cost_per_token'),
        outputCostPerToken: getNum('output_cost_per_token'),
        cacheCreationInputTokenCost: getNum('cache_creation_input_token_cost'),
        cacheReadInputTokenCost: getNum('cache_read_input_token_cost'),
      );
      if (price.inputCostPerToken == 0.0 && price.outputCostPerToken == 0.0) {
        return;
      }
      final key = rawName.toLowerCase();
      final bare = key.split('/').last;
      out.putIfAbsent(bare, () => price);
      out[key] = price;
    });
    return out;
  }

  static Map<String, String> builtinAliases() => {
    'gemini-pro-default': 'gemini-2.5-pro',
    'gemini-pro-c': 'gemini-2.5-pro',
    'gemini-pro-high': 'gemini-2.5-pro',
    'gemini-flash-default': 'gemini-2.5-flash',
    'gemini-3-flash-e': 'gemini-3-flash',
    'gemini-3-flash-a': 'gemini-3-flash',
    'gemini-3.1-pro-low': 'gemini-3-pro-preview',
    'gemini-3.1-pro': 'gemini-3-pro-preview',
    'claude-opus-4-6-thinking': 'claude-opus-4-1',
    'claude-sonnet-4-5-thinking': 'claude-sonnet-4-5',
    'claude-4-sonnet': 'claude-sonnet-4-20250514',
    'claude-4-opus': 'claude-opus-4-20250514',
    'gpt-5': 'gpt-5-2025-08-07',
    'glm-latest': 'glm-5.2',
    'auto': 'unknown',
    'kimi-code/k3': 'kimi-k3',
    'k3': 'kimi-k3',
    'k3-256k': 'kimi-k3',
    'deepseek-v4-flash': 'deepseek-chat',
  };
}
