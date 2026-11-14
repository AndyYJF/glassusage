// Isolated dart:ui fixture. No Flutter app, plugins, files or network access.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

int tick = 0;
int clicks = 0;
int frames = 0;

Future<void> exportRgba(ui.Image image) async {
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes != null) {
      ui.PlatformDispatcher.instance.sendPlatformMessage('fixture/rgba', bytes, null);
    }
  } finally {
    image.dispose();
  }
}

void report(Map<String, Object> message) {
  ui.PlatformDispatcher.instance.sendPlatformMessage(
    'fixture/event', Uint8List.fromList(utf8.encode(jsonEncode(message))).buffer.asByteData(), null,
  );
}

void draw() {
  final view = ui.PlatformDispatcher.instance.implicitView;
  if (view == null || view.physicalSize.isEmpty) return;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0x00000000), ui.BlendMode.src);
  canvas.drawRect(
    const ui.Rect.fromLTWH(32, 32, 128, 64),
    ui.Paint()..color = clicks == 0 ? const ui.Color(0xffff0000) : const ui.Color(0xff00ff00),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(192, 32, 128, 64),
    ui.Paint()..color = const ui.Color(0x80ff0000),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(32, 128, 128, 64),
    ui.Paint()..color = tick.isEven ? const ui.Color(0xff00ff00) : const ui.Color(0xffff00ff),
  );
  final code = (tick + clicks * 64) & 255;
  for (var bit = 0; bit < 8; bit++) {
    canvas.drawRect(
      ui.Rect.fromLTWH(bit * 81, 200, 81, 200),
      ui.Paint()..color = (code & (1 << bit)) != 0
          ? const ui.Color(0xff00ff00) : const ui.Color(0xffff00ff),
    );
  }
  final picture = recorder.endRecording();
  unawaited(exportRgba(picture.toImageSync(648, 400)));
  final builder = ui.SceneBuilder()..addPicture(ui.Offset.zero, picture);
  final scene = builder.build();
  view.render(scene);
  scene.dispose();
  picture.dispose();
  frames++;
  report({'event': 'frame', 'tick': tick, 'clicks': clicks, 'frame': frames, 'code': code});
}

void main() {
  final dispatcher = ui.PlatformDispatcher.instance;
  dispatcher.onDrawFrame = draw;
  dispatcher.onMetricsChanged = dispatcher.scheduleFrame;
  dispatcher.onPointerDataPacket = (packet) {
    for (final pointer in packet.data) {
      if (pointer.change == ui.PointerChange.down) {
        clicks++;
        report({'event': 'pointer_down', 'x': pointer.physicalX,
          'y': pointer.physicalY, 'clicks': clicks});
        dispatcher.scheduleFrame();
      }
    }
  };
  Timer.periodic(const Duration(milliseconds: 200), (_) {
    tick++;
    dispatcher.scheduleFrame();
  });
  dispatcher.scheduleFrame();
}
