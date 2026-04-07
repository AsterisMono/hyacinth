// Widget test for the fallback MainActivityPage. We mount it with an
// injected HealthReport so the page renders deterministically without
// triggering its async refresh, and we subclass AppState to record
// `retryConnect` calls.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:async';

import 'package:hyacinth/app_state.dart';
import 'package:hyacinth/config/config_model.dart';
import 'package:hyacinth/config/config_store.dart';
import 'package:hyacinth/fallback/health_check.dart';
import 'package:hyacinth/fallback/main_activity_page.dart';
import 'package:hyacinth/net/config_client.dart';
import 'package:hyacinth/net/ws_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hyacinth/permissions/perm_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingAppState extends AppState {
  _RecordingAppState()
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
          fallbackRetryInterval: const Duration(hours: 1),
        );

  int retryCalls = 0;
  int returnCalls = 0;

  @override
  Future<void> retryConnect() async {
    retryCalls++;
  }

  @override
  Future<void> returnToDisplaying() async {
    returnCalls++;
  }
}

/// AppState subclass that lands in displaying with a known config, then
/// flips to fallback via [requestMainActivity] so the page can render
/// the M4.7 "Return to content" button. Uses the real state machine so
/// `config` is populated by the actual flow rather than reflectively.
class _CachedConfigAppState extends AppState {
  _CachedConfigAppState()
      : super(
          store: ConfigStore(),
          client: _CannedConfigClient(),
          healthCheck: HealthCheck(
            store: ConfigStore(),
            perms: const _AlwaysGrantedPerms(),
            httpClient:
                MockClient((_) async => http.Response('{"ok":true}', 200)),
          ),
          wsClientFactory: (baseUrl, onConfigUpdate) => WsClient(
            baseUrl: baseUrl,
            channelFactory: (_) => _NeverChannel(),
            onConfigUpdate: onConfigUpdate,
          ),
          fallbackRetryInterval: const Duration(hours: 1),
        );

  int returnCalls = 0;

  @override
  Future<void> returnToDisplaying() async {
    returnCalls++;
  }
}

class _CannedConfigClient extends ConfigClient {
  _CannedConfigClient()
      : super(httpClient: MockClient((_) async => http.Response('{}', 200)));

  @override
  Future<HyacinthConfig> fetch(String serverBaseUrl) async {
    return const HyacinthConfig(
      content: 'https://example.com',
      contentRevision: 'r1',
      brightness: 'auto',
      screenTimeout: 'always-on',
    );
  }
}

class _NeverChannel implements WsConnection {
  _NeverChannel() : _controller = StreamController<dynamic>();
  final StreamController<dynamic> _controller;
  @override
  Stream<dynamic> get stream => _controller.stream;
  @override
  void send(String data) {}
  @override
  void close() {
    _controller.close();
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

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'hyacinth.serverUrl': 'http://server:8080',
      'hyacinth.onboardingComplete': true,
    });
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
      CheckResult(
        name: 'Home launcher role',
        status: CheckStatus.unknown,
        message: 'Cannot be checked.',
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

    // All three rows render with their messages.
    expect(find.text('Server URL set'), findsOneWidget);
    expect(find.text('http://server:8080'), findsWidgets);
    expect(find.text('Server reachable'), findsOneWidget);
    expect(find.text('GET /health -> HTTP 500'), findsOneWidget);
    expect(find.text('Home launcher role'), findsOneWidget);
    expect(find.text('Cannot be checked.'), findsOneWidget);

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

  group('M4.7 Return to content button', () {
    const minimalReport = HealthReport(<CheckResult>[
      CheckResult(
        name: 'Server URL set',
        status: CheckStatus.ok,
        message: 'http://server:8080',
      ),
    ]);

    testWidgets('shows button when a config is cached', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final state = _CachedConfigAppState();
      await state.start();
      expect(state.phase, AppPhase.displaying);
      expect(state.config, isNotNull);
      state.requestMainActivity();
      expect(state.phase, AppPhase.fallback);
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

      final state = _CachedConfigAppState();
      await state.start();
      state.requestMainActivity();

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
