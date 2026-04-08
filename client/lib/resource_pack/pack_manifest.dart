/// Immutable client-side mirror of the server's `PackManifest` JSON.
///
/// Wire shape (one entry of `GET /packs`, also the body of `GET
/// /packs/{id}/manifest`):
/// ```json
/// {
///   "id": "neko",
///   "version": 3,
///   "type": "png",
///   "filename": "image.png",
///   "sha256": "abc...",
///   "size": 12345,
///   "createdAt": "2026-04-07T10:15:00Z"
/// }
/// ```
///
/// `type` is one of `png`, `jpg`, `webp`, `gif` (M5), `zip` (M6),
/// or `mp4` (M16). The renderer-selection layer in `DisplayPage` keys off
/// `isVideo` / `isZip` to decide whether to mount `HyacinthVideoPlayer`,
/// `HyacinthWebView` against an index.html, or `HyacinthWebView` against
/// the single image file.
class PackManifest {
  const PackManifest({
    required this.id,
    required this.version,
    required this.type,
    required this.filename,
    required this.sha256,
    required this.size,
    required this.createdAt,
  });

  final String id;
  final int version;
  final String type;
  final String filename;
  final String sha256;
  final int size;
  final String createdAt;

  /// True for zip-archive packs (Vite builds with index.html at the
  /// archive root). Image packs return false.
  bool get isZip => type == 'zip';

  /// True for M16 video packs (mp4 only). Image and zip packs return false.
  /// `DisplayPage` reads this (via `AppState`) to decide whether to mount
  /// the native `HyacinthVideoPlayer` instead of the WebView renderer.
  bool get isVideo => type == 'mp4';

  factory PackManifest.fromJson(Map<String, dynamic> json) {
    return PackManifest(
      id: json['id'] as String? ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      type: json['type'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
      sha256: json['sha256'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      createdAt: json['createdAt'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'version': version,
        'type': type,
        'filename': filename,
        'sha256': sha256,
        'size': size,
        'createdAt': createdAt,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PackManifest &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          version == other.version &&
          type == other.type &&
          filename == other.filename &&
          sha256 == other.sha256 &&
          size == other.size &&
          createdAt == other.createdAt;

  @override
  int get hashCode =>
      Object.hash(id, version, type, filename, sha256, size, createdAt);

  @override
  String toString() =>
      'PackManifest(id: $id, version: $version, type: $type, '
      'filename: $filename, size: $size, sha256: $sha256, createdAt: $createdAt)';
}
