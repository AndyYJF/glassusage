import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../database/app_database.dart';
import 'collector_base.dart';

const String kCursorDashboardEventsUrl =
    'https://cursor.com/api/dashboard/get-filtered-usage-events';
const String kCursorTeamEventsUrl =
    'https://api.cursor.com/teams/filtered-usage-events';
const String kCursorUsageSummaryUrl = 'https://cursor.com/api/usage-summary';
const String _kUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) GlassUsage/0.1';
const String _kOrigin = 'https://cursor.com';

class CursorCollector extends Collector {
  static final List<UsageEvent> _pending = [];
  static String? _lastError;

  static void stashEvents(List<UsageEvent> events) {
    _pending.addAll(events);
  }

  static void setError(String? msg) {
    _lastError = msg;
  }

  static String? takeError() => _lastError;

  @override
  String get id => SourceIds.cursor;

  @override
  String get label => 'Cursor';

  @override
  bool get isRealtime => false;

  static String? stateDb(AppSettings settings) {
    final custom = settings.customPath(SourceIds.cursor);
    if (custom != null) return custom;
    final cfg = configDir();
    if (cfg == null) return null;
    final db = p.join(cfg, 'Cursor', 'User', 'globalStorage', 'state.vscdb');
    return File(db).existsSync() ? db : null;
  }

  static String? accessToken(AppSettings settings) {
    final dbPath = stateDb(settings);
    if (dbPath == null) return null;
    try {
      final conn = openSqliteReadOnly(dbPath);
      try {
        if (!tableExists(conn, 'ItemTable')) return null;
        final rows = conn.select(
          "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'",
        );
        if (rows.isEmpty) return null;
        final raw = (rows.first['value'] as String?)?.trim() ?? '';
        final cleaned = raw.replaceAll('"', '').trim();
        return cleaned.isEmpty ? null : cleaned;
      } finally {
        conn.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  @override
  List<String> detect(AppSettings settings) {
    final db = stateDb(settings);
    return db != null ? [db] : const [];
  }

  @override
  List<String> watchPaths(AppSettings settings) => const [];

  @override
  ScanReport scan(ScanCtx ctx) {
    final pending = List<UsageEvent>.from(_pending);
    _pending.clear();
    final detected = detect(ctx.settings);
    return ScanReport(
      filesSeen: detected.length,
      detectedPaths: detected,
      events: finalizeEvents(pending, ctx.pricing),
    );
  }

  static String normalizeCredential(String raw) {
    var s = raw.trim();
    if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) {
      s = s.substring(1, s.length - 1).trim();
    }
    if (s.startsWith("'") && s.endsWith("'") && s.length >= 2) {
      s = s.substring(1, s.length - 1).trim();
    }
    final lower = s.toLowerCase();
    for (final prefix in [
      'cookie: workoscursorsessiontoken=',
      'workoscursorsessiontoken=',
    ]) {
      if (lower.startsWith(prefix)) {
        s = s.substring(prefix.length).trim();
        break;
      }
    }
    return s;
  }

  static bool looksLikeApiKey(String s) {
    final t = s.trim();
    return t.startsWith('key_') || t.startsWith('crsr_');
  }

  static Future<List<UsageEvent>> fetchUsageEvents({
    String? token,
    String? pasted,
    required int startMs,
    required int endMs,
    String instance = kLocalInstance,
  }) async {
    final normPasted = pasted != null ? normalizeCredential(pasted) : null;
    final cleanPasted =
        (normPasted != null && normPasted.isNotEmpty) ? normPasted : null;
    final cleanToken =
        (token != null && token.trim().isNotEmpty) ? token.trim() : null;

    if (cleanToken == null && cleanPasted == null) {
      throw StateError('no Cursor credential configured');
    }

    final errors = <String>[];

    if (cleanPasted != null && looksLikeApiKey(cleanPasted)) {
      try {
        return await _fetchPages(
          url: kCursorTeamEventsUrl,
          authHeader:
              'Basic ${base64Encode(utf8.encode('$cleanPasted:'))}',
          startMs: startMs,
          endMs: endMs,
          numericDates: true,
          instance: instance,
        );
      } catch (e) {
        errors.add('team API: $e');
      }
    }

    if (cleanPasted != null && !looksLikeApiKey(cleanPasted)) {
      try {
        return await _fetchPages(
          url: kCursorDashboardEventsUrl,
          cookieHeader: 'WorkosCursorSessionToken=$cleanPasted',
          startMs: startMs,
          endMs: endMs,
          numericDates: false,
          instance: instance,
        );
      } catch (e) {
        errors.add('dashboard cookie: $e');
      }
    }

    if (cleanToken != null) {
      try {
        return await _fetchPages(
          url: kCursorDashboardEventsUrl,
          authHeader: 'Bearer $cleanToken',
          startMs: startMs,
          endMs: endMs,
          numericDates: false,
          instance: instance,
        );
      } catch (e) {
        errors.add('dashboard bearer: $e');
      }
    }

    throw HttpException(errors.join(' · '));
  }

  static Future<List<UsageEvent>> _fetchPages({
    required String url,
    String? authHeader,
    String? cookieHeader,
    required int startMs,
    required int endMs,
    required bool numericDates,
    required String instance,
  }) async {
    final all = <UsageEvent>[];
    var page = 1;
    while (true) {
      final body = jsonEncode({
        'startDate': numericDates ? startMs : startMs.toString(),
        'endDate': numericDates ? endMs : endMs.toString(),
        'page': page,
        'pageSize': 200,
      });

      final headers = <String, String>{
        'User-Agent': _kUserAgent,
        'Origin': _kOrigin,
        'Referer': 'https://cursor.com/dashboard',
        'Content-Type': 'application/json',
        if (authHeader != null) 'Authorization': authHeader,
        if (cookieHeader != null) 'Cookie': cookieHeader,
      };

      final resp = await http
          .post(Uri.parse(url), headers: headers, body: body)
          .timeout(const Duration(seconds: 45));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final snippet = resp.body.length > 160
            ? resp.body.substring(0, 160)
            : resp.body;
        throw HttpException('HTTP ${resp.statusCode}: $snippet');
      }

      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) {
        throw const FormatException('unexpected Cursor API response');
      }
      final rawList = (decoded['usageEvents'] ??
              decoded['usage_events'] ??
              decoded['usageEventsDisplay'] ??
              const []) as List;
      final totalCount = (decoded['totalUsageEventsCount'] as num?)?.toInt();

      for (final raw in rawList) {
        if (raw is Map) {
          final ev = _toEvent(Map<String, dynamic>.from(raw), instance);
          if (ev != null) {
            all.add(ev);
          }
        }
      }

      if (rawList.length < 200 || page >= 50) break;
      if (totalCount != null && all.length >= totalCount) break;
      page += 1;
    }
    return all;
  }

