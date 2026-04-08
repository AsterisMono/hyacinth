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
import 'package:hyacinth/system/root_helper.dart';
import 'package:hyacinth/system/screen_power.dart';
import 'package:hyacinth/system/secure_settings.dart';
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

class _GreenSecureSettings extends SecureSettings {
  _GreenSecureSettings() : super();
  @override
  Future<bool> hasPermission() async => true;
}

class _FakeScreenPower implements ScreenPower {
  _FakeScreenPower({this.adminAfterRequest = true});
  bool adminAfterRequest;
  int requestAdminCalls = 0;
  bool _activated = false;
  @override
  Future<bool> isInteractive() async => true;
  @override
  Future<bool> isAdminActive() async => _activated;
  @override
  Future<void> requestAdmin() async {
    requestAdminCalls++;
    _activated = adminAfterRequest;
  }

  @override
  Future<String> apply(bool screenOn) async => 'admin';
}

class _FakeRootHelper extends RootHelper {
  _FakeRootHelper({
    this.summary = const RootGrantSummary(
      rootAvailable: false,
      writeSecureSettings: false,
      postNotifications: false,
      batteryOpt: false,
    ),
  }) : super();
  RootGrantSummary summary;
  int autoGrantCalls = 0;
  @override
  Future<bool> hasRoot() async => summary.rootAvailable;
  @override
  Future<RootGrantSummary> autoGrantAll() async {
    autoGrantCalls++;
    return summary;
  }
}

