// Widget tests for the onboarding wizard. Drive every step end-to-end with
// a fake PermManager (so no platform-channel calls fire).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/app_state.dart';
import 'package:hyacinth/config/config_store.dart';
import 'package:hyacinth/fallback/health_check.dart';
import 'package:hyacinth/net/config_client.dart';
import 'package:hyacinth/onboarding/onboarding_page.dart';
import 'package:hyacinth/permissions/perm_manager.dart';
import 'package:hyacinth/config/config_model.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePerms implements PermManager {
  int notifRequests = 0;
  int batteryRequests = 0;
  @override
  Future<PermissionStatus> notificationStatus() async =>
      PermissionStatus.granted;
  @override
  Future<PermissionStatus> batteryOptimizationStatus() async =>
      PermissionStatus.granted;
  @override
  Future<PermissionStatus> requestNotifications() async {
    notifRequests++;
    return PermissionStatus.granted;
  }

  @override
  Future<PermissionStatus> requestBatteryOptimization() async {
    batteryRequests++;
    return PermissionStatus.granted;
  }
}

class _StubConfigClient extends ConfigClient {
  _StubConfigClient() : super(httpClient: MockClient((_) async {
          return http.Response('{}', 200);
        }));

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

HealthCheck _greenHealthCheck() => HealthCheck(
      store: ConfigStore(),
      perms: _FakePerms(),
      httpClient:
          MockClient((req) async => http.Response('{"ok":true}', 200)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders the explain step first', (tester) async {
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(home: OnboardingPage(appState: state)),
    );
    await tester.pump();

    expect(find.text('Welcome to Hyacinth'), findsOneWidget);
    expect(
      find.textContaining('Always-on display for your Ita-Bag'),
      findsOneWidget,
    );
    expect(find.text('Continue'), findsOneWidget);
    state.dispose();
  });

  testWidgets('walks through every step and saves the URL', (tester) async {
    final perms = _FakePerms();
    final store = ConfigStore();
    final state = AppState(
      store: store,
      client: _StubConfigClient(),
      healthCheck: _greenHealthCheck(),
      fallbackRetryInterval: const Duration(hours: 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(
          appState: state,
          perms: perms,
          store: store,
        ),
      ),
    );
    await tester.pump();

    // Step 1: Welcome → tap Continue
    expect(find.textContaining('Always-on display'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // Step 2: notifications
    expect(find.text('Notifications permission'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    // Step 3: battery
    expect(find.text('Battery optimization exemption'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    // Step 4: server URL
    expect(find.text('Server URL'), findsWidgets);
    await tester.enterText(
      find.byType(TextField),
      'http://127.0.0.1:8080',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(await store.loadServerUrl(), 'http://127.0.0.1:8080');
    expect(await store.isOnboardingComplete(), isTrue);

    state.dispose();
  });

  testWidgets('Grant button on notifications step calls perm manager',
      (tester) async {
    final perms = _FakePerms();
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(
          appState: state,
          perms: perms,
        ),
      ),
    );
    await tester.pump();
    // Advance to notifications step.
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Grant'));
    await tester.pumpAndSettle();
    expect(perms.notifRequests, 1);
    state.dispose();
  });

  testWidgets('wizard content is constrained on wide landscape viewports',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(appState: state, perms: _FakePerms()),
      ),
    );
    await tester.pump();

    // Find the ConstrainedBox inside the active step body. PageView builds
    // all pages, so there will be several; all should be <= 560 + tolerance.
    final constrained = find.byWidgetPredicate(
      (w) =>
          w is ConstrainedBox && w.constraints.maxWidth == 560,
    );
    expect(constrained, findsWidgets);

    // Rendered width must not exceed 560 dp on the wide viewport.
    for (final element in tester.elementList(constrained)) {
      final size = element.size;
      expect(size, isNotNull);
      expect(size!.width, lessThanOrEqualTo(560.0));
    }

    // Baseline: the outer Scaffold is actually 1280 dp wide, confirming the
    // viewport really is landscape-tablet-sized.
    final scaffoldSize = tester.getSize(find.byType(Scaffold));
    expect(scaffoldSize.width, greaterThan(1000));

    state.dispose();
  });

  testWidgets('rejects empty/invalid URL on save', (tester) async {
    final state = AppState();
    final store = ConfigStore();
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(
          appState: state,
          perms: _FakePerms(),
          store: store,
        ),
      ),
    );
    await tester.pump();
    // Skip to last step.
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'not-a-url');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('http://'), findsWidgets);
    // Store should NOT have been written.
    expect(await store.loadServerUrl(), isNull);
    state.dispose();
  });
}
