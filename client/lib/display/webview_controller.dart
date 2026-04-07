import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

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
class HyacinthWebView extends StatelessWidget {
  const HyacinthWebView({super.key, required this.url});

  final String url;

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
      ),
    );
  }
}
