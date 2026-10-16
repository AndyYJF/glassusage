import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/usage_models.dart';
import 'ssh_host_keys.dart';

const int _kConnectTimeoutSecs = 10;
const Duration _kCommandTimeout = Duration(seconds: 120);
int _snapshotSeq = 0;

/// Single-quote a value for a POSIX remote shell.
String shellQuote(String s) {
  return "'${s.replaceAll("'", r"'\''")}'";
}

class AppSshClient {
  final RemoteInstance instance;
  final String? password;
  final String knownHostsPath;
  SSHClient? _passwordClient;

  AppSshClient({
    required this.instance,
    this.password,
    required this.knownHostsPath,
  });

  bool get usesPassword => instance.authMode == 'password';

  String get _target => '${instance.username}@${instance.host}';

  Future<SSHClient> _getPasswordClient() async {
    if (_passwordClient != null && !_passwordClient!.isClosed) {
      return _passwordClient!;
    }
    final pwd = password;
    if (pwd == null || pwd.isEmpty) {
      throw StateError('SSH password is required for password authentication');
    }
    final socket = await _connectSocket();
    Object? hostKeyError;
    final client = SSHClient(
      socket,
      username: instance.username,
      onVerifyHostKey: (type, fingerprint) {
        try {
          return SshHostKeys(knownHostsPath).verify(
            instance.host,
            instance.port,
            type,
            utf8.decode(fingerprint),
          );
        } catch (error) {
          hostKeyError = error;
          return false;
        }
      },
      onPasswordRequest: () => pwd,
    );
    try {
      await client.authenticated.timeout(
        const Duration(seconds: _kConnectTimeoutSecs),
      );
    } catch (_) {
      client.close();
      if (hostKeyError != null) throw hostKeyError!;
      rethrow;
    }
    _passwordClient = client;
    return client;
  }

