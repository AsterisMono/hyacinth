import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'pack_cache.dart';

/// Resolves an `app-scheme://pack/<id>/<rel/path>` request to a local
/// file under [PackCache]. Returns `null` for any URL that isn't an
/// `app-scheme://pack/...` (so the WebView falls back to its normal
/// loading path), for any pack file that isn't currently cached, or
/// for any unsafe relative path.
///
/// Examples:
///   - `app-scheme://pack/neko/image.png`        → image pack file
///   - `app-scheme://pack/site/index.html`       → zip pack entry point
///   - `app-scheme://pack/site/assets/app.js`    → nested zip pack file
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
  final relPath = segments.skip(1).join('/');
  final file = await cache.currentContentFileByPath(packId, relPath);
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  return CustomSchemeResponse(
    data: bytes,
    contentType: guessAppSchemeMime(relPath),
    contentEncoding: 'utf-8',
  );
}

/// Maps a filename (or relative path) to a Content-Type, defaulting to
/// `application/octet-stream`. Public for tests. The set covers the
/// common files emitted by Vite builds plus a few image/media types.
String guessAppSchemeMime(String name) {
  final lower = name.toLowerCase();
  // Markup / styling / scripting
  if (lower.endsWith('.html') || lower.endsWith('.htm')) return 'text/html';
  if (lower.endsWith('.css')) return 'text/css';
  if (lower.endsWith('.js') || lower.endsWith('.mjs')) {
    return 'application/javascript';
  }
  if (lower.endsWith('.json')) return 'application/json';
  if (lower.endsWith('.txt')) return 'text/plain';
  // Images
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.svg')) return 'image/svg+xml';
  if (lower.endsWith('.ico')) return 'image/x-icon';
  // Fonts
  if (lower.endsWith('.woff2')) return 'font/woff2';
  if (lower.endsWith('.woff')) return 'font/woff';
  if (lower.endsWith('.ttf')) return 'font/ttf';
  if (lower.endsWith('.otf')) return 'font/otf';
  // Media
  if (lower.endsWith('.mp4')) return 'video/mp4';
  if (lower.endsWith('.webm')) return 'video/webm';
  return 'application/octet-stream';
}
