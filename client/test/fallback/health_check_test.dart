// Hermetic tests for the HealthCheck aggregator.
//
// MockClient handles `/health`. PermManager is replaced with a fake the
// test controls so we can flip notification/battery rows green or red.
// SharedPreferences is mocked so the "Server URL set" check is driven by
// the test. WifiGuard is replaced with a fake so the M5 Wi-Fi row is
// deterministic.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hyacinth/config/config_store.dart';
import 'package:hyacinth/fallback/health_check.dart';
import 'package:hyacinth/permissions/perm_manager.dart';
import 'package:hyacinth/resource_pack/wifi_guard.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeWifiGuard extends WifiGuard {
  _FakeWifiGuard({this.wifi = true}) : super();
  bool wifi;
  @override
  Future<bool> isOnWifi() async => wifi;
  @override
  Stream<bool> onWifiChanged() => const Stream.empty();
}

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

HealthCheck _makeHC({
  required MockClient http_,
  _FakePerms? perms,
  bool wifi = true,
}) {
  return HealthCheck(
    store: ConfigStore(),
    perms: perms ?? _FakePerms(),
    wifiGuard: _FakeWifiGuard(wifi: wifi),
    httpClient: http_,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HealthCheck', () {
    test('green when URL set, /health 200, perms granted, on wifi', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.serverUrl': 'http://server:8080',
      });
      final hc = _makeHC(
        http_: MockClient((req) async => http.Response('{"ok":true}', 200)),
      );
      final report = await hc.run();
      expect(report.checks.length, 5);
      expect(report.checks[0].status, CheckStatus.ok); // url set
      expect(report.checks[1].status, CheckStatus.ok); // server reachable
      expect(report.checks[2].status, CheckStatus.ok); // notifications
      expect(report.checks[3].status, CheckStatus.ok); // battery
      expect(report.checks[4].status, CheckStatus.ok); // wifi
      expect(report.allOk, isTrue);
    });

    test('off Wi-Fi → wifi row warns but other rows stay green', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.serverUrl': 'http://server:8080',
      });
      final hc = _makeHC(
        http_: MockClient((req) async => http.Response('{"ok":true}', 200)),
        wifi: false,
      );
      final report = await hc.run();
      expect(report.checks.length, 5);
      expect(report.checks[4].status, CheckStatus.warn);
      expect(report.checks[4].message, contains('Not on Wi-Fi'));
      expect(report.allOk, isFalse,
          reason: 'allOk requires every check to be ok, including wifi');
      // But there are no hard-fail rows.
      final hardFails = report.checks
          .where((c) => c.status == CheckStatus.fail)
          .toList();
      expect(hardFails, isEmpty);
    });

    test('500 from /health → red row with status code in message', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.serverUrl': 'http://server:8080',
      });
      final hc = _makeHC(
        http_: MockClient((req) async => http.Response('boom', 500)),
      );
      final report = await hc.run();
      final ping = report.checks[1];
      expect(ping.status, CheckStatus.fail);
      expect(ping.message, contains('500'));
    });

    test('no server URL → red row', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final hc = _makeHC(
        http_: MockClient((req) async => http.Response('{"ok":true}', 200)),
      );
      final report = await hc.run();
      expect(report.checks[0].status, CheckStatus.fail);
      expect(report.checks[1].status, CheckStatus.fail);
    });

    test('mixed report: battery denied → battery row red', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.serverUrl': 'http://server:8080',
      });
      final hc = _makeHC(
        perms: _FakePerms(battery: PermissionStatus.denied),
        http_: MockClient((req) async => http.Response('{"ok":true}', 200)),
      );
      final report = await hc.run();
      expect(report.checks[2].status, CheckStatus.ok); // notifications
      expect(report.checks[3].status, CheckStatus.fail); // battery
    });

    test('mixed report: notifications denied → that row red', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.serverUrl': 'http://server:8080',
      });
      final hc = _makeHC(
        perms: _FakePerms(notif: PermissionStatus.denied),
        http_: MockClient((req) async => http.Response('{"ok":true}', 200)),
      );
      final report = await hc.run();
      expect(report.checks[0].status, CheckStatus.ok); // url
      expect(report.checks[1].status, CheckStatus.ok); // ping
      expect(report.checks[2].status, CheckStatus.fail); // notifications
      expect(report.checks[3].status, CheckStatus.ok); // battery
    });
  });
}
