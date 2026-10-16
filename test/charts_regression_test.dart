import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glassusage/domain/models/usage_models.dart';
import 'package:glassusage/core/i18n/app_i18n.dart';
import 'package:glassusage/presentation/widgets/charts.dart';

void main() {
  testWidgets(
    'tooltip aggregates exact bucket details and stays inside viewport',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(700, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final previewPath = Platform.environment['GLASSUSAGE_TOOLTIP_PREVIEW'];
      if (previewPath != null) {
        // Use a real local font for the visual artifact, not test Ahem boxes.
        await tester.runAsync(() async {
          final font = FontLoader('TooltipPreview');
          font.addFont(
            File('C:/Windows/Fonts/msyh.ttc').readAsBytes().then(
              (bytes) => bytes.buffer.asByteData(
                bytes.offsetInBytes,
                bytes.lengthInBytes,
              ),
            ),
          );
          await font.load();
        });
      }
      final screenshot = GlobalKey();
      final timestamp = DateTime(2026, 10, 16, 21).millisecondsSinceEpoch;
      final points = [
        SeriesPoint(
          bucket: timestamp,
          key: 'gpt-6.1-sol',
          totals: const TokenBreakdown(
            inputTokens: 1000000,
            totalTokens: 1000000,
            events: 1,
          ),
        ),
        SeriesPoint(
          bucket: timestamp,
          key: 'gpt-6.1-sol',
          totals: const TokenBreakdown(
            inputTokens: 758867,
            outputTokens: 284535,
            cacheReadTokens: 45558400,
            totalTokens: 46601802,
            events: 1,
          ),
        ),
        SeriesPoint(
          bucket: timestamp,
          key: 'codex-auto-review',
          totals: const TokenBreakdown(
            inputTokens: 100000,
            totalTokens: 100000,
            events: 1,
          ),
        ),
        SeriesPoint(
          bucket: timestamp + 3600000,
          key: 'other-hour',
          totals: const TokenBreakdown(
            inputTokens: 999,
            totalTokens: 999,
            events: 1,
          ),
        ),
      ];
      Widget fixture({bool showCost = false}) => RepaintBoundary(
        key: screenshot,
        child: MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: previewPath == null ? null : 'TooltipPreview',
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: 600,
                  child: UsageChart(
                    points: points,
                    bucket: 'hour',
                    height: 220,
                    colorBy: UsageChartColorMode.palette,
                    showCost: showCost,
                    i18n: const AppI18n(isZh: true),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(fixture());
      final plot =
          find
              .descendant(
                of: find.byType(UsageChart),
                matching: find.byType(CustomPaint),
              )
              .first;
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getTopLeft(plot) + const Offset(52, 100));
      await tester.pump();
      final tooltip = find.byKey(const ValueKey('usage-chart-tooltip'));
      expect(tooltip, findsOneWidget);
      for (final text in [
        '输入',
        '输出',
        '缓存创建',
        '缓存命中',
        '费用',
        'Token 合计',
        '1,858,867',
        '284,535',
        '45,558,400',
        '47,701,802',
        '0',
        r'$0.000000',
        'gpt-6.1-sol',
        'codex-auto-review',
      ]) {
        expect(
          find.descendant(of: tooltip, matching: find.text(text)),
          findsOneWidget,
        );
      }
      final rect = tester.getRect(tooltip);
      final viewport = tester.getSize(find.byType(Scaffold));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(viewport.width));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(viewport.height));
      expect(rect.height, greaterThan(220));
      expect(tester.takeException(), isNull);
      final preview = Platform.environment['GLASSUSAGE_TOOLTIP_PREVIEW'];
      if (preview != null) {
        await tester.runAsync(() async {
          final boundary =
              screenshot.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes =
              (await image.toByteData(format: ui.ImageByteFormat.png))!;
          await File(preview).writeAsBytes(bytes.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(fixture(showCost: true));
      await mouse.moveTo(tester.getTopLeft(plot) + const Offset(54, 100));
      await tester.pump();
      expect(
        find.descendant(of: tooltip, matching: find.text('1,858,867')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tooltip, matching: find.text(r'$0.000000')),
        findsOneWidget,
      );
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(tooltip, findsNothing);
    },
  );

  testWidgets('unpriced tooltip does not pretend missing prices are free', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: UsageChart(
              points: [
                SeriesPoint(
                  bucket: DateTime(2026, 10, 16).millisecondsSinceEpoch,
                  key: 'unknown',
                  totals: const TokenBreakdown(
                    inputTokens: 123,
                    totalTokens: 123,
                    events: 1,
                    unpricedEvents: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final plot =
        find
            .descendant(
              of: find.byType(UsageChart),
              matching: find.byType(CustomPaint),
            )
            .first;
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(plot));
    await tester.pump();
    expect(find.text('—'), findsOneWidget);
    expect(find.text('no price for these models'), findsOneWidget);
    expect(find.text(r'$0.000000'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one populated bucket remains visibly painted without hovering', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
            child: SizedBox(
              width: 600,
              child: UsageChart(
                colorBy: UsageChartColorMode.palette,
                bucket: 'hour',
                points: [
                  SeriesPoint(
                    bucket: DateTime(2026, 10, 16, 10).millisecondsSinceEpoch,
                    key: 'test',
                    totals: const TokenBreakdown(totalTokens: 100),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final render =
        boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final bluePixels = await tester.runAsync(() async {
      final image = await render.toImage();
      final bytes =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      // The blue legend is above y=30. Count series pixels only in the plot,
      // excluding grid, labels and the legend: a moveTo-only path paints none.
      var bluePixels = 0;
      for (var y = 35; y < 240; y++) {
        for (var x = 60; x < 590; x++) {
          final offset = (y * image.width + x) * 4;
          if (bytes.getUint8(offset + 2) > 210 &&
              bytes.getUint8(offset) < 60 &&
              bytes.getUint8(offset + 1) > 100 &&
              bytes.getUint8(offset + 1) < 170) {
            bluePixels++;
          }
        }
      }
      image.dispose();
      return bluePixels;
    });
    expect(bluePixels, greaterThan(10));
    expect(tester.takeException(), isNull);
  });

  test('switching day ranges back to today restores hour labels', () {
    final timestamp = DateTime(2026, 10, 16, 10, 0).millisecondsSinceEpoch;
    expect(chartBucketLabel(timestamp, 'day'), isNot(contains(':')));
    expect(chartBucketLabel(timestamp, 'hour'), '10:00');
    expect(chartBucketLabel(timestamp, 'month'), '2026-10');
    expect(chartBucketLabel(timestamp, 'hour'), '10:00');
  });
}
