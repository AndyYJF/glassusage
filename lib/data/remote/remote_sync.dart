import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../core/security/dpapi.dart';
import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../collectors/all_collectors.dart';
import '../collectors/collector_base.dart';
import '../database/app_database.dart';
import '../live/live_tracker.dart';
import '../pricing/pricing_service.dart';
import 'ssh_client.dart';

typedef SourceStatusCallback = void Function(
  String source,
  String instance,
  HealthStatus status,
  String? error,
);

typedef UsageUpdatedCallback = void Function(
  String source,
  String instance,
  int added,
);

String safeSnapshotPath(String snapshotDir, String relative) {
  if (relative.isEmpty ||
      relative.startsWith('/') ||
      relative.startsWith('\\') ||
      relative.contains('\\') ||
      relative.contains(':')) {
    throw ArgumentError('unsafe remote snapshot path: $relative');
  }
  final parts = relative.split('/');
  for (final part in parts) {
    if (part.isEmpty || part == '.' || part == '..') {
      throw ArgumentError('unsafe remote snapshot path: $relative');
    }
  }
  return p.joinAll([snapshotDir, ...parts]);
}

void validateRemoteComponent(String component) {
  if (component.isEmpty ||
      component == '.' ||
      component == '..' ||
      component.contains('/') ||
      component.contains('\\') ||
      component.contains('\x00') ||
      component.contains('\r') ||
      component.contains('\n')) {
    throw ArgumentError('unsafe remote filename: $component');
  }
}

bool isSqlitePath(String path) {
  final ext = p.extension(path).toLowerCase();
  return ext == '.sqlite' || ext == '.db';
}

String sidecarPath(String path, String suffix) {
  return p.join(p.dirname(path), '${p.basename(path)}$suffix');
}

