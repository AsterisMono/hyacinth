import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/config_model.dart';
import 'webview_controller.dart';

/// Top-level fullscreen display surface.
///
/// Given a resolved [HyacinthConfig], renders the configured URL in an
/// InAppWebView. Immersive sticky mode is applied at construction and
/// re-applied when the app resumes. A wakelock keeps the screen on while
/// this widget is mounted.
///
/// **Reload guard (M3)**: the inner [HyacinthWebView] is constructed once
/// in [State.initState] and only re-created in [didUpdateWidget] when
/// [shouldReloadWebView] returns true. Brightness/timeout-only config
/// updates therefore rebuild the [DisplayPage] but leave the WebView's
/// element/state untouched, so a playing video does not flicker.
class DisplayPage extends StatefulWidget {
  const DisplayPage({
    super.key,
    required this.config,
  });

  final HyacinthConfig config;

  @override
  State<DisplayPage> createState() => _DisplayPageState();
}

/// Pure predicate that decides whether the WebView must be remounted.
///
/// Per plan.md L73: `contentUrl + contentRevision unchanged → do nothing
/// to WebView`. We treat ANY change in either field as a reload trigger,
/// and brightness/timeout changes alone as no-ops.
bool shouldReloadWebView(HyacinthConfig oldCfg, HyacinthConfig newCfg) {
  return oldCfg.content != newCfg.content ||
      oldCfg.contentRevision != newCfg.contentRevision;
}

class _DisplayPageState extends State<DisplayPage>
    with WidgetsBindingObserver {
  late HyacinthWebView _webView;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enterImmersive();
    WakelockPlus.enable();
    _webView = HyacinthWebView(url: widget.config.content);
  }

  @override
  void didUpdateWidget(covariant DisplayPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The reload guard. We only rebuild the inner WebView widget when
    // content or revision actually changed. Brightness/timeout-only updates
    // hit this branch with `shouldReloadWebView == false`, so the cached
    // _webView is reused — Flutter sees the same widget instance, the
    // element tree is preserved, and the underlying native WebView never
    // sees a `loadUrl`.
    if (shouldReloadWebView(oldWidget.config, widget.config)) {
      _webView = HyacinthWebView(
        // Bump the key so Flutter throws the old element away and the
        // new InAppWebView mounts with the new URL. Without a fresh key
        // identical-type widgets get reused and the URL change is silently
        // dropped.
        key: ValueKey<String>(
          '${widget.config.content}#${widget.config.contentRevision}',
        ),
        url: widget.config.content,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _enterImmersive();
    }
  }

  void _enterImmersive() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(child: _webView),
    );
  }
}
