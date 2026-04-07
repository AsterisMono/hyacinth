import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Thin wrapper around [InAppWebView] configured for Hyacinth's display use
/// case: fullscreen, no zoom controls, JavaScript enabled, media autoplay
/// without a user gesture.
class HyacinthWebView extends StatelessWidget {
  const HyacinthWebView({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
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
