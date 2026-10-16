import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glassusage/domain/models/settings_model.dart';
import 'package:glassusage/main.dart';
import 'package:glassusage/presentation/providers/app_providers.dart';

void main() {
  testWidgets('GlassUsageApp renders shell and navigates across views',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(
            (ref) => AppSettings(locale: LocaleMode.en, firstRunDone: true),
          ),
        ],
        child: const GlassUsageApp(autoInitialize: false),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('GlassUsage'), findsOneWidget);
    expect(find.text('Dashboard'), findsWidgets);

    // Navigate to Compare
    await tester.tap(find.text('Compare').first);
    await tester.pumpAndSettle();
    expect(find.text('Compare Agents & Models'), findsOneWidget);

    // Navigate to Settings
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(find.text('Appearance & Liquid Glass'), findsOneWidget);

    // Test MiniCard mode
    final container = ProviderScope.containerOf(
      tester.element(find.byType(GlassUsageApp)),
    );
    container.read(isMiniCardModeProvider.notifier).state = true;
    await tester.pumpAndSettle();
    expect(find.text('GLASSUSAGE LIVE'), findsOneWidget);
  });
}
