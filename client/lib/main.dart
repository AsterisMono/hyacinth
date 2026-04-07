import 'package:flutter/material.dart';

import 'app_state.dart';
import 'display/display_page.dart';
import 'fallback/main_activity_page.dart';
import 'onboarding/onboarding_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HyacinthApp());
}

class HyacinthApp extends StatefulWidget {
  const HyacinthApp({super.key});

  @override
  State<HyacinthApp> createState() => _HyacinthAppState();
}

class _HyacinthAppState extends State<HyacinthApp> {
  late final AppState _appState;

  @override
  void initState() {
    super.initState();
    _appState = AppState();
    // Kick off the boot sequence after the first frame so that
    // `notifyListeners` during `start()` can safely rebuild the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _appState.start();
    });
  }

  @override
  void dispose() {
    _appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hyacinth',
      debugShowCheckedModeBanner: false,
      home: ListenableBuilder(
        listenable: _appState,
        builder: (context, _) {
          switch (_appState.phase) {
            case AppPhase.booting:
              return const Scaffold(
                backgroundColor: Colors.black,
                body: Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              );
            case AppPhase.onboarding:
              return OnboardingPage(appState: _appState);
            case AppPhase.connecting:
            case AppPhase.fallback:
              return MainActivityPage(appState: _appState);
            case AppPhase.displaying:
              return DisplayPage(config: _appState.config!);
          }
        },
      ),
    );
  }
}
