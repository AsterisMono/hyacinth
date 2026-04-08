// Widget test for the fallback MainActivityPage. We mount it with an
// injected HealthReport so the page renders deterministically without
// triggering its async refresh, and we subclass AppState to record
// `retryConnect` / `returnToDisplaying` calls.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hyacinth/app_state.dart';
import 'package:hyacinth/config/config_model.dart';
import 'package:hyacinth/config/config_store.dart';
import 'package:hyacinth/fallback/health_check.dart';
import 'package:hyacinth/fallback/main_activity_page.dart';
import 'package:hyacinth/net/config_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hyacinth/permissions/perm_manager.dart';
import 'package:hyacinth/resource_pack/pack_cache.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Shared temp dir injected into [_RecordingAppState.packCache] so the
/// M8.4 CachedPacksCard never reaches into real `getApplicationSupportDirectory`
/// (which hangs `flutter test`).
late Directory _packTmp;

class _RecordingAppState extends AppState {
  _RecordingAppState({this.cachedConfig})
      : super(
          store: ConfigStore(),
          client: ConfigClient(
            httpClient:
                MockClient((_) async => http.Response('{}', 200)),
          ),
          healthCheck: HealthCheck(
            store: ConfigStore(),
            perms: const _AlwaysGrantedPerms(),
            httpClient:
                MockClient((_) async => http.Response('{"ok":true}', 200)),
          ),
          packCache: PackCache(overrideRoot: _packTmp),
          fallbackRetryInterval: const Duration(hours: 1),
        );

  /// When non-null, [config] returns this directly without driving the
  /// real `_connect()` path (which would touch real platform plugins
  /// in test mode). This is the "cached config" surface the M8.2
  /// "Return to content" button reads.
  final HyacinthConfig? cachedConfig;

  int retryCalls = 0;
  int returnCalls = 0;

  @override
  HyacinthConfig? get config => cachedConfig ?? super.config;

  @override
  Future<void> retryConnect() async {
    retryCalls++;
  }

  @override
  Future<void> returnToDisplaying() async {
    returnCalls++;
  }
}

class _AlwaysGrantedPerms implements PermManager {
  const _AlwaysGrantedPerms();
  @override
  Future<PermissionStatus> notificationStatus() async =>
      PermissionStatus.granted;
  @override
  Future<PermissionStatus> batteryOptimizationStatus() async =>
      PermissionStatus.granted;
  @override
  Future<PermissionStatus> requestNotifications() async =>
      PermissionStatus.granted;
  @override
  Future<PermissionStatus> requestBatteryOptimization() async =>
      PermissionStatus.granted;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'hyacinth.serverUrl': 'http://server:8080',
      'hyacinth.onboardingComplete': true,
    });
    _packTmp =
        await Directory.systemTemp.createTemp('hyacinth_main_act_packtmp_');
  });

  tearDown(() async {
    if (await _packTmp.exists()) {
      await _packTmp.delete(recursive: true);
    }
  });

  testWidgets('renders mixed health rows and Reload button calls retry',
      (tester) async {
    // Use a larger logical size so the entire fallback page (status footer
    // + health card + settings card) fits without scrolling.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = _RecordingAppState();
    const report = HealthReport(<CheckResult>[
      CheckResult(
        name: 'Server URL set',
        status: CheckStatus.ok,
        message: 'http://server:8080',
      ),
      CheckResult(
        name: 'Server reachable',
        status: CheckStatus.fail,
        message: 'GET /health -> HTTP 500',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: MainActivityPage(
          appState: state,
          initialReport: report,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // All rows render with their messages.
    expect(find.text('Server URL set'), findsOneWidget);
    expect(find.text('http://server:8080'), findsWidgets);
    expect(find.text('Server reachable'), findsOneWidget);
    expect(find.text('GET /health -> HTTP 500'), findsOneWidget);

    // M3 sanity: the page should be using Cards.
    expect(find.byType(Card), findsWidgets);

    // Tap "Reload now" in the SettingsBlock.
    final reloadButton = find.widgetWithText(OutlinedButton, 'Reload now');
    expect(reloadButton, findsOneWidget);
    await tester.tap(reloadButton);
    await tester.pumpAndSettle();
    expect(state.retryCalls, 1);

    state.dispose();
  });

  testWidgets('expanded layout puts HealthCheck and Settings side by side',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = _RecordingAppState();
    const report = HealthReport(<CheckResult>[
      CheckResult(
        name: 'Server URL set',
        status: CheckStatus.ok,
        message: 'http://server:8080',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: MainActivityPage(
          appState: state,
          initialReport: report,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // SettingsBlock-specific marker proves both cards rendered.
    expect(find.text('Test connection'), findsOneWidget);
    expect(find.text('Server URL set'), findsOneWidget);

    final healthRect = tester.getRect(find.byKey(const Key('healthCheckCard')));
    final settingsRect = tester.getRect(find.byKey(const Key('settingsCard')));

    // Same row: tops within ~50px.
    expect(
      (healthRect.top - settingsRect.top).abs(),
      lessThan(50),
      reason: 'Health and Settings cards should be on the same row',
    );
    // And they must be horizontally distinct (one to the left of the other).
    expect(
      healthRect.right <= settingsRect.left ||
          settingsRect.right <= healthRect.left,
      isTrue,
      reason: 'Cards should not overlap horizontally',
    );

    state.dispose();
  });

  testWidgets('compact layout stacks HealthCheck above Settings',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = _RecordingAppState();
    const report = HealthReport(<CheckResult>[
      CheckResult(
        name: 'Server URL set',
        status: CheckStatus.ok,
        message: 'http://server:8080',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: MainActivityPage(
          appState: state,
          initialReport: report,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final healthTop =
        tester.getTopLeft(find.byKey(const Key('healthCheckCard'))).dy;
    final settingsTop =
        tester.getTopLeft(find.byKey(const Key('settingsCard'))).dy;

    expect(
      settingsTop,
      greaterThan(healthTop),
      reason: 'Settings card should be below the HealthCheck card on compact',
    );

    state.dispose();
  });

  group('M8.2 Return to content button', () {
    const minimalReport = HealthReport(<CheckResult>[
      CheckResult(
        name: 'Server URL set',
        status: CheckStatus.ok,
        message: 'http://server:8080',
      ),
    ]);

    const cachedCfg = HyacinthConfig(
      content: 'https://example.com',
      contentRevision: 'r1',
      brightness: 'auto',
      screenTimeout: 'always-on',
    );

    testWidgets('shows button when a config is cached', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final state = _RecordingAppState(cachedConfig: cachedCfg);
      expect(state.config, isNotNull);

      await tester.pumpWidget(
        MaterialApp(
          home: MainActivityPage(
            appState: state,
            initialReport: minimalReport,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilledButton, 'Return to content'),
        findsOneWidget,
      );
      state.dispose();
    });

    testWidgets('hides button when no config is cached', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final state = _RecordingAppState();
      expect(state.config, isNull);

      await tester.pumpWidget(
        MaterialApp(
          home: MainActivityPage(
            appState: state,
            initialReport: minimalReport,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilledButton, 'Return to content'),
        findsNothing,
      );
      state.dispose();
    });

    testWidgets('tapping the button calls returnToDisplaying',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final state = _RecordingAppState(cachedConfig: cachedCfg);

      await tester.pumpWidget(
        MaterialApp(
          home: MainActivityPage(
            appState: state,
            initialReport: minimalReport,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.widgetWithText(FilledButton, 'Return to content'),
      );
      await tester.pumpAndSettle();
      expect(state.returnCalls, 1);
      state.dispose();
    });
  });
}