void replaceDownloadSet(List<(String?, String)> entries) {
  final backups = <(String, String)>[];
  for (final (_, target) in entries) {
    final backup = p.join(
      p.dirname(target),
      '.${p.basename(target)}.glassusage-previous',
    );
    final backupFile = File(backup);
    if (backupFile.existsSync()) {
      try {
        backupFile.deleteSync();
      } catch (_) {}
    }
    final targetFile = File(target);
    if (targetFile.existsSync()) {
      try {
        targetFile.renameSync(backup);
        backups.add((target, backup));
      } catch (e) {
        for (final (orig, prev) in backups.reversed) {
          try {
            File(prev).renameSync(orig);
          } catch (_) {}
        }
        rethrow;
      }
    }
  }

  final installed = <String>[];
  for (final (staged, target) in entries) {
    if (staged == null) continue;
    try {
      File(staged).renameSync(target);
      installed.add(target);
    } catch (e) {
      for (final instPath in installed.reversed) {
        try {
          File(instPath).deleteSync();
        } catch (_) {}
      }
      for (final (orig, prev) in backups.reversed) {
        if (File(prev).existsSync()) {
          try {
            File(prev).renameSync(orig);
          } catch (_) {}
        }
      }
      rethrow;
    }
  }

  for (final (_, backup) in backups) {
    try {
      final f = File(backup);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

Future<void> downloadVerified(
  AppSshClient client,
  String remotePath,
  String localPath,
  int expectedSize,
  bool useBackup,
) async {
  final parent = p.dirname(localPath);
  Directory(parent).createSync(recursive: true);
  final temp = p.join(
    parent,
    '.${p.basename(localPath)}.glassusage-download-$pid-${AppDatabase.nowMs()}',
  );

  try {
    if (isSqlitePath(localPath)) {
      await client.snapshotSqlite(remotePath, temp, useBackup);
      final conn = sqlite3.open(temp, mode: OpenMode.readOnly);
      try {
        final rows = conn.select('PRAGMA quick_check');
        final check = rows.isEmpty ? '' : (rows.first.values.first as String? ?? '');
        if (check != 'ok') {
          throw StateError('downloaded SQLite snapshot failed quick_check: $check');
        }
      } finally {
        conn.dispose();
      }

      final entries = <(String?, String)>[(temp, localPath)];
      for (final suffix in const ['-wal', '-shm']) {
        final tempSide = sidecarPath(temp, suffix);
        final targetSide = sidecarPath(localPath, suffix);
        entries.add((
          File(tempSide).existsSync() ? tempSide : null,
          targetSide,
        ));
      }
      replaceDownloadSet(entries);
    } else {
      await client.download(remotePath, temp);
      final actualSize = File(temp).lengthSync();
      if (expectedSize >= 0 && actualSize != expectedSize) {
        throw StateError(
          'downloaded file size mismatch: expected $expectedSize, got $actualSize',
        );
      }
      replaceDownloadSet([(temp, localPath)]);
    }
  } catch (_) {
    try {
      final f = File(temp);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    for (final suffix in const ['-wal', '-shm']) {
      try {
        final s = File(sidecarPath(temp, suffix));
        if (s.existsSync()) s.deleteSync();
      } catch (_) {}
    }
    rethrow;
  }
}

Future<List<(String, String)>> enumerateRemoteFiles(
  AppSshClient client,
  RemoteInstance inst,
  String home,
) async {
  final out = <(String, String)>[];
  switch (inst.agent) {
    case 'hermes':
      final base = (inst.remotePath != null && inst.remotePath!.trim().isNotEmpty)
          ? inst.remotePath!.trim()
          : '$home/.hermes/state.db';
      if (await client.stat(base) != null) {
        out.add((base, 'state.db'));
      }
      final profilesDir = '$home/.hermes/profiles';
      for (final profile in await client.listDir(profilesDir)) {
        validateRemoteComponent(profile);
        final db = '$profilesDir/$profile/state.db';
        if (await client.stat(db) != null) {
          out.add((db, 'profiles/$profile/state.db'));
        }
      }
      break;
    case 'openclaw':
      final root = (inst.remotePath != null && inst.remotePath!.trim().isNotEmpty)
          ? inst.remotePath!.trim()
          : '$home/.openclaw';
      for (final agentId in await client.listDir('$root/agents')) {
        validateRemoteComponent(agentId);
        final agentDir = '$root/agents/$agentId/agent';
        for (final f in await client.listDir(agentDir)) {
          validateRemoteComponent(f);
          if ((f.endsWith('.sqlite') || f.endsWith('.db')) &&
              !f.contains('.reindex-lock.')) {
            out.add(('$agentDir/$f', 'agents/$agentId/agent/$f'));
          }
        }
        final sessions = '$root/agents/$agentId/sessions';
        for (final f in await client.listDir(sessions)) {
          validateRemoteComponent(f);
          if (f.endsWith('.jsonl')) {
            out.add(('$sessions/$f', 'agents/$agentId/sessions/$f'));
          }
        }
        if (inst.importArchives) {
          final archives = '$root/agents/$agentId/archives';
          for (final f in await client.listDir(archives)) {
            validateRemoteComponent(f);
            if (f.endsWith('.jsonl')) {
              out.add(('$archives/$f', 'agents/$agentId/archives/$f'));
            }
          }
        }
      }
      break;
    default:
      throw ArgumentError('unsupported remote agent type: ${inst.agent}');
  }
  return out;
}

Future<int> syncRemoteInstance({
  required String dataDir,
  required AppDatabase store,
  required PricingService pricing,
  required AppSettings settings,
  required LiveTracker live,
  required String name,
  required SourceStatusCallback onStatus,
  required UsageUpdatedCallback onUpdated,
}) async {
  final instances = store.listRemote();
  final inst = instances.where((i) => i.name == name).firstOrNull;
  if (inst == null) {
    throw ArgumentError('no such instance: $name');
  }
  inst.validate();

  onStatus(inst.agent, inst.name, HealthStatus.polling, null);

  String? password;
  if (inst.authMode == 'password') {
    final secret = store.remoteSecret(inst.name);
    if (secret != null) {
      try {
        password = Dpapi.unprotectStr(secret);
      } catch (_) {}
    }
  }

  final client = AppSshClient(
    instance: inst,
    password: password,
    knownHostsPath: p.join(dataDir, 'ssh-known-hosts'),
  );

  try {
    String home;
    if (inst.remoteHome != null && inst.remoteHome!.trim().isNotEmpty) {
      home = inst.remoteHome!.trim();
      while (home.endsWith('/')) {
        home = home.substring(0, home.length - 1);
      }
    } else {
      home = await client.remoteHome();
      store.setRemoteHome(inst.name, home);
    }

    final snapshotDir = p.join(dataDir, 'remote', inst.name);
    Directory(snapshotDir).createSync(recursive: true);

    final useBackup = await client.hasSqlite3();
    final remoteFiles = await enumerateRemoteFiles(client, inst, home);
    if (remoteFiles.isEmpty) {
      throw StateError(
        'no ${inst.agent} data found on the remote host (looked under $home)',
      );
    }

    for (final (remotePath, localRel) in remoteFiles) {
      final st = await client.stat(remotePath);
      if (st == null) continue;
      final (mtime, size) = st;
      final key = 'remote:${inst.name}:$remotePath';
      final prev = store.getScanState(inst.agent, inst.name, key);
      final localPath = safeSnapshotPath(snapshotDir, localRel);
      final sqliteFile = isSqlitePath(localPath);

      if (prev != null) {
        final localFile = File(localPath);
        final localOk = localFile.existsSync() &&
            (sqliteFile
                ? localFile.lengthSync() > 0
                : localFile.lengthSync() == size);
        if (prev.mtimeMs == mtime * 1000 && prev.offset == size && localOk) {
          continue;
        }
      }

      await downloadVerified(client, remotePath, localPath, size, useBackup);
      store.setScanState(
        inst.agent,
        inst.name,
        key,
        ScanState(
          offset: size,
          mtimeMs: mtime * 1000,
          extra: localRel,
        ),
      );
    }

    final collector = collectorById(inst.agent);
    if (collector == null) {
      throw StateError('unknown agent ${inst.agent}');
    }
    final ctx = ScanCtx(
      store: store,
      pricing: pricing,
      settings: settings,
      instance: inst.name,
      rootOverride: snapshotDir,
    );
    final report = collector.scan(ctx);
    final outcome = store.ingestScan(
      report.events,
      collector.writeMode,
      report.states,
    );
    live.push(outcome.deltas);
    if (outcome.changed > 0) {
      live.markTotalsDirty();
    }
    store.recordStatus(
      inst.agent,
      inst.name,
      report.filesSeen,
      report.skipped,
      report.detectedPaths,
      null,
    );
    onStatus(inst.agent, inst.name, HealthStatus.polling, null);
    if (outcome.changed > 0) {
      onUpdated(inst.agent, inst.name, outcome.changed);
    }
    return outcome.changed;
  } catch (e) {
    final msg = e.toString();
    store.recordStatus(inst.agent, inst.name, 0, 0, const [], msg);
    onStatus(inst.agent, inst.name, HealthStatus.error, msg);
    rethrow;
  } finally {
    client.close();
  }
}

Future<TestReport> testRemoteInstance({
  required String dataDir,
  required AppDatabase store,
  required PricingService pricing,
  required AppSettings settings,
  required RemoteInstanceInput input,
}) async {
  final steps = <TestStep>[];
  try {
    input.validate();
  } catch (e) {
    steps.add(
      TestStep(label: 'Configuration', ok: false, detail: e.toString()),
    );
    return TestReport(ok: false, steps: steps);
  }

  final inst = input.toInstance();
  String? password = input.password;
  if (password == null || password.isEmpty) {
    final secret = store.remoteSecret(inst.name);
    if (secret != null) {
      try {
        password = Dpapi.unprotectStr(secret);
      } catch (_) {}
    }
  }

  final client = AppSshClient(
    instance: inst,
    password: password,
    knownHostsPath: p.join(dataDir, 'ssh-known-hosts'),
  );

  try {
    String home;
    try {
      home = await client.remoteHome();
      steps.add(
        TestStep(
          label: 'SSH connection',
          ok: true,
          detail: 'connected as ${inst.username}@${inst.host}, home = $home',
        ),
      );
    } catch (e) {
      steps.add(
        TestStep(label: 'SSH connection', ok: false, detail: e.toString()),
      );
      return TestReport(ok: false, steps: steps);
    }

    List<(String, String)> files;
    try {
      files = await enumerateRemoteFiles(client, inst, home);
      if (files.isEmpty) {
        steps.add(
          TestStep(
            label: 'Data path',
            ok: false,
            detail: 'no ${inst.agent} data under $home',
          ),
        );
        return TestReport(ok: false, steps: steps);
      }
      steps.add(
        TestStep(
          label: 'Data path',
          ok: true,
          detail: 'found ${files.length} database file(s)',
        ),
      );
    } catch (e) {
      steps.add(TestStep(label: 'Data path', ok: false, detail: e.toString()));
      return TestReport(ok: false, steps: steps);
    }

    final testDir = p.join(dataDir, 'remote', '${inst.name}__test');
    final testDirObj = Directory(testDir);
    if (testDirObj.existsSync()) {
      try {
        testDirObj.deleteSync(recursive: true);
      } catch (_) {}
    }
    testDirObj.createSync(recursive: true);

    final useBackup = await client.hasSqlite3();
    final (remotePath, localRel) = files.first;
    try {
      final localPath = safeSnapshotPath(testDir, localRel);
      await downloadVerified(client, remotePath, localPath, -1, useBackup);
      steps.add(
        TestStep(
          label: 'Snapshot',
          ok: true,
          detail: useBackup
              ? 'pulled a consistent snapshot via sqlite3 .backup'
              : 'sqlite3 not available on the host; copied the database with its WAL sidecars',
        ),
      );
    } catch (e) {
      steps.add(TestStep(label: 'Snapshot', ok: false, detail: e.toString()));
      return TestReport(ok: false, steps: steps);
    }

    final collector = collectorById(inst.agent);
    if (collector == null) {
      steps.add(
        TestStep(
          label: 'Parse',
          ok: false,
          detail: 'no collector for agent type ${inst.agent}',
        ),
      );
    } else {
      try {
        final ctx = ScanCtx(
          store: store,
          pricing: pricing,
          settings: settings,
          instance: '${inst.name}__test',
          rootOverride: testDir,
        );
        final report = collector.scan(ctx);
        steps.add(
          TestStep(
            label: 'Parse',
            ok: true,
            detail:
                'read ${report.events.length} usage record(s) from ${report.filesSeen} file(s)',
          ),
        );
      } catch (e) {
        steps.add(TestStep(label: 'Parse', ok: false, detail: e.toString()));
      }
    }

    try {
      if (testDirObj.existsSync()) testDirObj.deleteSync(recursive: true);
    } catch (_) {}
    store.clearScanState(inst.agent, instance: '${inst.name}__test');
    store.deleteSource(inst.agent, instance: '${inst.name}__test');

    return TestReport(ok: steps.every((s) => s.ok), steps: steps);
  } finally {
    client.close();
  }
}
