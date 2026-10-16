import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glassusage/domain/models/usage_models.dart';
import 'package:glassusage/presentation/widgets/charts.dart';

void main() {
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
