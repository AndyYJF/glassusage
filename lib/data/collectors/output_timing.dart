import '../../domain/models/output_speed.dart';

/// Per-file timing state survives incremental scans. It does not change billing
/// events or assume that a file-write timestamp is a request start timestamp.
class OutputTurnState {
  int? startedAtMs;
  String turnId = '';
  bool valid = true;
  final Map<String, int> outputs = {};
  final Map<String, (String, int)> _messages = {};

  OutputTurnState();

  factory OutputTurnState.fromJson(dynamic raw) {
    final state = OutputTurnState();
    if (raw is! Map) return state;
    state.startedAtMs = (raw['startedAtMs'] as num?)?.toInt();
    state.turnId = raw['turnId'] as String? ?? '';
    state.valid = raw['valid'] != false;
    final outputs = raw['outputs'];
    if (outputs is Map) {
      for (final entry in outputs.entries.take(64)) {
        if (entry.key is String && entry.value is num) {
          state.outputs[entry.key as String] = (entry.value as num).toInt();
        }
      }
    }
    final messages = raw['messages'];
    if (messages is Map) {
      for (final entry in messages.entries.take(512)) {
        final value = entry.value;
        if (entry.key is String &&
            value is List &&
            value.length == 2 &&
            value[0] is String &&
            value[1] is num) {
          state._messages[entry.key as String] = (
            value[0] as String,
            (value[1] as num).toInt(),
          );
        }
      }
    }
    return state;
  }

  Map<String, dynamic> toJson() => {
    'startedAtMs': startedAtMs,
    'turnId': turnId,
    'valid': valid,
    'outputs': outputs,
    'messages': {
      for (final entry in _messages.entries)
        entry.key: [entry.value.$1, entry.value.$2],
    },
  };

  void start(int? timestamp, String id) {
    if (turnId == id && id.isNotEmpty && startedAtMs != null) return;
    clear();
    startedAtMs = timestamp;
    turnId = id;
  }

  void add(String model, int tokens) {
    if (tokens <= 0) return;
    if (outputs.length >= 64 && !outputs.containsKey(model)) {
      valid = false;
      return;
    }
    outputs[model] = (outputs[model] ?? 0) + tokens;
  }

  /// Claude assistant usage is updated cumulatively for the same message ID.
  void message(String id, String model, int tokens) {
    if (id.isEmpty || tokens < 0) return;
    if (_messages.length >= 512 && !_messages.containsKey(id)) {
      valid = false;
      return;
    }
    final previous = _messages[id];
    if (previous != null) {
      outputs[previous.$1] = (outputs[previous.$1] ?? 0) - previous.$2;
    }
    _messages[id] = (model, tokens);
    add(model, tokens);
  }

  List<OutputSpeedSample> finish({
    required String source,
    required String instance,
    required String fileId,
    required int? completedAtMs,
    int? nativeDurationMs,
  }) {
    final end = completedAtMs;
    final started = startedAtMs;
    final duration =
        nativeDurationMs ??
        (end != null && started != null ? end - started : null);
    // A shared whole-turn duration cannot be attributed to individual models
    // if the model changed mid-turn, or a cumulative counter reset mid-turn.
    final measurable =
        valid &&
        started != null &&
        end != null &&
        end > started &&
        outputs.values.where((n) => n > 0).length == 1;
    final result = <OutputSpeedSample>[
      if (end != null)
        for (final entry in outputs.entries)
          if (entry.value > 0)
            OutputSpeedSample(
              source: source,
              instance: instance,
              model: entry.key,
              requestId: '$fileId:$turnId:${started ?? "unknown"}',
              outputTokens: entry.value,
              completedAtMs: end,
              durationMs: measurable ? duration : null,
              scope: OutputTimingScope.turn,
            ),
    ];
    clear();
    return result;
  }

  void clear() {
    startedAtMs = null;
    turnId = '';
    valid = true;
    outputs.clear();
    _messages.clear();
  }
}
