import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../resource_pack/pack_cache.dart';
import '../resource_pack/scheme_handler.dart';

/// Optional override for the inner widget tree. Tests inject a stub builder
/// that returns a plain `Container` so the WebView's reload guard can be
/// driven without bringing up the platform view layer (which doesn't work
/// in `flutter test` headless mode).
typedef WebViewBuilder = Widget Function(BuildContext context, String url);

/// Process-wide override. Set in tests via [debugSetWebViewBuilder]; null
/// in production. We use a top-level field rather than a constructor
/// parameter so the *existing* `HyacinthWebView(url: …)` call sites in
/// `display_page.dart` don't need a separate test/prod variant.
WebViewBuilder? _debugWebViewBuilder;

/// Test-only seam. Pass `null` to restore the real InAppWebView path.
@visibleForTesting
void debugSetWebViewBuilder(WebViewBuilder? builder) {
  _debugWebViewBuilder = builder;
}

/// Thin wrapper around [InAppWebView] configured for Hyacinth's display use
/// case: fullscreen, no zoom controls, JavaScript enabled, media autoplay
/// without a user gesture.
///
/// **M5**: declares `app-scheme` as a custom resource scheme and routes
/// requests through [resolveAppScheme] so URLs of the form
/// `app-scheme://pack/<id>/<file>` resolve out of the local [PackCache]
/// without ever touching the network.
class HyacinthWebView extends StatelessWidget {
  const HyacinthWebView({
    super.key,
    required this.url,
    this.packCache,
  });

  final String url;

  /// Optional pack cache used by the `app-scheme://` resolver. Production
  /// passes the singleton from [DisplayPage]; tests can pass a temp-dir
  /// backed cache or omit it entirely (the resolver simply returns null
  /// for every request and the WebView falls through to its default).
  final PackCache? packCache;

  @override
  Widget build(BuildContext context) {
    final override = _debugWebViewBuilder;
    if (override != null) {
      return override(context, url);
    }
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        transparentBackground: true,
        mediaPlaybackRequiresUserGesture: false,
        useHybridComposition: true,
        supportZoom: false,
        displayZoomControls: false,
        builtInZoomControls: false,
        javaScriptEnabled: true,
        domStorageEnabled: true,
        resourceCustomSchemes: const ['app-scheme'],
      ),
      onLoadResourceWithCustomScheme: (controller, request) async {
        final cache = packCache;
        if (cache == null) return null;
        return resolveAppScheme(request, cache);
      },
    );
  }
}
