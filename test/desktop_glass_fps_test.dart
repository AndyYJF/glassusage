import 'package:desktop_glass/desktop_glass.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('glassusage/desktop_glass');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Windows accepts high refresh capture rates', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    int? requested;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          requested = (call.arguments as Map)['targetFps'] as int;
          return {'sessionId': 1, 'textureId': 2};
        });
    final session = await const DesktopGlass().start(targetFps: 240);
    expect(requested, 240);
    expect(session.textureId, 2);
    await expectLater(
      const DesktopGlass().start(targetFps: 241),
      throwsArgumentError,
    );
  });

  test('macOS retains its capture rate limit', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await expectLater(
      const DesktopGlass().start(targetFps: 61),
      throwsArgumentError,
    );
  });
}
