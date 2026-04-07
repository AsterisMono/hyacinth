import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'display/display_page.dart';
import 'fallback/main_activity_page.dart';
import 'onboarding/onboarding_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HyacinthApp());
}

/// Hyacinth's brand seed colour. Used as the fallback when Material You
/// dynamic colours are unavailable (pre-API 31, emulator, etc.). Roughly
/// `Colors.deepPurple[400]`.
const Color _hyacinthSeed = Color(0xFF7E57C2);

class HyacinthApp extends StatefulWidget {
  const HyacinthApp({super.key});

  @override
  State<HyacinthApp> createState() => _HyacinthAppState();
}

class _HyacinthAppState extends State<HyacinthApp> with WidgetsBindingObserver {
  late final AppState _appState;

  @override
  void initState() {
    super.initState();
    _appState = AppState();
    WidgetsBinding.instance.addObserver(this);
    // Kick off the boot sequence after the first frame so that
    // `notifyListeners` during `start()` can safely rebuild the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _appState.start();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _appState.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Closes the M2 deferral: when the user comes back from the system
      // settings screen (e.g. after toggling notifications), re-run health
      // checks so a regression flips us into fallback immediately.
      _appState.recheckPermissions();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        final ColorScheme lightScheme = lightDynamic ??
            ColorScheme.fromSeed(
              seedColor: _hyacinthSeed,
              brightness: Brightness.light,
            );
        final ColorScheme darkScheme = darkDynamic ??
            ColorScheme.fromSeed(
              seedColor: _hyacinthSeed,
              brightness: Brightness.dark,
            );
        return MaterialApp(
          title: 'Hyacinth',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.system,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: lightScheme,
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: darkScheme,
          ),
          home: ListenableBuilder(
            listenable: _appState,
            builder: (context, _) {
              switch (_appState.phase) {
                case AppPhase.booting:
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                case AppPhase.onboarding:
                  return OnboardingPage(appState: _appState);
                case AppPhase.connecting:
                case AppPhase.fallback:
                  return MainActivityPage(appState: _appState);
                case AppPhase.displaying:
                  return DisplayPage(
                    config: _appState.config!,
                    packCache: _appState.packCache,
                  );
              }
            },
          ),
        );
      },
    );
  }
}
