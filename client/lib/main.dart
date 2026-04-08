import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'config/config_store.dart';
import 'display/display_page.dart';
import 'fallback/main_activity_page.dart';
import 'onboarding/onboarding_page.dart';
import 'system/foreground_service.dart';
import 'system/root_helper.dart';
import 'system/secure_settings.dart';

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
  // M8: best-effort foreground service stub. Failures are swallowed by
  // the wrapper; the app still runs.
  final ForegroundService _foregroundService = ForegroundService();

  @override
  void initState() {
    super.initState();
    _appState = AppState();
    WidgetsBinding.instance.addObserver(this);
    // Kick off the boot sequence after the first frame so that
    // `notifyListeners` during `start()` can safely rebuild the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _appState.start();
      // Fire-and-forget: this is best-effort.
      _foregroundService.start();
      // M8.1 — silent re-grant of WRITE_SECURE_SETTINGS on boot. Only
      // fires if the cache says root was previously available AND the
      // current grant has been dropped (e.g. after an app reinstall).
      // We deliberately do NOT call hasRoot() here — that would trigger
      // a Magisk consent dialog. We just attempt the grant; Magisk
      // remembers prior consent across reinstalls.
      _maybeSilentRegrant();
    });
  }

  Future<void> _maybeSilentRegrant() async {
    try {
      final store = ConfigStore();
      final available = await store.getRootAvailable();
      if (!available) return;
      final secure = SecureSettings();
      if (await secure.hasPermission()) return;
      await RootHelper().grantWriteSecureSettings();
    } catch (_) {
      // Best-effort. HealthCheck row will surface any persistent gap.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Stop the FGS first so its ongoing notification disappears with the
    // process. The wrapper never throws.
    _foregroundService.stop();
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
                    videoFile: _appState.videoFile,
                    onBackRequested: _appState.requestMainActivity,
                    screenPowerError: _appState.screenPowerError,
                  );
              }
            },
          ),
        );
      },
    );
  }
}
