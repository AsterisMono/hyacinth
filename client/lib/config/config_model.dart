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
    return HyacinthConfig(
      content: json['content'] as String? ?? '',
      contentRevision: json['contentRevision'] as String? ?? '',
      brightness: json['brightness'] as String? ?? 'auto',
      screenTimeout: json['screenTimeout'] as String? ?? 'always-on',
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
