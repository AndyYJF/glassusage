enum OutputTimingScope { response, turn }

/// One completed reply/turn, never an instantaneous token-stream measurement.
class OutputSpeedSample {
  const OutputSpeedSample({
    required this.source,
    required this.instance,
    required this.model,
    required this.requestId,
    required this.outputTokens,
    required this.completedAtMs,
    required this.scope,
    this.durationMs,
  });

  final String source;
  final String instance;
  final String model;
  final String requestId;
  final int outputTokens;
  final int completedAtMs;
  final int? durationMs;
  final OutputTimingScope scope;

  double? get tokensPerSecond {
    final duration = durationMs;
    if (duration == null ||
        duration <= 0 ||
        duration > 86400000 ||
        outputTokens <= 0) {
      return null;
    }
    return outputTokens * 1000.0 / duration;
  }

  Map<String, dynamic> toJson() => {
    'source': source,
    'instance': instance,
    'model': model,
    'requestId': requestId,
    'outputTokens': outputTokens,
    'completedAtMs': completedAtMs,
    'durationMs': durationMs,
    'scope': scope.name,
  };

  factory OutputSpeedSample.fromJson(Map<String, dynamic> json) =>
      OutputSpeedSample(
        source: json['source'] as String,
        instance: json['instance'] as String,
        model: json['model'] as String,
        requestId: json['requestId'] as String,
        outputTokens: (json['outputTokens'] as num).toInt(),
        completedAtMs: (json['completedAtMs'] as num).toInt(),
        durationMs: (json['durationMs'] as num?)?.toInt(),
        scope:
            json['scope'] == 'response'
                ? OutputTimingScope.response
                : OutputTimingScope.turn,
      );
}
