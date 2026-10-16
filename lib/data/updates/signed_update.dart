import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:pinenacl/ed25519.dart';
import 'package:pointycastle/digests/blake2b.dart';

// Same pinned public key as the original Tauri updater. Never trust a key
// supplied by release metadata or downloaded alongside the installer.
const updaterPublicKey =
    'dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDE4MDMxMTExRTQ4NjAzMDQKUldRRUE0YmtFUkVER0FzSzFGbTkwL21WUGtoYlVtNzFSWi9TSlNZUndDeTNkcmNudDhhK1pvVncK';

String _minisignText(String value) {
  final text = value.trim();
  return text.startsWith('untrusted comment:')
      ? text
      : utf8.decode(base64Decode(text)).trim();
}

/// Verify both Minisign signatures (payload and trusted comment). Tauri uses
/// base64-encoded Minisign text and ED/Blake2b prehashed file signatures.
Future<void> verifyUpdateFile(
  File file,
  String signature, {
  String publicKey = updaterPublicKey,
}) async {
  final keyLines = const LineSplitter().convert(_minisignText(publicKey));
  final lines = const LineSplitter().convert(_minisignText(signature));
  if (keyLines.length != 2 ||
      lines.length != 4 ||
      !lines[2].startsWith('trusted comment: ')) {
    throw const FormatException('Invalid update signature');
  }
  final key = base64Decode(keyLines[1]);
  final packet = base64Decode(lines[1]);
  final global = base64Decode(lines[3]);
  if (key.length != 42 ||
      packet.length != 74 ||
      global.length != 64 ||
      key[0] != 69 ||
      key[1] != 100 ||
      packet[0] != 69 ||
      (packet[1] != 68 && packet[1] != 100)) {
    throw const FormatException('Unsupported update signature');
  }
  for (var i = 2; i < 10; i++) {
    if (key[i] != packet[i]) {
      throw const FormatException('Update signing key mismatch');
    }
  }
  final verifier = VerifyKey(Uint8List.fromList(key.sublist(10)));
  final payloadSignature = Uint8List.fromList(packet.sublist(10));
  final comment = utf8.encode(lines[2].substring('trusted comment: '.length));
  verifier.verify(
    signature: Signature(global),
    message: Uint8List.fromList([...payloadSignature, ...comment]),
  );
  Uint8List message;
  if (packet[1] == 68) {
    final hash = Blake2bDigest();
    await for (final chunk in file.openRead()) {
      final bytes = Uint8List.fromList(chunk);
      hash.update(bytes, 0, bytes.length);
    }
    message = Uint8List(64);
    hash.doFinal(message, 0);
  } else {
    message = await file.readAsBytes();
  }
  verifier.verify(signature: Signature(payloadSignature), message: message);
}

Uri updateDownloadUri(String url) {
  final uri = Uri.parse(url);
  if (uri.scheme != 'https' ||
      uri.host != 'github.com' ||
      !uri.path.startsWith('/AndyYJF/glassusage/releases/download/')) {
    throw const FormatException('Untrusted update download URL');
  }
  return uri;
}

Future<File> downloadSignedUpdate(
  String url,
  String signature, {
  required void Function(double) onProgress,
}) async {
  final uri = updateDownloadUri(url);
  final directory = await Directory.systemTemp.createTemp('glassusage-update-');
  final file = File('${directory.path}/setup.exe');
  final client = http.Client();
  try {
    final response = await client
        .send(http.Request('GET', uri))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HttpException('Download HTTP ${response.statusCode}');
    }
    final total = response.contentLength;
    const maximum = 256 * 1024 * 1024;
    if (total != null && total > maximum) {
      throw const FormatException('Update too large');
    }
    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        received += chunk.length;
        if (received > maximum) throw const FormatException('Update too large');
        sink.add(chunk);
        if (total != null && total > 0) onProgress(received / total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (received == 0 || (total != null && total != received)) {
      throw const FormatException('Incomplete update download');
    }
    await Isolate.run(() => verifyUpdateFile(file, signature));
    return file;
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
  } finally {
    client.close();
  }
}
