import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'usage_models.dart';

enum WindowMaterial {
  acrylic,
  mica,
  css;

  String toJson() => name;

  static WindowMaterial fromJson(String? raw) {
    return WindowMaterial.values.firstWhere(
      (e) => e.name == raw?.toLowerCase(),
      orElse: () => WindowMaterial.acrylic,
    );
  }
}

enum ThemeModeSetting {
  system,
  dark,
  light;

  String toJson() => name;

  static ThemeModeSetting fromJson(String? raw) {
    return ThemeModeSetting.values.firstWhere(
      (e) => e.name == raw?.toLowerCase(),
      orElse: () => ThemeModeSetting.system,
    );
  }
}

enum LocaleMode {
  system,
  en,
  zh;

  String toJson() => name;

  static LocaleMode fromJson(String? raw) {
    return LocaleMode.values.firstWhere(
      (e) => e.name == raw?.toLowerCase(),
      orElse: () => LocaleMode.system,
    );
  }
}

class SourceConfig {
  final bool enabled;
  final String? customPath;

  const SourceConfig({
    this.enabled = true,
    this.customPath,
  });

  SourceConfig copyWith({
    bool? enabled,
    String? customPath,
    bool clearCustomPath = false,
  }) {
    return SourceConfig(
      enabled: enabled ?? this.enabled,
      customPath: clearCustomPath ? null : (customPath ?? this.customPath),
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'customPath': customPath,
      };

  factory SourceConfig.fromJson(Map<String, dynamic> json) {
    return SourceConfig(
      enabled: json['enabled'] as bool? ?? true,
      customPath: json['customPath'] as String?,
    );
  }
}

class AppSettings {
  final Map<String, SourceConfig> sources;
  final WindowMaterial material;
  final ThemeModeSetting theme;
  final LocaleMode locale;
  final double refraction;
  final bool animatedBackground;
  final int pollSecs;
  final int cursorPollSecs;
  final bool autostart;
  final bool startMinimized;
  final bool widgetCompact;
  final bool widgetAlwaysOnTop;
  final String widgetShortcut;
  /// 小窗折射强度，由界面限制在 0–60 并在拖动结束后持久化。
  final double widgetRefraction;

  /// 小窗色散强度，由界面限制在 0–4；与折射同时为零时跳过实时滤镜。
  final double widgetChromatic;
  final bool antigravityIdeEnabled;
  final int autoRefreshSecs;
  final bool firstRunDone;
  final bool budgetAlertsEnabled;
  final double dailyCostBudget;
  final int dailyTokenBudget;
  final List<String> budgetAlertSources;

  AppSettings({
    Map<String, SourceConfig>? sources,
    this.material = WindowMaterial.acrylic,
    this.theme = ThemeModeSetting.system,
    this.locale = LocaleMode.system,
    this.refraction = 0.62,
    this.animatedBackground = true,
    this.pollSecs = 60,
    this.cursorPollSecs = 300,
    this.autostart = false,
    this.startMinimized = false,
    this.widgetCompact = false,
    this.widgetAlwaysOnTop = true,
    this.widgetShortcut = 'CmdOrCtrl+Alt+G',
    this.widgetRefraction = 32.0,
    this.widgetChromatic = 1.2,
    this.antigravityIdeEnabled = true,
    this.autoRefreshSecs = 30,
    this.firstRunDone = false,
    this.budgetAlertsEnabled = false,
    this.dailyCostBudget = 10.0,
    this.dailyTokenBudget = 0,
    this.budgetAlertSources = const [],
  }) : sources = sources ??
            {
              for (final id in SourceIds.all) id: const SourceConfig(),
            };

  bool sourceEnabled(String source) => sources[source]?.enabled ?? true;

  String? customPath(String source) {
    final raw = sources[source]?.customPath?.trim();
    return (raw != null && raw.isNotEmpty) ? raw : null;
  }

