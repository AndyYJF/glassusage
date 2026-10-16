import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Trust on first use, then fail closed on identity changes. Keep fingerprints
/// separate from OpenSSH's public-key records so neither format is corrupted.
class SshHostKeys {
  SshHostKeys(this.knownHostsPath);
  final String knownHostsPath;

  bool verify(String host, int port, String type, String fingerprint) {
    final identity = port == 22 ? host : '[$host]:$port';
    final trusted = <(String, String)>[];
    final legacy = File(knownHostsPath);
    if (legacy.existsSync()) {
      for (final line in legacy.readAsLinesSync()) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length < 3 || line.trimLeft().startsWith('#')) continue;
        final revoked = fields.first == '@revoked';
        final start = fields.first.startsWith('@') ? 1 : 0;
        if (fields.length < start + 3) continue;
        if (!fields[start]
            .split(',')
            .any((entry) => _matches(entry, identity))) {
          continue;
        }
        final digest = base64Encode(
          sha256.convert(base64Decode(fields[start + 2])).bytes,
        ).replaceAll('=', '');
        if (revoked && fingerprint == 'SHA256:$digest') {
          throw StateError('SSH host key is revoked for $identity');
        }
        if (!revoked) trusted.add((fields[start + 1], 'SHA256:$digest'));
      }
    }
    final file = File('$knownHostsPath.fingerprints.json');
    final saved =
        file.existsSync()
            ? (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)
            : <String, dynamic>{};
    if (saved.containsKey(identity)) {
      final key = saved[identity] as Map<String, dynamic>;
      trusted.add((key['type'] as String, key['fingerprint'] as String));
    }
    if (trusted.isNotEmpty) {
      if (trusted.contains((type, fingerprint))) return true;
      throw StateError(
        'SSH host key changed for $identity. Verify the server identity before resetting its saved host key.',
      );
    }
    saved[identity] = {'type': type, 'fingerprint': fingerprint};
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(saved), flush: true);
    return true;
  }

  bool _matches(String entry, String identity) {
    if (!entry.startsWith('|1|')) return entry == identity;
    final parts = entry.split('|');
    if (parts.length != 4) return false;
    return base64Encode(
          Hmac(
            sha1,
            base64Decode(parts[2]),
          ).convert(utf8.encode(identity)).bytes,
        ) ==
        parts[3];
  }
}