HealthCheck _greenHealthCheck() => HealthCheck(
      store: ConfigStore(),
      perms: _FakePerms(),
      httpClient:
          MockClient((req) async => http.Response('{"ok":true}', 200)),
      secureSettings: _GreenSecureSettings(),
      rootHelper: _FakeRootHelper(),
      screenPower: _FakeScreenPower(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders the explain step first', (tester) async {
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(appState: state, root: _FakeRootHelper()),
      ),
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
          root: _FakeRootHelper(),
          screenPower: _FakeScreenPower(),
        ),
      ),
    );
    await tester.pump();

    // Step 1: Welcome → tap Continue
    expect(find.textContaining('Always-on display'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // Step 2: root → Skip
    expect(find.text('Root access (optional)'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    // Step 2.5: device admin → Skip (M9).
    expect(find.text('Device admin (for screen-off)'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    // Step 3: notifications
    expect(find.text('Notifications permission'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    // Step 4: battery
    expect(find.text('Battery optimization exemption'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    // Step 5: server URL
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
          root: _FakeRootHelper(),
          screenPower: _FakeScreenPower(),
        ),
      ),
    );
    await tester.pump();
    // Advance through Welcome → Root → Device admin → Notifications.
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip')); // root
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip')); // device admin
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
        home: OnboardingPage(
          appState: state,
          perms: _FakePerms(),
          root: _FakeRootHelper(),
          screenPower: _FakeScreenPower(),
        ),
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
          root: _FakeRootHelper(),
          screenPower: _FakeScreenPower(),
        ),
      ),
    );
    await tester.pump();
    // Skip to last step (Welcome → Root → Device admin → Notifications →
    // Battery → URL).
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip')); // root
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip')); // device admin
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip')); // notifications
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip')); // battery
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'not-a-url');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('http://'), findsWidgets);
    // Store should NOT have been written.
    expect(await store.loadServerUrl(), isNull);
    state.dispose();
  });

  // ── M8.1: root-based self-grant flow ────────────────────────────────────

  testWidgets('rooted path: all grants land → wizard skips notifs + battery',
      (tester) async {
    final perms = _FakePerms();
    final store = ConfigStore();
    final state = AppState();
    final root = _FakeRootHelper(
      summary: const RootGrantSummary(
        rootAvailable: true,
        writeSecureSettings: true,
        postNotifications: true,
        batteryOpt: true,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(
          appState: state,
          perms: perms,
          store: store,
          root: root,
          screenPower: _FakeScreenPower(),
        ),
      ),
    );
    await tester.pump();

    // Welcome → Continue
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // Root step: tap "Check for root and grant".
    expect(find.text('Root access (optional)'), findsOneWidget);
    await tester.tap(find.text('Check for root and grant'));
    await tester.pumpAndSettle();
    expect(root.autoGrantCalls, 1);
    // Three M8.1 grants should each render a "Granted" status label.
    expect(find.text('Granted'), findsNWidgets(4));
    // Persisted to ConfigStore.
    expect(await store.getRootChecked(), isTrue);
    expect(await store.getRootAvailable(), isTrue);

    // Continue from root step.
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // Should jump straight to Server URL — device admin / notifications /
    // battery all skipped because root landed everything.
    expect(find.text('Device admin (for screen-off)'), findsNothing);
    expect(find.text('Notifications permission'), findsNothing);
    expect(find.text('Battery optimization exemption'), findsNothing);
    expect(find.text('Server URL'), findsWidgets);
    // Caption about adb pm grant should be hidden when WSS landed via root.
    expect(find.textContaining('via adb'), findsNothing);

    state.dispose();
  });

  testWidgets('rooted partial: battery skipped, notifications still shown',
      (tester) async {
    final state = AppState();
    final root = _FakeRootHelper(
      summary: const RootGrantSummary(
        rootAvailable: true,
        writeSecureSettings: true,
        postNotifications: false,
        batteryOpt: true,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(
          appState: state,
          perms: _FakePerms(),
          store: ConfigStore(),
          root: root,
          screenPower: _FakeScreenPower(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for root and grant'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // Device admin step also skipped because root landed.
    expect(find.text('Device admin (for screen-off)'), findsNothing);
    // Notifications must still be shown.
    expect(find.text('Notifications permission'), findsOneWidget);
    // But battery was granted via root → step is gone from the wizard.
    // Drive past notifications and confirm we land on Server URL, not battery.
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Battery optimization exemption'), findsNothing);
    expect(find.text('Server URL'), findsWidgets);

    state.dispose();
  });

  testWidgets('non-rooted path: probe runs, wizard advances to device admin',
      (tester) async {
    final state = AppState();
    final root = _FakeRootHelper(); // default summary: all false
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(
          appState: state,
          perms: _FakePerms(),
          store: ConfigStore(),
          root: root,
          screenPower: _FakeScreenPower(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for root and grant'));
    await tester.pumpAndSettle();
    expect(root.autoGrantCalls, 1);
    // The summary list rendered the "Not available" hint.
    expect(find.textContaining('Root not detected'), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    // Device admin step is now the next visible page (M9).
    expect(find.text('Device admin (for screen-off)'), findsOneWidget);
    state.dispose();
  });

  testWidgets('skip-root path: helper is never invoked', (tester) async {
    final state = AppState();
    final root = _FakeRootHelper();
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(
          appState: state,
          perms: _FakePerms(),
          store: ConfigStore(),
          root: root,
          screenPower: _FakeScreenPower(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Root access (optional)'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(root.autoGrantCalls, 0);
    // Lands on device admin step (M9).
    expect(find.text('Device admin (for screen-off)'), findsOneWidget);
    state.dispose();
  });

  // ── M9: device admin step ──────────────────────────────────────────────

  testWidgets('device admin Grant → admin active → advances to notifications',
      (tester) async {
    final state = AppState();
    final sp = _FakeScreenPower(adminAfterRequest: true);
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(
          appState: state,
          perms: _FakePerms(),
          store: ConfigStore(),
          root: _FakeRootHelper(),
          screenPower: sp,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip')); // root
    await tester.pumpAndSettle();

    expect(find.text('Device admin (for screen-off)'), findsOneWidget);
    await tester.tap(find.text('Grant'));
    // Grant uses a 500ms delay; let real time pass.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(sp.requestAdminCalls, 1);
    expect(find.text('Notifications permission'), findsOneWidget);
    state.dispose();
  });

  testWidgets('device admin Grant → not active → error shown, stays on step',
      (tester) async {
    final state = AppState();
    final sp = _FakeScreenPower(adminAfterRequest: false);
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(
          appState: state,
          perms: _FakePerms(),
          store: ConfigStore(),
          root: _FakeRootHelper(),
          screenPower: sp,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip')); // root
    await tester.pumpAndSettle();
    expect(find.text('Device admin (for screen-off)'), findsOneWidget);
    await tester.tap(find.text('Grant'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(sp.requestAdminCalls, 1);
    // Still on device admin step with an error.
    expect(find.text('Device admin (for screen-off)'), findsOneWidget);
    expect(find.textContaining('not activated'), findsOneWidget);
    state.dispose();
  });
}
