import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/format/app_format.dart';
import 'core/i18n/app_i18n.dart';
import 'core/theme/glass_theme.dart';
import 'core/window/desktop_window_manager.dart';
import 'domain/models/settings_model.dart';
import 'presentation/pages/agent_detail_page.dart';
import 'presentation/pages/compare_page.dart';
import 'presentation/pages/dashboard_page.dart';
import 'presentation/pages/mini_card_view.dart';
import 'presentation/pages/onboarding_modal.dart';
import 'presentation/pages/settings_page.dart';
import 'presentation/pages/usage_page.dart';
import 'presentation/providers/app_providers.dart';
import 'presentation/widgets/glass_widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DesktopWindowManager.instance.initialize();
  runApp(
    const ProviderScope(
      child: GlassUsageApp(),
    ),
  );
}

class GlassUsageApp extends ConsumerStatefulWidget {
  const GlassUsageApp({
    super.key,
    this.autoInitialize = true,
  });

  final bool autoInitialize;

  @override
  ConsumerState<GlassUsageApp> createState() => _GlassUsageAppState();
}

class _GlassUsageAppState extends ConsumerState<GlassUsageApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.autoInitialize) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(appControllerProvider).initialize();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    ref.read(isWindowVisibleProvider.notifier).state = visible;
  }

  @override
  Widget build(BuildContext context) {
    final themeSetting = ref.watch(appSettingsProvider.select((s) => s.theme));
    final refraction =
        ref.watch(appSettingsProvider.select((s) => s.refraction));
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final isDark = switch (themeSetting) {
      ThemeModeSetting.dark => true,
      ThemeModeSetting.light => false,
      ThemeModeSetting.system => platformBrightness == Brightness.dark,
    };

    return MaterialApp(
      title: 'GlassUsage',
      debugShowCheckedModeBanner: false,
      theme: GlassTheme.buildThemeData(
        isDark: isDark,
        refraction: refraction,
      ),
      home: const _GlassShell(),
    );
  }
}

class _GlassShell extends ConsumerWidget {
  const _GlassShell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = GlassTheme.of(context);
    final isMiniCard = ref.watch(isMiniCardModeProvider);
    final showOnboarding = ref.watch(showOnboardingProvider);
    final material = ref.watch(appSettingsProvider.select((s) => s.material));

