/// Immutable model of the `/config` payload returned by the Hyacinth server.
///
/// In M1 only [content] is consumed (it's the URL the WebView loads).
/// [brightness] and [screenTimeout] are parsed but not enforced — that's M7.
class HyacinthConfig {
  const HyacinthConfig({
    required this.content,
    required this.contentRevision,
    required this.brightness,
    required this.screenTimeout,
  });

  final String content;
  final String contentRevision;
  final String brightness;
  final String screenTimeout;

  factory HyacinthConfig.fromJson(Map<String, dynamic> json) {
    // The server's `brightness` and `screenTimeout` are union types
    // (`"auto"` / int / `"always-on"` / `"30s"`). M3 only needs the values
    // round-tripped for diffing — full enforcement lands in M7 — so we
    // collapse them to their string form here.
    String stringify(Object? v, String fallback) {
      if (v == null) return fallback;
      if (v is String) return v;
      return v.toString();
    }

    return HyacinthConfig(
      content: json['content'] as String? ?? '',
      contentRevision: json['contentRevision'] as String? ?? '',
      brightness: stringify(json['brightness'], 'auto'),
      screenTimeout: stringify(json['screenTimeout'], 'always-on'),
    );
  }

  /// Returns a copy with selectively-overridden fields. Used by the M3
  /// reload-guard tests to construct "same content, different brightness"
  /// configs without retyping all four fields.
  HyacinthConfig copyWith({
    String? content,
    String? contentRevision,
    String? brightness,
    String? screenTimeout,
  }) {
    return HyacinthConfig(
      content: content ?? this.content,
      contentRevision: contentRevision ?? this.contentRevision,
      brightness: brightness ?? this.brightness,
      screenTimeout: screenTimeout ?? this.screenTimeout,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HyacinthConfig &&
          runtimeType == other.runtimeType &&
          content == other.content &&
          contentRevision == other.contentRevision &&
          brightness == other.brightness &&
          screenTimeout == other.screenTimeout;

  @override
  int get hashCode => Object.hash(
        content,
        contentRevision,
        brightness,
        screenTimeout,
      );

  @override
  String toString() =>
      'HyacinthConfig(content: $content, contentRevision: $contentRevision, '
      'brightness: $brightness, screenTimeout: $screenTimeout)';
}
