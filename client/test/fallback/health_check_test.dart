// Hermetic tests for the HealthCheck aggregator.
//
// MockClient handles `/health`. PermManager is replaced with a fake the
// test controls so we can flip notification/battery rows green or red.
// SharedPreferences is mocked so the "Server URL set" check is driven by
// the test.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hyacinth/config/config_store.dart';
import 'package:hyacinth/fallback/health_check.dart';
import 'package:hyacinth/permissions/perm_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePerms implements PermManager {
  _FakePerms({
    this.notif = PermissionStatus.granted,
    this.battery = PermissionStatus.granted,
  });

  PermissionStatus notif;
  PermissionStatus battery;

  @override
  Future<PermissionStatus> notificationStatus() async => notif;
  @override
  Future<PermissionStatus> batteryOptimizationStatus() async => battery;
  @override
  Future<PermissionStatus> requestNotifications() async => notif;
  @override
  Future<PermissionStatus> requestBatteryOptimization() async => battery;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HealthCheck', () {
    test('green when URL set, /health 200, perms granted', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.serverUrl': 'http://server:8080',
      });
      final hc = HealthCheck(
        store: ConfigStore(),
        perms: _FakePerms(),
        httpClient: MockClient(
          (req) async => http.Response('{"ok":true}', 200),
        ),
      );
      final report = await hc.run();
      // The home-role check is intentionally `unknown`, so allOk is false.
      // We assert each non-home check individually.
      expect(report.checks.length, 5);
      expect(report.checks[0].status, CheckStatus.ok); // url set
      expect(report.checks[1].status, CheckStatus.ok); // server reachable
      expect(report.checks[2].status, CheckStatus.ok); // notifications
      expect(report.checks[3].status, CheckStatus.ok); // battery
      expect(report.checks[4].status, CheckStatus.unknown); // home role
    });

    test('500 from /health → red row with status code in message', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.serverUrl': 'http://server:8080',
      });
      final hc = HealthCheck(
        store: ConfigStore(),
        perms: _FakePerms(),
        httpClient:
            MockClient((req) async => http.Response('boom', 500)),
      );
      final report = await hc.run();
      final ping = report.checks[1];
      expect(ping.status, CheckStatus.fail);
      expect(ping.message, contains('500'));
    });

    test('no server URL → red row', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final hc = HealthCheck(
        store: ConfigStore(),
        perms: _FakePerms(),
        httpClient:
            MockClient((req) async => http.Response('{"ok":true}', 200)),
      );
      final report = await hc.run();
      expect(report.checks[0].status, CheckStatus.fail);
      expect(report.checks[1].status, CheckStatus.fail);
    });

    test('mixed report: battery denied → battery row red', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.serverUrl': 'http://server:8080',
      });
      final hc = HealthCheck(
        store: ConfigStore(),
        perms: _FakePerms(battery: PermissionStatus.denied),
        httpClient:
            MockClient((req) async => http.Response('{"ok":true}', 200)),
      );
      final report = await hc.run();
      expect(report.checks[2].status, CheckStatus.ok); // notifications
      expect(report.checks[3].status, CheckStatus.fail); // battery
    });

    test('mixed report: notifications denied → that row red', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.serverUrl': 'http://server:8080',
      });
      final hc = HealthCheck(
        store: ConfigStore(),
        perms: _FakePerms(notif: PermissionStatus.denied),
        httpClient:
            MockClient((req) async => http.Response('{"ok":true}', 200)),
      );
      final report = await hc.run();
      expect(report.checks[0].status, CheckStatus.ok); // url
      expect(report.checks[1].status, CheckStatus.ok); // ping
      expect(report.checks[2].status, CheckStatus.fail); // notifications
      expect(report.checks[3].status, CheckStatus.ok); // battery
    });
  });
}