  Map<String, dynamic> toJson() => {
        'sources': {
          for (final entry in sources.entries) entry.key: entry.value.toJson(),
        },
        'material': material.toJson(),
        'theme': theme.toJson(),
        'locale': locale.toJson(),
        'refraction': refraction,
        'animatedBackground': animatedBackground,
        'pollSecs': pollSecs,
        'cursorPollSecs': cursorPollSecs,
        'autostart': autostart,
        'startMinimized': startMinimized,
        'widgetCompact': widgetCompact,
        'widgetAlwaysOnTop': widgetAlwaysOnTop,
        'widgetShortcut': widgetShortcut,
        'widgetRefraction': widgetRefraction,
        'widgetChromatic': widgetChromatic,
        'antigravityIdeEnabled': antigravityIdeEnabled,
        'autoRefreshSecs': autoRefreshSecs,
        'firstRunDone': firstRunDone,
        'budgetAlertsEnabled': budgetAlertsEnabled,
        'dailyCostBudget': dailyCostBudget,
        'dailyTokenBudget': dailyTokenBudget,
        'budgetAlertSources': budgetAlertSources,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final defaultSources = {
      for (final id in SourceIds.all) id: const SourceConfig(),
    };
    final rawSources = json['sources'];
    if (rawSources is Map) {
      rawSources.forEach((k, v) {
        if (k is String && v is Map) {
          defaultSources[k] =
              SourceConfig.fromJson(Map<String, dynamic>.from(v));
        }
      });
    }
    return AppSettings(
      sources: defaultSources,
      material: WindowMaterial.fromJson(json['material'] as String?),
      theme: ThemeModeSetting.fromJson(json['theme'] as String?),
      locale: LocaleMode.fromJson(json['locale'] as String?),
      refraction: (json['refraction'] as num?)?.toDouble() ?? 0.62,
      animatedBackground: json['animatedBackground'] as bool? ?? true,
      pollSecs: (json['pollSecs'] as num?)?.toInt() ?? 60,
      cursorPollSecs: (json['cursorPollSecs'] as num?)?.toInt() ?? 300,
      autostart: json['autostart'] as bool? ?? false,
      startMinimized: json['startMinimized'] as bool? ?? false,
      widgetCompact: json['widgetCompact'] as bool? ?? false,
      widgetAlwaysOnTop: json['widgetAlwaysOnTop'] as bool? ?? true,
      widgetShortcut:
          json['widgetShortcut'] as String? ?? 'CmdOrCtrl+Alt+G',
      // 旧设置文件没有这两个键时沿用初始视觉参数，不要求迁移配置文件。
      widgetRefraction:
          (json['widgetRefraction'] as num?)?.toDouble() ?? 32.0,
      widgetChromatic:
          (json['widgetChromatic'] as num?)?.toDouble() ?? 1.2,
      antigravityIdeEnabled: json['antigravityIdeEnabled'] as bool? ?? true,
      autoRefreshSecs: (json['autoRefreshSecs'] as num?)?.toInt() ?? 30,
      firstRunDone: json['firstRunDone'] as bool? ?? false,
      budgetAlertsEnabled: json['budgetAlertsEnabled'] as bool? ?? false,
      dailyCostBudget: (json['dailyCostBudget'] as num?)?.toDouble() ?? 10.0,
      dailyTokenBudget: (json['dailyTokenBudget'] as num?)?.toInt() ?? 0,
      budgetAlertSources: (json['budgetAlertSources'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  AppSettings copyWithPatch(Map<String, dynamic> patch) {
    final merged = _deepMerge(toJson(), patch);
    return AppSettings.fromJson(merged);
  }

  static Map<String, dynamic> _deepMerge(
    Map<String, dynamic> target,
    Map<String, dynamic> patch,
  ) {
    final result = Map<String, dynamic>.from(target);
    patch.forEach((key, value) {
      final existing = result[key];
      if (existing is Map<String, dynamic> && value is Map) {
        result[key] = _deepMerge(existing, Map<String, dynamic>.from(value));
      } else {
        result[key] = value;
      }
    });
    return result;
  }
}

class SettingsStore {
  final String filePath;
  AppSettings _current;

  SettingsStore._(this.filePath, this._current);

  factory SettingsStore.load(String dataDir) {
    final path = p.join(dataDir, 'settings.json');
    final file = File(path);
    if (file.existsSync()) {
      try {
        final rawText = file.readAsStringSync();
        final decoded = jsonDecode(rawText);
        if (decoded is Map) {
          final map = Map<String, dynamic>.from(decoded);
          final hadFlag = map.containsKey('firstRunDone');
          var settings = AppSettings.fromJson(map);
          if (!hadFlag) {
            settings = settings.copyWithPatch({'firstRunDone': true});
          }
          return SettingsStore._(path, settings);
        }
      } catch (_) {}
    }
    return SettingsStore._(path, AppSettings());
  }

  AppSettings get() => _current;

  void set(AppSettings next) {
    _current = next;
    save();
  }

  AppSettings patch(Map<String, dynamic> patchMap) {
    _current = _current.copyWithPatch(patchMap);
    save();
    return _current;
  }

  void save() {
    final file = File(filePath);
    file.parent.createSync(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    file.writeAsStringSync(encoder.convert(_current.toJson()));
  }
}