  static UsageEvent? _toEvent(Map<String, dynamic> raw, String instance) {
    final usage = raw['tokenUsage'] is Map
        ? Map<String, dynamic>.from(raw['tokenUsage'] as Map)
        : null;

    int numFrom(Map<String, dynamic>? m, String k) =>
        (m?[k] as num?)?.toInt() ?? 0;

    final input =
        usage != null ? numFrom(usage, 'inputTokens') : numFrom(raw, 'inputTokens');
    final output =
        usage != null ? numFrom(usage, 'outputTokens') : numFrom(raw, 'outputTokens');
    final cacheRead = usage != null
        ? numFrom(usage, 'cacheReadTokens')
        : numFrom(raw, 'cacheReadTokens');
    final cacheWrite = usage != null
        ? numFrom(usage, 'cacheWriteTokens')
        : numFrom(raw, 'cacheWriteTokens');

    if (input + output + cacheRead + cacheWrite == 0) return null;

    final ts = parseTimestamp(raw['timestamp']) ?? nowMs();
    final model = (raw['model'] as String?) ??
        (raw['modelIntent'] as String?) ??
        'unknown';
    final requestId = raw['requestId'] as String?;
    final owningUser = raw['owningUser'] as String? ?? '';

    final dedupKey = (requestId != null && requestId.isNotEmpty)
        ? requestId
        : shaKey([
            ts.toString(),
            model,
            input.toString(),
            output.toString(),
            cacheRead.toString(),
            cacheWrite.toString(),
            owningUser,
          ]);

    final chargedCents = (raw['chargedCents'] as num?)?.toDouble() ??
        (usage?['totalCents'] as num?)?.toDouble() ??
        (raw['costCents'] as num?)?.toDouble();

    return UsageEvent(
      source: SourceIds.cursor,
      surface: SurfaceIds.ide,
      instance: instance,
      dedupKey: dedupKey,
      sessionId: (raw['kind'] as String?) ?? '',
      model: model,
      provider: 'cursor',
      timestamp: ts,
      inputTokens: input,
      outputTokens: output,
      cacheReadTokens: cacheRead,
      cacheWriteTokens: cacheWrite,
      costUsd: chargedCents != null ? chargedCents / 100.0 : null,
    );
  }
}