    if (isMiniCard) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: MiniCardView(),
      );
    }

    final canvasAlpha = material == WindowMaterial.css
        ? 0.94
        : (g.isDark ? 0.72 : 0.78);

    return Scaffold(
      backgroundColor: g.bgCanvas.withValues(alpha: canvasAlpha),
      body: Stack(
        children: [
          // Subtle ambient radial glows behind the Liquid Glass chrome
          Positioned(
            top: -120,
            left: -80,
            child: IgnorePointer(
              child: Container(
                width: 380,
                height: 380,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      g.accentBlue.withValues(alpha: g.isDark ? 0.14 : 0.10),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -140,
            right: -60,
            child: IgnorePointer(
              child: Container(
                width: 420,
                height: 420,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      g.accentPurple.withValues(alpha: g.isDark ? 0.12 : 0.08),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: const [
              _GlassSidebar(),
              Expanded(
                child: Column(
                  children: [
                    _GlassTopBar(),
                    Expanded(child: _ActiveRouteBody()),
                  ],
                ),
              ),
            ],
          ),
          if (showOnboarding) const OnboardingModal(),
        ],
      ),
    );
  }
}

class _GlassSidebar extends ConsumerWidget {
  const _GlassSidebar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = GlassTheme.of(context);
    final i18n = ref.watch(i18nProvider);
    final activeRoute = ref.watch(activeRouteProvider);
    final agentRollups = ref.watch(agentRollupProvider);
    final refraction =
        ref.watch(appSettingsProvider.select((s) => s.refraction));

    return SizedBox(
      width: 232,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 0, 12),
        child: GlassCard(
          useBlur: true,
          blurSigma: 12 + refraction * 12,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Brand header (draggable)
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => DesktopWindowManager.instance.startDragging(),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 14),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(9),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [g.accentBlue, g.accentPurple],
                          ),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.blur_on_rounded,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'GlassUsage',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: g.textPrimary,
                              ),
                            ),
                            Text(
                              'Liquid Monitor',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: g.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Section: Overview
              _SidebarGroupLabel(i18n.t('nav.overview')),
              _SidebarNavItem(
                label: i18n.t('nav.dashboard'),
                icon: Icons.space_dashboard_rounded,
                selected: activeRoute == 'dashboard',
                onTap: () =>
                    ref.read(activeRouteProvider.notifier).state = 'dashboard',
              ),
              _SidebarNavItem(
                label: i18n.t('nav.usage'),
                icon: Icons.table_chart_rounded,
                selected: activeRoute == 'usage',
                onTap: () =>
                    ref.read(activeRouteProvider.notifier).state = 'usage',
              ),
              _SidebarNavItem(
                label: i18n.t('nav.compare'),
                icon: Icons.compare_arrows_rounded,
                selected: activeRoute == 'compare',
                onTap: () =>
                    ref.read(activeRouteProvider.notifier).state = 'compare',
              ),
              const SizedBox(height: 10),

              // Section: Agents (10 AI Coding Agents)
              _SidebarGroupLabel(i18n.t('nav.agents')),
              Expanded(
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: agentRollups.length,
                  itemBuilder: (context, index) {
                    final agent = agentRollups[index];
                    final meta = kSourceMeta[agent.source];
                    final routeKey = 'agent:${agent.source}';
                    final statusColor = GlassTheme.statusColor(agent.status);

                    return _SidebarNavItem(
                      label: meta?.label ?? agent.source,
                      dotColor: GlassTheme.sourceColor(agent.source),
                      selected: activeRoute == routeKey,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (agent.eventCount > 0)
                            Text(
                              fmtTokens(agent.eventCount),
                              style: GlassTheme.tabularStyle(
                                fontSize: 10.5,
                                color: g.textTertiary,
                              ),
                            ),
                          const SizedBox(width: 5),
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: statusColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                      onTap: () =>
                          ref.read(activeRouteProvider.notifier).state =
                              routeKey,
                    );
                  },
                ),
              ),

              const Divider(height: 16),
              _SidebarNavItem(
                label: i18n.t('nav.settings'),
                icon: Icons.tune_rounded,
                selected: activeRoute == 'settings',
                onTap: () =>
                    ref.read(activeRouteProvider.notifier).state = 'settings',
              ),
              const SizedBox(height: 4),
              _SidebarNavItem(
                label: i18n.t('nav.miniCard'),
                icon: Icons.picture_in_picture_alt_rounded,
                selected: false,
                onTap: () =>
                    ref.read(appControllerProvider).setWidgetMode(true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarGroupLabel extends StatelessWidget {
  const _SidebarGroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: g.textTertiary,
        ),
      ),
    );
  }
}

