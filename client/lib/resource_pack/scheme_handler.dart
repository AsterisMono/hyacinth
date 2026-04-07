import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'pack_cache.dart';

/// Resolves an `app-scheme://pack/<id>/<filename>` request to a local
/// file under [PackCache]. Returns `null` for any URL that isn't an
/// `app-scheme://pack/...` (so the WebView falls back to its normal
/// loading path) or for any pack file that isn't currently cached.
///
/// The expected URL shape is:
///   `app-scheme://pack/<id>/<filename>`
/// where `<id>` is the pack id and `<filename>` matches the manifest's
/// `filename` field (e.g. `image.png`). Extra path segments are accepted
/// for forward-compat with M6's zip packs (Vite builds may have
/// `/assets/foo.js`); the manager only resolves the trailing component
/// against the cache for now.
Future<CustomSchemeResponse?> resolveAppScheme(
  WebResourceRequest request,
  PackCache cache,
) async {
  final uri = request.url;
  if (uri.scheme != 'app-scheme') return null;
  if (uri.host != 'pack') return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length < 2) return null;
  final packId = segments.first;
  final filename = segments.last;
  final file = await cache.currentContentFile(packId, filename);
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  return CustomSchemeResponse(
    data: bytes,
    contentType: guessAppSchemeMime(filename),
    contentEncoding: 'utf-8',
  );
}

/// Maps a filename to a Content-Type, defaulting to
/// `application/octet-stream`. Public for tests.
String guessAppSchemeMime(String filename) {
  final lower = filename.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.html') || lower.endsWith('.htm')) return 'text/html';
  if (lower.endsWith('.css')) return 'text/css';
  if (lower.endsWith('.js')) return 'application/javascript';
  if (lower.endsWith('.json')) return 'application/json';
  if (lower.endsWith('.svg')) return 'image/svg+xml';
  return 'application/octet-stream';
}
