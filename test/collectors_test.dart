import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glassusage/data/collectors/collector_base.dart';
import 'package:glassusage/data/collectors/dsh_collector.dart';
import 'package:glassusage/data/collectors/kimi_collector.dart';
import 'package:glassusage/data/collectors/zstd_decoder.dart';
import 'package:glassusage/data/remote/remote_sync.dart';
import 'package:glassusage/data/remote/ssh_client.dart';
import 'package:glassusage/domain/models/usage_models.dart';

Uint8List _hexBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < hex.length; i += 2) {
    out[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
  }
  return out;
}

List<UsageEvent> _replayDsh(List<String> lines, {DshFileMeta? meta}) {
  final m = meta ??
      DshFileMeta(
        sessionId: 'session-abc',
        project: 'dsh',
      );
  final fold = DshUsageFold();
  final events = <UsageEvent>[];
  for (final line in lines) {
    final json = jsonDecode(line) as Map<String, dynamic>;
    applyDshEntry(json, 'local', m, 'session-abc', fold, events);
  }
  return events;
}

void main() {
  group('DshCollector & ZstdDecoder', () {
    test('decodes_concatenated_zstd_frames', () {
      final bytes = _hexBytes(
        '28b52ffd20329101007b2274797065223a2273657373696f6e222c226964223a227331222c22637764223a22433a5c70726f6a5c64656d6f227d0a28b52ffd206595020052c51117a0b539e4034482a7dd6fff0712fb5f61da6849801a3246426b8dd8957c05fa4803c9d8a59031c36586cecdc3470829683d667d052dd0fbac80fcf50c8b726ffe345ad560cd020200685ad3732928',
      );
      final (consumed, frames) = decodeCompleteZstdFrames(bytes);
      expect(consumed, bytes.length);
      expect(frames.length, 2);
      expect(frames[0], contains('"type":"session"'));
      expect(frames[1], contains('"type":"assistant/message"'));
    });

    test('assistant_event_uses_session_and_seq', () {
      final e = _replayDsh([
        r'{"type":"assistant/message","seq":159,"time":1786626078104,"data":{"turn":1,"step":1,"message":{"source":{"kind":"model","provider":"deepseek-official","model":"deepseek-v4-flash"}},"usage":{"inputTokens":10,"outputTokens":4,"cacheReadTokens":2,"reasoningTokens":1}}}',
      ]).single;
      expect(e.dedupKey, 'session-abc:s:159');
      expect(e.model, 'deepseek-v4-flash');
      expect(e.provider, 'deepseek-official');
      expect(e.inputTokens, 10);
      expect(e.outputTokens, 4);
      expect(e.reasoningTokens, 1);
      expect(e.cacheReadTokens, 2);
      expect(e.project, 'dsh');
    });

    test('keeps_only_the_highest_session_generation', () {
      final paths = [
        'root/sess/session.jsonl.zstd',
        'root/sess/session.v3.jsonl.zstd',
        'root/sess/session.v1.jsonl.zstd',
        'root/other/session.jsonl',
        'root/other/session.jsonl.zstd',
      ];
      final chosen = chooseLatestDshLogs(paths);
      expect(chosen.length, 2);
      expect(chosen.any((p) => p.endsWith('session.v3.jsonl.zstd')), isTrue);
      expect(chosen.any((p) => p.endsWith('session.jsonl.zstd')), isTrue);
    });

    test('same_turn_replaces_and_retry_adds', () {
      final replaced = _replayDsh([
        r'{"type":"assistant/attempt","seq":10,"time":1,"data":{"turn":1,"step":1,"stream":[{"type":"chunk","chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":10,"cacheReadTokens":1000}}}]}}',
        r'{"type":"assistant/message","seq":11,"time":2,"data":{"turn":1,"step":1,"usage":{"inputTokens":120,"outputTokens":12,"cacheReadTokens":4000}}}',
      ]);
      expect(replaced.length, 2);
      expect(replaced[0].dedupKey, replaced[1].dedupKey);
      expect(replaced[1].inputTokens, 120);
      expect(replaced[1].cacheReadTokens, 4000);

      final retried = _replayDsh([
        r'{"type":"assistant/attempt","seq":10,"time":1,"data":{"turn":1,"step":1,"stream":[{"type":"chunk","chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":10}}}]}}',
        r'{"type":"llm/retry-started","seq":11,"data":{"turn":1,"step":1}}',
        r'{"type":"assistant/message","seq":12,"time":2,"data":{"turn":1,"step":1,"usage":{"inputTokens":80,"outputTokens":8}}}',
      ]);
      expect(retried.length, 2);
      expect(retried[0].dedupKey, isNot(equals(retried[1].dedupKey)));
    });
  });

  group('KimiCollector', () {
    test('extracts_status_Update_token_usage', () {
      const line =
          r'{"timestamp": 1776152940.197254, "model": "kimi-code/k3", "message": {"type": "StatusUpdate", "payload": {"token_usage": {"input_other": 2124, "output": 144, "input_cache_read": 7424, "input_cache_creation": 50}}}}';
      final (events, skipped) = KimiCollector.parseKimiLines(
        const JsonlChunk(
          lines: [(42, line)],
          newOffset: 100,
          newLineNo: 42,
          mtimeMs: 0,
        ),
        const WireLocation(sessionId: 'session-123', agent: 'main'),
        'demo',
        'local',
      );
      expect(skipped, 0);
      final event = events.single;
      expect(event.inputTokens, 2124);
      expect(event.outputTokens, 144);
      expect(event.cacheReadTokens, 7424);
      expect(event.cacheWriteTokens, 50);
      expect(event.model, 'kimi-code/k3');
      expect(event.project, 'demo');
    });
  });

  group('Remote validation & shell quoting', () {
    test('rejects_unsafe_instance_names_and_paths', () {
      for (final bad in [
        '../outside',
        r'..\outside',
        '.',
        'CON',
        '/absolute',
        'local',
        'LOCAL',
        'name.',
      ]) {
        final input = RemoteInstanceInput(
          name: bad,
          agent: 'openclaw',
          host: '10.0.0.5',
          port: 22,
          username: 'ubuntu',
          authMode: 'password',
        );
        expect(() => input.validate(), throwsArgumentError);
      }

      expect(
        safeSnapshotPath(r'C:\data\remote\safe', 'agents/a/session.jsonl'),
        isNotEmpty,
      );
      for (final rel in [
        '../outside.db',
        r'..\outside.db',
        r'agents\a\..\outside.db',
        r'C:\outside.db',
        '/outside.db',
      ]) {
        expect(
          () => safeSnapshotPath(r'C:\data\remote\safe', rel),
          throwsArgumentError,
        );
      }
      expect(
        shellQuote("/tmp/it's.db"),
        r"'/tmp/it'\''s.db'",
      );
    });
  });
}
