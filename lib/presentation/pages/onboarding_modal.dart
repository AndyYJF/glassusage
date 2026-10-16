import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/app_format.dart';
import '../../core/theme/glass_theme.dart';
import '../providers/app_providers.dart';
import '../widgets/glass_widgets.dart';

class OnboardingModal extends ConsumerWidget {
  const OnboardingModal({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = GlassTheme.of(context);
    final i18n = ref.watch(i18nProvider);
    final agentRollups = ref.watch(agentRollupProvider);
    final controller = ref.read(appControllerProvider);

    return Container(
      color: Colors.black.withValues(alpha: 0.55),
      alignment: Alignment.center,
      child: SizedBox(
        width: 560,
        child: GlassCard(
          useBlur: true,
          elevated: true,
          padding: const EdgeInsets.all(26),
          borderRadius: 22,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                i18n.t('dash.title'),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: g.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                i18n.t('dash.subtitle'),
                style: TextStyle(fontSize: 13, color: g.textSecondary),
              ),
              const SizedBox(height: 18),
              Text(
                i18n.t('dash.agentStatus').toUpperCase(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: g.textTertiary,
                ),
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 250),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final agent in agentRollups)
                        SizedBox(
                          width: 245,
                          child: GlassCard(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            borderRadius: 12,
                            child: Row(
                              children: [
                                Expanded(
                                  child: AgentBadge(
                                    sourceId: agent.source,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  fmtInt(agent.eventCount),
                                  style: GlassTheme.tabularStyle(
                                    fontSize: 11.5,
                                    color: g.textSecondary,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                StatusPill(
                                  status: agent.status,
                                  i18n: i18n,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Align(
                alignment: Alignment.centerRight,
                child: GlassButton(
                  label: i18n.t('common.close'),
                  variant: GlassButtonVariant.primary,
                  icon: Icons.arrow_forward_rounded,
                  onPressed: controller.completeOnboarding,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
