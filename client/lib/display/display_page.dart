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
/// This widget does NOT load config or handle bootstrap errors; the caller
/// is expected to have a valid [HyacinthConfig] in hand before mounting it.
/// In M1 that caller is `_M1Bootstrap` in `main.dart`; in M2 it will be
/// `AppState` mounting `DisplayPage` only in the `Displaying` state.
class DisplayPage extends StatefulWidget {
  const DisplayPage({
    super.key,
    required this.config,
  });

  final HyacinthConfig config;

  @override
  State<DisplayPage> createState() => _DisplayPageState();
}

class _DisplayPageState extends State<DisplayPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enterImmersive();
    WakelockPlus.enable();
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
      body: SizedBox.expand(
        child: HyacinthWebView(url: widget.config.content),
      ),
    );
  }
}
