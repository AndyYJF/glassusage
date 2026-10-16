import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/app_format.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/theme/glass_theme.dart';
import '../../domain/models/usage_models.dart';
import '../providers/app_providers.dart';

/// Liquid Glass container that strictly obeys the BackdropFilter GPU budget
/// (Anti-Jank Rule #2: `useBlur` defaults to `false` for cards/tiles/rows;
/// only top-level chrome like Sidebar, TopBar, and Modals pass `useBlur: true`).
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = 18,
    this.elevated = false,
    this.useBlur = false,
    this.blurSigma = 18,
    this.tintColor,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final bool elevated;
  final bool useBlur;
  final double blurSigma;
  final Color? tintColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final radius = BorderRadius.circular(borderRadius);
    final baseColor =
        tintColor ?? (elevated ? g.glassElevated : g.glassSurface);

    Widget box = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              g.specularHighlight.withValues(alpha: g.isDark ? 0.05 : 0.35),
              baseColor,
            ),
            baseColor,
          ],
        ),
        border: Border.all(color: g.glassBorder, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: g.isDark ? 0.26 : 0.06),
            blurRadius: elevated ? 22 : 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );

    if (useBlur && blurSigma > 0) {
      box = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: box,
        ),
      );
    }

    if (onTap != null) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: box,
        ),
      );
    }
    return box;
  }
}

enum GlassButtonVariant { primary, secondary, ghost, danger }

class GlassButton extends StatefulWidget {
  const GlassButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.variant = GlassButtonVariant.secondary,
    this.compact = false,
    this.isLoading = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final GlassButtonVariant variant;
  final bool compact;
  final bool isLoading;

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final disabled = widget.onPressed == null || widget.isLoading;

    final (Color bg, Color fg, Color border) = switch (widget.variant) {
      GlassButtonVariant.primary => (
          _hovered
              ? g.accentBlue.withValues(alpha: 0.92)
              : g.accentBlue.withValues(alpha: 0.82),
          Colors.white,
          g.accentBlue.withValues(alpha: 0.55),
        ),
      GlassButtonVariant.danger => (
          _hovered
              ? g.danger.withValues(alpha: 0.24)
              : g.danger.withValues(alpha: 0.15),
          g.danger,
          g.danger.withValues(alpha: 0.38),
        ),
      GlassButtonVariant.ghost => (
          _hovered ? g.glassHover : Colors.transparent,
          g.textSecondary,
          Colors.transparent,
        ),
      GlassButtonVariant.secondary => (
          _hovered ? g.glassHover : g.glassSurface,
          g.textPrimary,
          g.glassBorderStrong,
        ),
    };

    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: disabled ? null : widget.onPressed,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: disabled ? 0.5 : 1.0,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 10 : 14,
              vertical: widget.compact ? 6 : 8,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(widget.compact ? 9 : 11),
              border: Border.all(color: border, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.isLoading) ...[
                  SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      valueColor: AlwaysStoppedAnimation<Color>(fg),
                    ),
                  ),
                  if (widget.label.isNotEmpty) const SizedBox(width: 6),
                ] else if (widget.icon != null) ...[
                  Icon(widget.icon, size: widget.compact ? 14 : 15, color: fg),
                  if (widget.label.isNotEmpty) const SizedBox(width: 6),
                ],
                if (widget.label.isNotEmpty)
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: widget.compact ? 12 : 12.5,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class GlassSegmented<T> extends StatelessWidget {
  const GlassSegmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.compact = false,
  });

  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: g.glassSurface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: g.glassBorder, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (optVal, label) in options)
            _SegmentItem(
              label: label,
              selected: optVal == value,
              compact: compact,
              onTap: () => onChanged(optVal),
            ),
        ],
      ),
    );
  }
}

class _SegmentItem extends StatefulWidget {
  const _SegmentItem({
    required this.label,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_SegmentItem> createState() => _SegmentItemState();
}

class _SegmentItemState extends State<_SegmentItem> {
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
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 9 : 12,
            vertical: widget.compact ? 4.5 : 6,
          ),
          decoration: BoxDecoration(
            color: widget.selected
                ? g.accentBlue.withValues(alpha: g.isDark ? 0.25 : 0.16)
                : (_hovered ? g.glassHover : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.selected
                  ? g.accentBlue.withValues(alpha: 0.45)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: widget.compact ? 11.5 : 12,
              fontWeight:
                  widget.selected ? FontWeight.w600 : FontWeight.w500,
              color: widget.selected ? g.textPrimary : g.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class RangePicker extends ConsumerWidget {
  const RangePicker({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(selectedRangeProvider);
    final i18n = ref.watch(i18nProvider);
    final controller = ref.read(appControllerProvider);

    return GlassSegmented<RangePreset>(
      value: range,
      compact: compact,
      options: [
        (RangePreset.today, i18n.t('range.today')),
        (RangePreset.d7, i18n.t('range.7d')),
        (RangePreset.d14, i18n.t('range.14d')),
        (RangePreset.d30, i18n.t('range.30d')),
        (RangePreset.d90, i18n.t('range.90d')),
        (RangePreset.all, i18n.t('range.all')),
      ],
      onChanged: controller.setRange,
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.subtitle,
    this.deltaPct,
    this.accentColor,
    this.trailing,
  });

  final String label;
  final String value;
  final String? subtitle;
  final double? deltaPct;
  final Color? accentColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final deltaStr = fmtDelta(deltaPct);
    final isPos = (deltaPct ?? 0) >= 0;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (accentColor != null) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: accentColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
              ],
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                    color: g.textTertiary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (deltaStr.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: (isPos ? g.success : g.warning)
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    deltaStr,
                    style: GlassTheme.tabularStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isPos ? g.success : g.warning,
                    ),
                  ),
                ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: GlassTheme.tabularStyle(
              fontSize: 25,
              fontWeight: FontWeight.w700,
              color: g.textPrimary,
              letterSpacing: -0.5,
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 12,
                color: g.textSecondary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.status,
    required this.i18n,
  });

  final HealthStatus status;
  final AppI18n i18n;

  @override
  Widget build(BuildContext context) {
    final color = GlassTheme.statusColor(status);
    final label = i18n.statusLabel(status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class AgentBadge extends StatelessWidget {
  const AgentBadge({
    super.key,
    required this.sourceId,
    this.instanceLabel,
    this.fontSize = 12.5,
  });

  final String sourceId;
  final String? instanceLabel;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final meta = kSourceMeta[sourceId];
    final color = GlassTheme.sourceColor(sourceId);
    final name = meta?.label ?? sourceId;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.45),
                blurRadius: 6,
              ),
            ],
          ),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            instanceLabel != null &&
                    instanceLabel!.isNotEmpty &&
                    instanceLabel != 'Local' &&
                    instanceLabel != 'local'
                ? '$name · $instanceLabel'
                : name,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: g.textPrimary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
