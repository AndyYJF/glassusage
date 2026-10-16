import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/format/app_format.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/window/win32_bridge.dart';
import '../../data/pricing/pricing_service.dart';
import '../../data/updates/signed_update.dart';
import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../providers/app_providers.dart';
import '../widgets/glass_widgets.dart';

const String kAppVersion = '0.7.8';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// Local slider value during drag (Anti-Jank Rule #3: only commit on onChangeEnd).
  double? _draggingRefraction;

  final TextEditingController _cursorTokenCtrl = TextEditingController();
  bool _savingCursor = false;
  String? _cursorMessage;

  final TextEditingController _overridePatternCtrl = TextEditingController();
  final TextEditingController _overrideInputCtrl = TextEditingController(
    text: '3.0',
  );
  final TextEditingController _overrideOutputCtrl = TextEditingController(
    text: '15.0',
  );
  final TextEditingController _overrideCacheReadCtrl = TextEditingController(
    text: '0.3',
  );
  final TextEditingController _overrideCacheCreateCtrl = TextEditingController(
    text: '3.75',
  );
  bool _refreshingPricing = false;
  String? _syncingRemoteName;

  @override
  void dispose() {
    _cursorTokenCtrl.dispose();
    _overridePatternCtrl.dispose();
    _overrideInputCtrl.dispose();
    _overrideOutputCtrl.dispose();
    _overrideCacheReadCtrl.dispose();
    _overrideCacheCreateCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final i18n = ref.watch(i18nProvider);
    final settings = ref.watch(appSettingsProvider);
    final cursorStatus = ref.watch(cursorStatusProvider);
    final remotes = ref.watch(remoteInstancesProvider);
    final allSources = ref.watch(sourceHealthProvider);
    final pricing = ref.watch(pricingInfoProvider);
    final dataDir = ref.watch(dataDirProvider);
    final controller = ref.read(appControllerProvider);

    final effectiveRefraction = _draggingRefraction ?? settings.refraction;
    final cursorConfigured =
        cursorStatus.hasAccessToken || cursorStatus.hasCookie;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Appearance & Liquid Glass
          GlassCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionHeader(
                  title: i18n.t('settings.appearance'),
                  icon: Icons.palette_outlined,
                ),
                const SizedBox(height: 16),
                _SettingRow(
                  label: i18n.t('settings.theme'),
                  control: GlassSegmented<ThemeModeSetting>(
                    value: settings.theme,
                    compact: true,
                    options: [
                      (ThemeModeSetting.dark, i18n.t('settings.themeDark')),
                      (ThemeModeSetting.light, i18n.t('settings.themeLight')),
                      (ThemeModeSetting.system, i18n.t('settings.themeSystem')),
                    ],
                    onChanged:
                        (v) => controller.patchSettings({'theme': v.toJson()}),
                  ),
                ),
                const Divider(height: 22),
                _SettingRow(
                  label: i18n.t('settings.language'),
                  control: GlassSegmented<LocaleMode>(
                    value: settings.locale,
                    compact: true,
                    options: [
                      (LocaleMode.system, i18n.t('settings.themeSystem')),
                      (LocaleMode.en, 'English'),
                      (LocaleMode.zh, '中文'),
                    ],
                    onChanged:
                        (v) => controller.patchSettings({'locale': v.toJson()}),
                  ),
                ),
                const Divider(height: 22),
                _SettingRow(
                  label: i18n.t('settings.material'),
                  control: GlassSegmented<WindowMaterial>(
                    value: settings.material,
                    compact: true,
                    options: [
                      (
                        WindowMaterial.acrylic,
                        i18n.t('settings.materialAcrylic'),
                      ),
                      (WindowMaterial.mica, i18n.t('settings.materialMica')),
                      (WindowMaterial.css, i18n.t('settings.materialCss')),
                    ],
                    onChanged:
                        (v) =>
                            controller.patchSettings({'material': v.toJson()}),
                  ),
                ),
                const Divider(height: 22),
                _SettingRow(
                  label:
                      '${i18n.t('settings.refraction')} (${(effectiveRefraction * 100).round()}%)',
                  control: SizedBox(
                    width: 240,
                    child: Slider(
                      value: effectiveRefraction.clamp(0.0, 1.0),
                      min: 0.0,
                      max: 1.0,
                      activeColor: g.accentBlue,
                      onChanged: (val) {
                        setState(() => _draggingRefraction = val);
                      },
                      onChangeEnd: (val) {
                        setState(() => _draggingRefraction = null);
                        controller.patchSettings({'refraction': val});
                      },
                    ),
                  ),
                ),
                const Divider(height: 22),
                _ToggleRow(
                  label: i18n.t('settings.autostart'),
                  value: settings.autostart,
                  onChanged: (v) => controller.patchSettings({'autostart': v}),
                ),
                const SizedBox(height: 10),
                _ToggleRow(
                  label: i18n.t('settings.widgetAlwaysOnTop'),
                  value: settings.widgetAlwaysOnTop,
                  onChanged:
                      (v) => controller.patchSettings({'widgetAlwaysOnTop': v}),
                ),
                const SizedBox(height: 10),
                _ToggleRow(
                  label: i18n.t('settings.widgetCompact'),
                  value: settings.widgetCompact,
                  onChanged:
                      (v) => controller.patchSettings({'widgetCompact': v}),
                ),
                const SizedBox(height: 10),
                _ToggleRow(
                  label: i18n.t('settings.animatedBg'),
                  value: settings.animatedBackground,
                  onChanged:
                      (v) =>
                          controller.patchSettings({'animatedBackground': v}),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 2. Cursor Cloud Integration
          GlassCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _SectionHeader(
                        title: i18n.t('settings.cursor'),
                        icon: Icons.key_rounded,
                      ),
                    ),
                    StatusPill(
                      status:
                          cursorConfigured
                              ? HealthStatus.live
                              : HealthStatus.missing,
                      i18n: i18n,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  i18n.t('settings.cursorDesc'),
                  style: TextStyle(fontSize: 12, color: g.textSecondary),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 36,
                        child: TextField(
                          controller: _cursorTokenCtrl,
                          obscureText: true,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: g.textPrimary,
                          ),
                          decoration: InputDecoration(
                            hintText:
                                cursorConfigured
                                    ? '••••••••••••••••••••••••'
                                    : i18n.t('settings.cursorPlaceholder'),
                            hintStyle: TextStyle(
                              fontSize: 12,
                              color: g.textTertiary,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            filled: true,
                            fillColor: g.glassSurface,
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(9),
                              borderSide: BorderSide(color: g.glassBorder),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(9),
                              borderSide: BorderSide(color: g.accentBlue),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GlassButton(
                      label: i18n.t('common.save'),
                      variant: GlassButtonVariant.primary,
                      isLoading: _savingCursor,
                      onPressed: () async {
                        setState(() {
                          _savingCursor = true;
                          _cursorMessage = null;
                        });
                        try {
                          await controller.saveCursorToken(
                            _cursorTokenCtrl.text.trim(),
                          );
                          _cursorTokenCtrl.clear();
                          if (mounted) {
                            setState(() {
                              _cursorMessage = 'Cursor token saved & synced';
                            });
                          }
                        } catch (e) {
                          if (mounted) {
                            setState(() => _cursorMessage = '$e');
                          }
                        } finally {
                          if (mounted) setState(() => _savingCursor = false);
                        }
                      },
                    ),
                  ],
                ),
                if (_cursorMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _cursorMessage!,
                    style: TextStyle(fontSize: 11.5, color: g.accentTeal),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 3. Remote SSH Instances
          GlassCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _SectionHeader(
                        title: i18n.t('settings.remote'),
                        icon: Icons.dns_outlined,
                      ),
                    ),
                    GlassButton(
                      label: i18n.t('settings.addRemote'),
                      icon: Icons.add_rounded,
                      variant: GlassButtonVariant.primary,
                      compact: true,
                      onPressed: () => _showRemoteDialog(context),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (remotes.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      i18n.t('common.noData'),
                      style: TextStyle(fontSize: 12, color: g.textTertiary),
                    ),
                  )
                else
                  Column(
                    children: [
                      for (final r in remotes)
                        Builder(
                          builder: (context) {
                            final health =
                                allSources
                                    .where(
                                      (h) =>
                                          h.source == r.agent &&
                                          h.instance == r.name,
                                    )
                                    .firstOrNull;
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              r.name,
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: g.textPrimary,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              '${r.agent} · ${r.username}@${r.host}:${r.port} (${r.authMode})',
                                              style: GlassTheme.tabularStyle(
                                                fontSize: 11.5,
                                                color: g.textSecondary,
                                              ),
                                            ),
                                            if (health != null) ...[
                                              const SizedBox(width: 8),
                                              StatusPill(
                                                status: health.status,
                                                i18n: i18n,
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                '${fmtInt(health.eventCount)} ev',
                                                style: GlassTheme.tabularStyle(
                                                  fontSize: 11.5,
                                                  color: g.textSecondary,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        if (health?.lastError != null &&
                                            health!.lastError!.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 3,
                                            ),
                                            child: Text(
                                              health.lastError!,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: g.danger,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  GlassButton(
                                    label: i18n.t('settings.testConn'),
                                    compact: true,
                                    onPressed:
                                        () => _runRemoteTest(
                                          context,
                                          input: RemoteInstanceInput(
                                            name: r.name,
                                            agent: r.agent,
                                            host: r.host,
                                            port: r.port,
                                            username: r.username,
                                            authMode: r.authMode,
                                            keyPath: r.keyPath,
                                            remoteHome: r.remoteHome,
                                            remotePath: r.remotePath,
                                            pollSecs: r.pollSecs,
                                            importArchives: r.importArchives,
                                            enabled: r.enabled,
                                            proxyUrl: r.proxyUrl,
                                          ),
                                        ),
                                  ),
                                  const SizedBox(width: 6),
                                  GlassButton(
                                    label: i18n.t('settings.syncNow'),
                                    compact: true,
                                    isLoading: _syncingRemoteName == r.name,
                                    onPressed: () async {
                                      setState(
                                        () => _syncingRemoteName = r.name,
                                      );
                                      try {
                                        await controller.syncRemoteInstance(
                                          r.name,
                                        );
                                      } finally {
                                        if (mounted) {
                                          setState(
                                            () => _syncingRemoteName = null,
                                          );
                                        }
                                      }
                                    },
                                  ),
                                  const SizedBox(width: 6),
                                  GlassButton(
                                    label: i18n.t('common.edit'),
                                    compact: true,
                                    onPressed:
                                        () => _showRemoteDialog(
                                          context,
                                          existing: r,
                                        ),
                                  ),
                                  const SizedBox(width: 6),
                                  GlassButton(
                                    label: i18n.t('common.delete'),
                                    variant: GlassButtonVariant.danger,
                                    compact: true,
                                    onPressed:
                                        () => controller.deleteRemoteInstance(
                                          r.name,
                                        ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 4. Pricing Catalog & Overrides
          GlassCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _SectionHeader(
                        title: i18n.t('settings.pricing'),
                        icon: Icons.attach_money_rounded,
                      ),
                    ),
                    GlassButton(
                      label: i18n.t('settings.refreshPricing'),
                      icon: Icons.sync_rounded,
                      compact: true,
                      isLoading: _refreshingPricing,
                      onPressed: () async {
                        setState(() => _refreshingPricing = true);
                        try {
                          await controller.refreshPricing();
                        } finally {
                          if (mounted) {
                            setState(() => _refreshingPricing = false);
                          }
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${fmtInt(pricing?.modelCount ?? 0)} models (${pricing?.source ?? 'bundled'})',
                  style: TextStyle(fontSize: 12, color: g.textSecondary),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _SmallInput(
                      controller: _overridePatternCtrl,
                      hint: 'Model pattern (e.g. claude-opus-4)',
                      width: 210,
                    ),
                    _SmallInput(
                      controller: _overrideInputCtrl,
                      hint: 'In \$/1M',
                      width: 85,
                    ),
                    _SmallInput(
                      controller: _overrideOutputCtrl,
                      hint: 'Out \$/1M',
                      width: 85,
                    ),
                    _SmallInput(
                      controller: _overrideCacheReadCtrl,
                      hint: 'CacheR',
                      width: 85,
                    ),
                    _SmallInput(
                      controller: _overrideCacheCreateCtrl,
                      hint: 'CacheW',
                      width: 85,
                    ),
                    GlassButton(
                      label: i18n.t('settings.addOverride'),
                      variant: GlassButtonVariant.primary,
                      compact: true,
                      onPressed: () async {
                        final pattern = _overridePatternCtrl.text.trim();
                        if (pattern.isEmpty) return;
                        final inPerM =
                            double.tryParse(_overrideInputCtrl.text) ?? 0;
                        final outPerM =
                            double.tryParse(_overrideOutputCtrl.text) ?? 0;
                        final crPerM =
                            double.tryParse(_overrideCacheReadCtrl.text) ?? 0;
                        final cwPerM =
                            double.tryParse(_overrideCacheCreateCtrl.text) ?? 0;
                        final override = ModelPrice(
                          inputCostPerToken: inPerM / 1e6,
                          outputCostPerToken: outPerM / 1e6,
                          cacheReadInputTokenCost: crPerM / 1e6,
                          cacheCreationInputTokenCost: cwPerM / 1e6,
                        );
                        await controller.savePricingOverride(pattern, override);
                        _overridePatternCtrl.clear();
                      },
                    ),
                  ],
                ),
                if (pricing != null && pricing.overrides.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (final entry in pricing.overrides.entries)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              entry.key,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: g.textPrimary,
                              ),
                            ),
                          ),
                          Text(
                            'In \$${(entry.value.inputCostPerToken * 1e6).toStringAsFixed(2)} · Out \$${(entry.value.outputCostPerToken * 1e6).toStringAsFixed(2)} / 1M',
                            style: GlassTheme.tabularStyle(
                              fontSize: 12,
                              color: g.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          GlassButton(
                            label: i18n.t('common.delete'),
                            variant: GlassButtonVariant.danger,
                            compact: true,
                            onPressed:
                                () =>
                                    controller.deletePricingOverride(entry.key),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 5. Data & Storage
          GlassCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionHeader(
                  title: i18n.t('settings.openDataDir'),
                  icon: Icons.folder_open_rounded,
                ),
                const SizedBox(height: 10),
                Text(
                  dataDir,
                  style: GlassTheme.tabularStyle(
                    fontSize: 12,
                    color: g.textSecondary,
                  ),
                ),
                const SizedBox(height: 14),
                GlassButton(
                  label: i18n.t('settings.openDataDir'),
                  icon: Icons.folder_open_rounded,
                  onPressed: () => Win32Bridge.instance.openDataDir(dataDir),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 6. In-App Updates
          _UpdateCheckerCard(i18n: i18n),
        ],
      ),
    );
  }

  Future<void> _runRemoteTest(
    BuildContext context, {
    required RemoteInstanceInput input,
  }) async {
    final g = GlassTheme.of(context);
    final controller = ref.read(appControllerProvider);
    final report = await controller.testRemoteInstance(input);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: SizedBox(
            width: 440,
            child: GlassCard(
              useBlur: true,
              elevated: true,
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SSH Diagnostics · ${input.name}',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: g.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final step in report.steps)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          Icon(
                            step.ok
                                ? Icons.check_circle_rounded
                                : Icons.error_rounded,
                            size: 16,
                            color: step.ok ? g.success : g.danger,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  step.label.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: g.textPrimary,
                                  ),
                                ),
                                Text(
                                  step.detail,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: g.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: GlassButton(
                      label: 'Close',
                      variant: GlassButtonVariant.primary,
                      compact: true,
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showRemoteDialog(
    BuildContext context, {
    RemoteInstance? existing,
  }) async {
    final g = GlassTheme.of(context);
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final hostCtrl = TextEditingController(text: existing?.host ?? '');
    final portCtrl = TextEditingController(text: '${existing?.port ?? 22}');
    final userCtrl = TextEditingController(text: existing?.username ?? 'root');
    final keyPathCtrl = TextEditingController(text: existing?.keyPath ?? '');
    final passCtrl = TextEditingController();
    final proxyCtrl = TextEditingController(text: existing?.proxyUrl ?? '');
    var agent = existing?.agent ?? 'hermes';
    var authMode = existing?.authMode ?? 'key';

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Dialog(
              backgroundColor: Colors.transparent,
              child: SizedBox(
                width: 460,
                child: GlassCard(
                  useBlur: true,
                  elevated: true,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        existing == null ? 'Add SSH Host' : 'Edit SSH Host',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: g.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: _SmallInput(
                              controller: nameCtrl,
                              hint: 'Instance name (e.g. devbox-us)',
                              width: double.infinity,
                            ),
                          ),
                          const SizedBox(width: 8),
                          GlassSegmented<String>(
                            value: agent,
                            compact: true,
                            options: const [
                              ('hermes', 'Hermes'),
                              ('openclaw', 'OpenClaw'),
                            ],
                            onChanged: (a) => setModalState(() => agent = a),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: _SmallInput(
                              controller: hostCtrl,
                              hint: 'Host / IP',
                              width: double.infinity,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 1,
                            child: _SmallInput(
                              controller: portCtrl,
                              hint: 'Port',
                              width: double.infinity,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _SmallInput(
                        controller: userCtrl,
                        hint: 'SSH User',
                        width: double.infinity,
                      ),
                      const SizedBox(height: 10),
                      GlassSegmented<String>(
                        value: authMode,
                        compact: true,
                        options: const [
                          ('key', 'SSH Key'),
                          ('agent', 'SSH Agent'),
                          ('password', 'Password (DPAPI)'),
                        ],
                        onChanged: (m) => setModalState(() => authMode = m),
                      ),
                      const SizedBox(height: 10),
                      if (authMode == 'key')
                        _SmallInput(
                          controller: keyPathCtrl,
                          hint: 'Key path (optional, e.g. ~/.ssh/id_ed25519)',
                          width: double.infinity,
                        ),
                      if (authMode == 'password')
                        _SmallInput(
                          controller: passCtrl,
                          hint: 'SSH Password (encrypted with Windows DPAPI)',
                          width: double.infinity,
                          obscure: true,
                        ),
                      const SizedBox(height: 8),
                      _SmallInput(
                        controller: proxyCtrl,
                        hint:
                            'HTTP Proxy (optional, e.g. http://127.0.0.1:7890)',
                        width: double.infinity,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          GlassButton(
                            label: 'Cancel',
                            compact: true,
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                          const SizedBox(width: 8),
                          GlassButton(
                            label: 'Save',
                            variant: GlassButtonVariant.primary,
                            compact: true,
                            onPressed: () async {
                              final input = RemoteInstanceInput(
                                name: nameCtrl.text.trim(),
                                agent: agent,
                                host: hostCtrl.text.trim(),
                                port: int.tryParse(portCtrl.text.trim()) ?? 22,
                                username: userCtrl.text.trim(),
                                authMode: authMode,
                                keyPath:
                                    keyPathCtrl.text.trim().isEmpty
                                        ? null
                                        : keyPathCtrl.text.trim(),
                                password:
                                    passCtrl.text.isEmpty
                                        ? null
                                        : passCtrl.text,
                                proxyUrl:
                                    proxyCtrl.text.trim().isEmpty
                                        ? null
                                        : proxyCtrl.text.trim(),
                                enabled: true,
                              );
                              await ref
                                  .read(appControllerProvider)
                                  .upsertRemoteInstance(input);
                              if (ctx.mounted) Navigator.of(ctx).pop();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    return Row(
      children: [
        Icon(icon, size: 17, color: g.accentBlue),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
            color: g.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, required this.control});

  final String label;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: g.textPrimary,
            ),
          ),
        ),
        control,
      ],
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: g.textPrimary)),
        Switch.adaptive(
          value: value,
          activeTrackColor: g.accentBlue,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _SmallInput extends StatelessWidget {
  const _SmallInput({
    required this.controller,
    required this.hint,
    required this.width,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String hint;
  final double width;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    return SizedBox(
      width: width,
      height: 34,
      child: TextField(
        controller: controller,
        obscureText: obscure,
        style: TextStyle(fontSize: 12, color: g.textPrimary),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(fontSize: 11.5, color: g.textTertiary),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          filled: true,
          fillColor: g.glassSurface,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: g.glassBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: g.accentBlue),
          ),
        ),
      ),
    );
  }
}

class _UpdateCheckerCard extends StatefulWidget {
  const _UpdateCheckerCard({required this.i18n});

  final AppI18n i18n;

  @override
  State<_UpdateCheckerCard> createState() => _UpdateCheckerCardState();
}

class _UpdateCheckerCardState extends State<_UpdateCheckerCard> {
  String _state =
      'idle'; // idle | checking | upToDate | available | downloading | error
  String? _remoteVersion;
  String? _releaseNotes;
  String? _downloadUrl;
  String? _signature;
  String? _errorMsg;
  double _progress = 0.0;

  static int _compareSemver(String a, String b) {
    final pa = a.replaceFirst(RegExp(r'^v'), '').split('+').first.split('.');
    final pb = b.replaceFirst(RegExp(r'^v'), '').split('+').first.split('.');
    for (var i = 0; i < 3; i++) {
      final na = i < pa.length ? (int.tryParse(pa[i]) ?? 0) : 0;
      final nb = i < pb.length ? (int.tryParse(pb[i]) ?? 0) : 0;
      if (na != nb) return na.compareTo(nb);
    }
    return 0;
  }

  Future<void> _checkForUpdates() async {
    setState(() {
      _state = 'checking';
      _errorMsg = null;
    });
    try {
      final resp = await http
          .get(
            Uri.parse(
              'https://github.com/AndyYJF/glassusage/releases/latest/download/latest.json',
            ),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 15));

      String? version;
      String? notes;
      String? installerUrl;
      String? signature;

      if (resp.statusCode == 200) {
        final json =
            jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
        version = (json['version'] as String?)?.trim();
        notes = json['notes'] as String?;
        final platforms = json['platforms'] as Map<String, dynamic>?;
        final winEntry =
            (platforms?['windows-x86_64-nsis'] ?? platforms?['windows-x86_64'])
                as Map<String, dynamic>?;
        installerUrl = winEntry?['url'] as String?;
        signature = winEntry?['signature'] as String?;
      } else {
        // Fallback to GitHub Releases REST API
        final ghResp = await http
            .get(
              Uri.parse(
                'https://api.github.com/repos/AndyYJF/glassusage/releases/latest',
              ),
              headers: const {'Accept': 'application/vnd.github+json'},
            )
            .timeout(const Duration(seconds: 15));
        if (ghResp.statusCode != 200) {
          throw Exception('HTTP ${ghResp.statusCode}');
        }
        final ghJson =
            jsonDecode(utf8.decode(ghResp.bodyBytes)) as Map<String, dynamic>;
        version = (ghJson['tag_name'] as String?)?.replaceFirst(
          RegExp(r'^v'),
          '',
        );
        notes = ghJson['body'] as String?;
        final assets = (ghJson['assets'] as List<dynamic>? ?? const []);
        for (final asset in assets) {
          if (asset is Map<String, dynamic>) {
            final name = asset['name'] as String? ?? '';
            if (name.endsWith('-setup.exe')) {
              installerUrl = asset['browser_download_url'] as String?;
              break;
            }
          }
        }
        if (installerUrl != null) {
          final sigResponse = await http
              .get(updateDownloadUri('$installerUrl.sig'))
              .timeout(const Duration(seconds: 15));
          if (sigResponse.statusCode != 200) {
            throw Exception('Signed update is unavailable');
          }
          signature = utf8.decode(sigResponse.bodyBytes).trim();
        }
      }

      if (version == null || version.isEmpty) {
        throw Exception('Invalid release metadata');
      }

      if (!mounted) return;
      if (_compareSemver(version, kAppVersion) > 0 && installerUrl != null) {
        updateDownloadUri(installerUrl);
        if (signature == null || signature.isEmpty) {
          throw Exception('Missing update signature');
        }
        setState(() {
          _state = 'available';
          _remoteVersion = version;
          _releaseNotes = notes;
          _downloadUrl = installerUrl;
          _signature = signature;
        });
      } else {
        setState(() {
          _state = 'upToDate';
          _remoteVersion = kAppVersion;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = 'error';
        _errorMsg = e.toString();
      });
    }
  }

  Future<void> _downloadAndInstall() async {
    final url = _downloadUrl;
    final signature = _signature;
    if (url == null || signature == null) return;

    setState(() {
      _state = 'downloading';
      _progress = 0.0;
      _errorMsg = null;
    });

    try {
      final outFile = await downloadSignedUpdate(
        url,
        signature,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress.clamp(0.0, 1.0));
        },
      );
      if (!mounted) return;

      // Launch NSIS installer in passive + auto-relaunch mode and exit current instance
      await Process.start(outFile.path, const [
        '/P',
        '/R',
      ], mode: ProcessStartMode.detached);
      exit(0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = 'error';
        _errorMsg = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final i18n = widget.i18n;

    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            title: i18n.t('settings.updates'),
            icon: Icons.sync_rounded,
          ),
          const SizedBox(height: 10),
          Text(
            i18n.t('settings.updatesHint'),
            style: TextStyle(fontSize: 12, color: g.textSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            i18n.t('settings.currentVersion', {'version': kAppVersion}),
            style: GlassTheme.tabularStyle(fontSize: 12, color: g.textTertiary),
          ),
          const SizedBox(height: 12),
          if (_state == 'upToDate')
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                i18n.t('settings.upToDate', {'version': kAppVersion}),
                style: TextStyle(fontSize: 12.5, color: g.success),
              ),
            ),
          if (_state == 'error' && _errorMsg != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _errorMsg!,
                style: TextStyle(fontSize: 12.5, color: g.danger),
              ),
            ),
          if (_state == 'available')
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: g.glassSurface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: g.glassBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    i18n.t('settings.updateAvailable', {
                      'version': _remoteVersion ?? '',
                    }),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: g.textPrimary,
                    ),
                  ),
                  if (_releaseNotes != null && _releaseNotes!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      _releaseNotes!,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: g.textSecondary),
                    ),
                  ],
                  const SizedBox(height: 10),
                  GlassButton(
                    label: i18n.t('settings.installUpdate'),
                    icon: Icons.system_update_alt_rounded,
                    variant: GlassButtonVariant.primary,
                    compact: true,
                    onPressed: _downloadAndInstall,
                  ),
                ],
              ),
            ),
          if (_state == 'downloading')
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${i18n.t('settings.downloadingUpdate')} ${(100 * _progress).round()}%',
                    style: TextStyle(fontSize: 12, color: g.textSecondary),
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _progress > 0 ? _progress : null,
                      minHeight: 6,
                      backgroundColor: g.glassSurface,
                      color: g.accentBlue,
                    ),
                  ),
                ],
              ),
            ),
          GlassButton(
            label:
                _state == 'checking'
                    ? i18n.t('settings.checkingUpdate')
                    : i18n.t('settings.checkUpdate'),
            icon: Icons.refresh_rounded,
            onPressed:
                (_state == 'checking' || _state == 'downloading')
                    ? null
                    : _checkForUpdates,
          ),
        ],
      ),
    );
  }
}