  Future<SSHSocket> _connectSocket() async {
    final proxy = instance.proxyUrl?.trim();
    if (proxy == null || proxy.isEmpty) {
      return SSHSocket.connect(
        instance.host,
        instance.port,
        timeout: const Duration(seconds: _kConnectTimeoutSecs),
      );
    }
    final rest = proxy.startsWith('http://') ? proxy.substring(7) : proxy;
    final hostPort = rest.split('/').first;
    final parts = hostPort.split(':');
    if (parts.length != 2) {
      throw StateError('Invalid proxy URL: $proxy');
    }
    final proxyHost = parts[0];
    final proxyPort = int.parse(parts[1]);
    final rawSocket = await Socket.connect(
      proxyHost,
      proxyPort,
      timeout: const Duration(seconds: _kConnectTimeoutSecs),
    );
    final req =
        'CONNECT ${instance.host}:${instance.port} HTTP/1.1\r\n'
        'Host: ${instance.host}:${instance.port}\r\n\r\n';
    rawSocket.add(ascii.encode(req));
    await rawSocket.flush();

    // Wait for HTTP 200 response header
    final completer = Completer<SSHSocket>();
    final headerBuf = <int>[];
    final dataController = StreamController<Uint8List>();
    var tunnelEstablished = false;

    rawSocket.listen(
      (chunk) {
        if (tunnelEstablished) {
          dataController.add(Uint8List.fromList(chunk));
          return;
        }
        headerBuf.addAll(chunk);
        final str = latin1.decode(headerBuf);
        final endIdx = str.indexOf('\r\n\r\n');
        if (endIdx != -1) {
          final statusLine = str.split('\r\n').first;
          if (!statusLine.contains(' 200 ')) {
            rawSocket.destroy();
            if (!completer.isCompleted) {
              completer.completeError(
                StateError('Proxy CONNECT failed: $statusLine'),
              );
            }
            return;
          }
          tunnelEstablished = true;
          final remaining = headerBuf.sublist(endIdx + 4);
          if (remaining.isNotEmpty) {
            dataController.add(Uint8List.fromList(remaining));
          }
          if (!completer.isCompleted) {
            completer.complete(
              _TunnelSshSocket(rawSocket, dataController.stream),
            );
          }
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) {
          completer.completeError(e);
        } else {
          dataController.addError(e);
        }
      },
      onDone: () {
        dataController.close();
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('Proxy closed before CONNECT response'),
          );
        }
      },
    );

    return completer.future.timeout(
      const Duration(seconds: _kConnectTimeoutSecs),
      onTimeout: () {
        rawSocket.destroy();
        throw TimeoutException('SSH proxy CONNECT timed out');
      },
    );
  }

  List<String> _sshArgs() {
    final args = <String>[
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=$_kConnectTimeoutSecs',
      '-o',
      'StrictHostKeyChecking=accept-new',
      '-p',
      instance.port.toString(),
    ];
    if (instance.authMode == 'key') {
      final key = instance.keyPath?.trim();
      if (key != null && key.isNotEmpty) {
        args.addAll(['-i', key, '-o', 'IdentitiesOnly=yes']);
      }
    }
    return args;
  }

  Future<String> exec(String remoteCommand) async {
    if (usesPassword) {
      final client = await _getPasswordClient();
      try {
        final res = await client
            .runWithResult(remoteCommand)
            .timeout(_kCommandTimeout);
        if (res.exitCode != 0) {
          throw StateError(
            'SSH command exited with ${res.exitCode ?? res.exitSignal ?? "no status"}: '
            '${utf8.decode(res.stderr, allowMalformed: true).trim()}',
          );
        }
        return utf8.decode(res.stdout, allowMalformed: true);
      } on TimeoutException {
        // Future.timeout alone does not terminate the underlying SSH command.
        close();
        rethrow;
      }
    }

    final program = _locate('ssh.exe');
    final args = [..._sshArgs(), _target, remoteCommand];
    final res = await Process.run(program, args).timeout(_kCommandTimeout);
    if (res.exitCode != 0) {
      throw StateError(
        'ssh exited with ${res.exitCode}: ${(res.stderr as String).trim()}',
      );
    }
    return res.stdout as String;
  }

  Future<void> download(String remotePath, String localPath) async {
    Directory(p.dirname(localPath)).createSync(recursive: true);
    if (usesPassword) {
      final client = await _getPasswordClient();
      final sftp = await client.sftp();
      final remoteFile = await sftp.open(remotePath);
      try {
        final out = File(localPath).openWrite();
        try {
          await for (final chunk in remoteFile.read()) {
            out.add(chunk);
          }
          await out.flush();
        } finally {
          await out.close();
        }
      } finally {
        await remoteFile.close();
      }
      return;
    }

    final remoteSpec = '$_target:${shellQuote(remotePath)}';
    final args = <String>[
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=$_kConnectTimeoutSecs',
      '-o',
      'StrictHostKeyChecking=accept-new',
      '-P',
      instance.port.toString(),
    ];
    if (instance.authMode == 'key') {
      final key = instance.keyPath?.trim();
      if (key != null && key.isNotEmpty) {
        args.addAll(['-i', key]);
      }
    }
    args.addAll([remoteSpec, localPath]);

    final res = await Process.run(
      _locate('scp.exe'),
      args,
    ).timeout(_kCommandTimeout);
    if (res.exitCode != 0) {
      throw StateError('download failed: ${(res.stderr as String).trim()}');
    }
  }

  Future<(int, int)?> stat(String remotePath) async {
    final out = await exec(
      "stat -c '%Y %s' ${shellQuote(remotePath)} 2>/dev/null || true",
    );
    final line = out.trim();
    if (line.isEmpty) return null;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) return null;
    final mtime = int.tryParse(parts[0]);
    final size = int.tryParse(parts[1]);
    if (mtime == null || size == null) return null;
    return (mtime, size);
  }

  Future<String> remoteHome() async {
    final out = await exec('echo \$HOME');
    var home = out.trim();
    while (home.endsWith('/')) {
      home = home.substring(0, home.length - 1);
    }
    if (home.isEmpty) {
      throw StateError('could not determine remote home directory');
    }
    return home;
  }

  Future<bool> hasSqlite3() async {
    try {
      final out = await exec(
        'command -v sqlite3 >/dev/null 2>&1 && echo yes || echo no',
      );
      return out.trim() == 'yes';
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> listDir(String remotePath) async {
    final out = await exec(
      'ls -1 ${shellQuote(remotePath)} 2>/dev/null || true',
    );
    return const LineSplitter()
        .convert(out)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  Future<void> snapshotSqlite(
    String remoteDb,
    String localDb,
    bool useBackup,
  ) async {
    if (useBackup) {
      final seq = _snapshotSeq++;
      final tmp = '/tmp/glassusage-snap-$pid-$seq.db';
      final cmd =
          "rm -f $tmp && sqlite3 ${shellQuote(remoteDb)} \".backup '$tmp'\"";
      try {
        await exec(cmd);
        try {
          await download(tmp, localDb);
          return;
        } finally {
          try {
            await exec('rm -f $tmp');
          } catch (_) {}
        }
      } catch (_) {
        // Fallback to direct file + sidecar copy
      }
    }

    await download(remoteDb, localDb);
    for (final suffix in const ['-wal', '-shm']) {
      final remoteSide = '$remoteDb$suffix';
      final localSide = p.join(
        p.dirname(localDb),
        '${p.basename(localDb)}$suffix',
      );
      final st = await stat(remoteSide);
      if (st != null) {
        await download(remoteSide, localSide);
      } else {
        final f = File(localSide);
        if (f.existsSync()) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    }
  }

  void close() {
    _passwordClient?.close();
    _passwordClient = null;
  }

  static String _locate(String exe) {
    final sysRoot = Platform.environment['SystemRoot'];
    if (sysRoot != null) {
      final candidate = p.join(sysRoot, 'System32', 'OpenSSH', exe);
      if (File(candidate).existsSync()) return candidate;
    }
    return exe;
  }
}

class _TunnelSshSocket implements SSHSocket {
  final Socket _socket;
  final Stream<Uint8List> _stream;

  _TunnelSshSocket(this._socket, this._stream);

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> flush() => _socket.flush();

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Stream<Uint8List> get stream => _stream;
}
