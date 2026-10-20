import 'package:flutter_test/flutter_test.dart';
import 'package:desktop_glass/desktop_glass.dart';

void main() {
  test('historical frames do not mark a recovering stream as live', () {
    final stats = GlassStats({
      'frames': 120,
      'hasValidFrame': false,
      'captureState': 'recovering',
      'recoveryEpoch': 3,
    });

    expect(stats.frames, 120);
    expect(stats.hasValidFrame, isFalse);
    expect(stats.captureState, 'recovering');
    expect(stats.recoveryEpoch, 3);
  });

  test('a complete frame marks the current stream valid', () {
    final stats = GlassStats({
      'frames': 121,
      'hasValidFrame': true,
      'captureState': 'live',
      'lastFrameAgeMs': 12.5,
    });

    expect(stats.hasValidFrame, isTrue);
    expect(stats.captureState, 'live');
    expect(stats.lastFrameAgeMs, 12.5);
  });

  test('older platforms retain the cumulative-frame fallback', () {
    final live = GlassStats({'frames': 1});
    final waiting = GlassStats({'frames': 0});

    expect(live.hasValidFrame, isTrue);
    expect(waiting.hasValidFrame, isFalse);
    expect(live.captureState, 'unknown');
  });
}
