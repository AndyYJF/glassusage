import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:pinenacl/ed25519.dart';
import 'package:pointycastle/digests/blake2b.dart';
import 'package:glassusage/data/database/app_database.dart';
import 'package:glassusage/data/pricing/pricing_service.dart';
import 'package:glassusage/data/remote/ssh_host_keys.dart';
import 'package:glassusage/data/updates/signed_update.dart';
import 'package:glassusage/domain/models/usage_models.dart';

UsageEvent event(
  int timestamp, {
  String key = 'one',
  String source = 'cursor',
  double cost = 9.99,
  bool? native,
}) => UsageEvent(
  source: source,
  surface: 'cli',
  instance: 'local',
  dedupKey: key,
  timestamp: timestamp,
  model: 'test-model',
  modelNorm: 'test-model',
  inputTokens: 100,
  costUsd: cost,
  costIsNative: native,
);

void main() {
  late Directory temp;
  setUp(
    () => temp = Directory.systemTemp.createTempSync('glassusage-regression-'),
  );
  tearDown(() => temp.deleteSync(recursive: true));

  test(
    'cost-only updates, reductions and moving days refresh rollups without live spikes',
    () {
      final db = AppDatabase.open(temp.path);
      addTearDown(db.dispose);
      final now = DateTime.now();
      final today =
          DateTime(now.year, now.month, now.day, 12).millisecondsSinceEpoch;
      final yesterday =
          DateTime(now.year, now.month, now.day - 1, 12).millisecondsSinceEpoch;
      final original = event(today);
      db.ingest([original], WriteMode.upsert);
      final costOnly = original.copyWith(costUsd: 5);
      final corrected = db.ingest([costOnly], WriteMode.upsert);
      expect(corrected.changed, 1);
      expect(corrected.deltas, isEmpty);
      expect(db.overview(0, today + 60000).today.costUsd, 5);
      final reduced = costOnly.copyWith(
        inputTokens: 20,
        modelNorm: 'corrected',
      );
      expect(db.ingest([reduced], WriteMode.upsert).deltas, isEmpty);
      expect(db.overview(0, today + 60000).today.totalTokens, 20);
      final moved = reduced.copyWith(timestamp: yesterday);
      expect(db.ingest([moved], WriteMode.upsert).changed, 1);
      final overview = db.overview(0, today + 60000);
      expect(overview.today.totalTokens, 0);
      expect(overview.yesterday.totalTokens, 20);
      expect(overview.yesterday.costUsd, 5);
      expect(db.ingest([moved], WriteMode.upsert).changed, 0);
    },
  );

  test(
    'reprice preserves actual bills but updates estimates, including after reopen',
    () {
      final now = AppDatabase.nowMs();
      var db = AppDatabase.open(temp.path);
      for (final source in ['cursor', 'hermes', 'pi', 'openclaw', 'opencode']) {
        db.ingest([event(now, key: source, source: source)], WriteMode.upsert);
      }
      db.ingest([
        event(now, key: 'estimated', native: false),
      ], WriteMode.upsert);
      db.dispose();
      db = AppDatabase.open(temp.path);
      addTearDown(db.dispose);
      final pricing = PricingService.forTest(
        prices: {
          'test-model': const ModelPrice(
            inputCostPerToken: 0.001,
            outputCostPerToken: 0.002,
          ),
        },
        tempDir: temp.path,
      );
      db.reprice(pricing);
      final rows = db.usageLog(const UsageFilter(), 0, 100).rows;
      expect(rows.where((r) => r.costUsd == 9.99), hasLength(5));
      expect(rows.where((r) => r.costUsd == 0.1), hasLength(1));
    },
  );

  test(
    'JSON exports all records beyond pagination limit and CSV neutralizes formulas',
    () {
      final db = AppDatabase.open(temp.path);
      addTearDown(db.dispose);
      final now = AppDatabase.nowMs();
      db.ingest(
        List.generate(
          1201,
          (i) =>
              event(now + i, key: '$i')
                ..project = '=HYPERLINK("https://example.invalid","click")',
        ),
        WriteMode.upsert,
      );
      final json = File('${temp.path}/export.json');
      db.exportJson(const UsageFilter(), json.path);
      expect(jsonDecode(json.readAsStringSync()) as List, hasLength(1201));
      final csv = File('${temp.path}/export.csv');
      db.exportCsv(const UsageFilter(), csv.path);
      expect(csv.readAsStringSync(), contains('"\'=HYPERLINK('));
    },
  );

  test(
    'SSH TOFU pins identities, rejects changes and respects existing OpenSSH keys',
    () {
      final known = '${temp.path}/known_hosts';
      final keys = SshHostKeys(known);
      expect(keys.verify('host', 22, 'ssh-ed25519', 'SHA256:first'), isTrue);
      expect(keys.verify('host', 22, 'ssh-ed25519', 'SHA256:first'), isTrue);
      expect(
        () => keys.verify('host', 22, 'ssh-ed25519', 'SHA256:changed'),
        throwsStateError,
      );
      expect(
        keys.verify('host', 2222, 'ssh-ed25519', 'SHA256:different-port'),
        isTrue,
      );
      final raw = List<int>.generate(32, (i) => i);
      File(
        known,
      ).writeAsStringSync('legacy ssh-ed25519 ${base64Encode(raw)}\n');
      final fingerprint =
          'SHA256:${base64Encode(sha256.convert(raw).bytes).replaceAll('=', '')}';
      expect(keys.verify('legacy', 22, 'ssh-ed25519', fingerprint), isTrue);
      expect(
        () => keys.verify('legacy', 22, 'ssh-ed25519', 'SHA256:new'),
        throwsStateError,
      );
    },
  );

  test(
    'Minisign verifies payload AND trusted comment; refuses tampering and wrong keys',
    () async {
      final signing = SigningKey(
        seed: Uint8List.fromList(List.generate(32, (i) => i)),
      );
      final id = List<int>.generate(8, (i) => i + 1);
      final publicKey =
          'untrusted comment: test\n${base64Encode([69, 100, ...id, ...signing.verifyKey])}';
      final file = File('${temp.path}/installer.exe')
        ..writeAsBytesSync([1, 2, 3, 4]);
      final digest = Blake2bDigest().process(Uint8List.fromList([1, 2, 3, 4]));
      final sig = signing.sign(digest).signature;
      const comment = 'timestamp:1 file:setup.exe';
      final global =
          signing
              .sign(Uint8List.fromList([...sig, ...utf8.encode(comment)]))
              .signature;
      final text =
          'untrusted comment: test\n${base64Encode([69, 68, ...id, ...sig])}\ntrusted comment: $comment\n${base64Encode(global)}';
      await verifyUpdateFile(
        file,
        base64Encode(utf8.encode(text)),
        publicKey: publicKey,
      );
      await expectLater(
        verifyUpdateFile(
          file,
          text.replaceFirst('timestamp:1', 'timestamp:2'),
          publicKey: publicKey,
        ),
        throwsA(anything),
      );
      file.writeAsBytesSync([1, 2, 3, 5]);
      await expectLater(
        verifyUpdateFile(file, text, publicKey: publicKey),
        throwsA(anything),
      );
      await expectLater(verifyUpdateFile(file, text), throwsA(anything));
      expect(
        () => updateDownloadUri(
          'http://github.com/AndyYJF/glassusage/releases/download/v1/setup.exe',
        ),
        throwsFormatException,
      );
      expect(
        () => updateDownloadUri('https://evil.invalid/setup.exe'),
        throwsFormatException,
      );
    },
  );
}