class _SidebarNavItem extends StatefulWidget {
  const _SidebarNavItem({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.dotColor,
    this.trailing,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final Color? dotColor;
  final Widget? trailing;

  @override
  State<_SidebarNavItem> createState() => _SidebarNavItemState();
}

class _SidebarNavItemState extends State<_SidebarNavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7.5),
          decoration: BoxDecoration(
            color: widget.selected
                ? g.accentBlue.withValues(alpha: g.isDark ? 0.22 : 0.14)
                : (_hovered ? g.glassHover : Colors.transparent),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected
                  ? g.accentBlue.withValues(alpha: 0.4)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              if (widget.icon != null) ...[
                Icon(
                  widget.icon,
                  size: 16,
                  color: widget.selected ? g.accentBlue : g.textSecondary,
                ),
                const SizedBox(width: 9),
              ] else if (widget.dotColor != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: widget.dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 9),
              ],
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight:
                        widget.selected ? FontWeight.w600 : FontWeight.w500,
                    color: widget.selected ? g.textPrimary : g.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassTopBar extends ConsumerWidget {
  const _GlassTopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = GlassTheme.of(context);
    final i18n = ref.watch(i18nProvider);
    final activeRoute = ref.watch(activeRouteProvider);
    final rescanning = ref.watch(isRescanningProvider);
    final controller = ref.read(appControllerProvider);

    final pageTitle = switch (activeRoute) {
      'dashboard' => i18n.t('nav.dashboard'),
      'usage' => i18n.t('nav.usage'),
      'compare' => i18n.t('nav.compare'),
      'settings' => i18n.t('nav.settings'),
      _ when activeRoute.startsWith('agent:') =>
        kSourceMeta[activeRoute.substring(6)]?.label ??
            activeRoute.substring(6),
      _ => 'GlassUsage',
    };

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => DesktopWindowManager.instance.startDragging(),
      onDoubleTap: DesktopWindowManager.instance.toggleMaximize,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 16, 8),
        child: Row(
          children: [
            Text(
              pageTitle,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: g.textPrimary,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(width: 14),
            const _HeaderLiveBadge(),
            const Spacer(),
            if (activeRoute != 'settings') ...[
              const RangePicker(compact: true),
              const SizedBox(width: 10),
            ],
            GlassButton(
              label: rescanning
                  ? i18n.t('dash.rescanning')
                  : i18n.t('common.rescan'),
              icon: Icons.refresh_rounded,
              compact: true,
              isLoading: rescanning,
              onPressed: controller.rescanNow,
            ),
            const SizedBox(width: 10),
            _WindowIconButton(
              icon: Icons.remove_rounded,
              tooltip: 'Minimize',
              onTap: DesktopWindowManager.instance.minimize,
            ),
            _WindowIconButton(
              icon: Icons.crop_square_rounded,
              tooltip: 'Maximize',
              onTap: DesktopWindowManager.instance.toggleMaximize,
            ),
            _WindowIconButton(
              icon: Icons.close_rounded,
              tooltip: 'Hide to Tray',
              isClose: true,
              onTap: DesktopWindowManager.instance.hideToTray,
            ),
          ],
        ),
      ),
    );
  }
}

/// Isolated 1 Hz header live badge (Anti-Jank Rule #5).
class _HeaderLiveBadge extends ConsumerWidget {
  const _HeaderLiveBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = GlassTheme.of(context);
    final live = ref.watch(liveRatesProvider);
    final isActive = live.perSource.any((s) => s.active);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: g.glassSurface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: g.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: isActive ? g.success : g.accentBlue,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${fmtTokens(live.tpm.round())}/m',
            style: GlassTheme.tabularStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: g.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowIconButton extends StatefulWidget {
  const _WindowIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.isClose = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool isClose;

  @override
  State<_WindowIconButton> createState() => _WindowIconButtonState();
}

class _WindowIconButtonState extends State<_WindowIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 30,
          height: 28,
          margin: const EdgeInsets.only(left: 2),
          decoration: BoxDecoration(
            color: _hovered
                ? (widget.isClose
                    ? g.danger.withValues(alpha: 0.85)
                    : g.glassHover)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          alignment: Alignment.center,
          child: Icon(
            widget.icon,
            size: 15,
            color: _hovered && widget.isClose ? Colors.white : g.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _ActiveRouteBody extends ConsumerWidget {
  const _ActiveRouteBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeRoute = ref.watch(activeRouteProvider);

    if (activeRoute.startsWith('agent:')) {
      final sourceId = activeRoute.substring(6);
      return AgentDetailPage(sourceId: sourceId);
    }

    return switch (activeRoute) {
      'usage' => const UsagePage(),
      'compare' => const ComparePage(),
      'settings' => const SettingsPage(),
      _ => const DashboardPage(),
    };
  }
}
