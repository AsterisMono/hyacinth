// Unit tests for the M2 AppState state machine.
//
// We stub out the ConfigClient (throwing vs returning a known config) and
// run against a HealthCheck that's been handed a fake http.Client returning
// 200 for /health. SharedPreferences is replaced with setMockInitialValues.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hyacinth/app_state.dart';
import 'package:hyacinth/config/config_model.dart';
import 'package:hyacinth/config/config_store.dart';
import 'package:hyacinth/fallback/health_check.dart';
import 'package:hyacinth/net/config_client.dart';
import 'package:hyacinth/permissions/perm_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ThrowingConfigClient extends ConfigClient {
  _ThrowingConfigClient() : super(httpClient: MockClient((_) async {
          throw Exception('boom');
        }));

  @override
  Future<HyacinthConfig> fetch(String serverBaseUrl) async {
    throw Exception('synthetic fetch failure');
  }
}

class _OkConfigClient extends ConfigClient {
  _OkConfigClient() : super(httpClient: MockClient((_) async {
          throw StateError('should not be called');
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

/// A fake PermManager that reports everything as granted so the HealthCheck
/// doesn't trip on notification/battery rows during tests.
class _GrantedPerms implements PermManager {
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

HealthCheck _makeHealthCheck({required bool pingOk}) {
  final mock = MockClient((request) async {
    if (request.url.path.endsWith('/health')) {
      return http.Response(pingOk ? '{"ok":true}' : '', pingOk ? 200 : 500);
    }
    return http.Response('not found', 404);
  });
  return HealthCheck(
    store: ConfigStore(),
    perms: _GrantedPerms(),
    httpClient: mock,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'hyacinth.serverUrl': 'http://127.0.0.1:8080',
      'hyacinth.onboardingComplete': true,
    });
  });

  test('start() lands in fallback when ConfigClient throws', () async {
    final state = AppState(
      store: ConfigStore(),
      client: _ThrowingConfigClient(),
      healthCheck: _makeHealthCheck(pingOk: true),
      fallbackRetryInterval: const Duration(hours: 1),
    );
    await state.start();
    expect(state.phase, AppPhase.fallback);
    expect(state.error, contains('synthetic fetch failure'));
    state.dispose();
  });

  test('start() lands in displaying when everything succeeds', () async {
    final state = AppState(
      store: ConfigStore(),
      client: _OkConfigClient(),
      healthCheck: _makeHealthCheck(pingOk: true),
      fallbackRetryInterval: const Duration(hours: 1),
    );
    await state.start();
    expect(state.phase, AppPhase.displaying);
    expect(state.config?.content, 'https://example.com');
    expect(state.error, isNull);
    state.dispose();
  });

  test('start() routes to onboarding when onboardingComplete is false',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = AppState(
      store: ConfigStore(),
      client: _OkConfigClient(),
      healthCheck: _makeHealthCheck(pingOk: true),
      fallbackRetryInterval: const Duration(hours: 1),
    );
    await state.start();
    expect(state.phase, AppPhase.onboarding);
    state.dispose();
  });

  test('start() goes to fallback when /health is down', () async {
    final state = AppState(
      store: ConfigStore(),
      client: _OkConfigClient(),
      healthCheck: _makeHealthCheck(pingOk: false),
      fallbackRetryInterval: const Duration(hours: 1),
    );
    await state.start();
    expect(state.phase, AppPhase.fallback);
    expect(state.error, contains('Server reachable'));
    state.dispose();
  });
}
