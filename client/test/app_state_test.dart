// Unit tests for the M2 AppState state machine.
//
// We stub out the ConfigClient (throwing vs returning a known config) and
// run against a HealthCheck that's been handed a fake http.Client returning
// 200 for /health. SharedPreferences is replaced with setMockInitialValues.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hyacinth/app_state.dart';
import 'package:hyacinth/config/config_model.dart';
import 'package:hyacinth/config/config_store.dart';
import 'package:hyacinth/fallback/health_check.dart';
import 'package:hyacinth/net/config_client.dart';
import 'package:hyacinth/net/ws_client.dart';
import 'package:hyacinth/permissions/perm_manager.dart';
import 'package:hyacinth/resource_pack/pack_cache.dart';
import 'package:hyacinth/resource_pack/pack_manager.dart';
import 'package:hyacinth/resource_pack/pack_manifest.dart';
import 'package:hyacinth/resource_pack/wifi_guard.dart';
import 'package:hyacinth/system/screen_power.dart';
import 'package:hyacinth/system/secure_settings.dart';
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

class _PackConfigClient extends ConfigClient {
  _PackConfigClient(this._cfg) : super(httpClient: MockClient((_) async {
          throw StateError('should not be called');
        }));
  final HyacinthConfig _cfg;
  @override
  Future<HyacinthConfig> fetch(String serverBaseUrl) async => _cfg;
}

/// Subclass of [PackManager] whose ensure() is fully driven by the test —
/// no real cache, no real network. Records every call.
class _FakePackManager extends PackManager {
  _FakePackManager({
    this.fail = false,
  }) : super(
          serverBaseUrl: 'http://unused',
          cache: PackCache(overrideRoot: Directory.systemTemp),
          wifiGuard: _NopWifi(),
          httpClient: MockClient((_) async {
            throw StateError('should not be called');
          }),
        );

  bool fail;
  final List<String> calls = <String>[];
  final List<String?> syncCalls = <String?>[];

  @override
  Future<List<String>> syncToServer({String? preserveId}) async {
    syncCalls.add(preserveId);
    return const <String>[];
  }

  @override
  Future<PackManifest> ensure(String packId) async {
    calls.add(packId);
    if (fail) {
      throw PackUnavailable('forced failure for tests');
    }
    return PackManifest(
      id: packId,
      version: 1,
      type: 'png',
      filename: 'image.png',
      sha256: 'h',
      size: 0,
      createdAt: 't',
    );
  }
}

class _NopWifi extends WifiGuard {
  _NopWifi() : super();
  @override
  Future<bool> isOnWifi() async => true;
  @override
  Stream<bool> onWifiChanged() => const Stream.empty();
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

/// Inert WsClient factory for tests that don't care about the WS path.
/// Returns a WsClient backed by a never-emitting fake connection so the
/// reconnect loop never tries to dial a real socket.
WsClient _inertWsClient(
  String baseUrl,
  void Function(HyacinthConfig) onConfigUpdate,
  void Function(bool on) onScreenCommand,
) {
  return WsClient(
    baseUrl: baseUrl,
    channelFactory: (_) => _NeverChannel(),
    onConfigUpdate: onConfigUpdate,
    onScreenCommand: onScreenCommand,
  );
}

/// Fake [SecureSettings] that always reports the permission as granted.
/// Without it, the new M8.1 health row added in this milestone would
/// hard-fail on every test (real channel returns false in test env)
/// and tip every AppState test into fallback.
class _GrantedSecureSettings extends SecureSettings {
  _GrantedSecureSettings() : super();
  @override
  Future<bool> hasPermission() async => true;
}

/// Fake [ScreenPower] for AppState tests. Reports Device Admin as active
/// so the M9 "Screen-off capability" HealthCheck row is green and doesn't
/// flip AppState into fallback.
class _AdminActiveScreenPower implements ScreenPower {
  @override
  Future<bool> isInteractive() async => true;
  @override
  Future<bool> isAdminActive() async => true;
  @override
  Future<void> requestAdmin() async {}
  @override
  Future<String> apply(bool screenOn) async => 'admin';
}

/// Fake [ScreenPower] whose `apply` behavior is flipped by the test. Used
/// to drive M9.1 `_handleScreenCommand` assertions.
class _ProgrammableScreenPower implements ScreenPower {
  bool throwUnavailable = false;
  final List<bool> calls = <bool>[];
  @override
  Future<bool> isInteractive() async => true;
  @override
  Future<bool> isAdminActive() async => true;
  @override
  Future<void> requestAdmin() async {}
  @override
  Future<String> apply(bool screenOn) async {
    calls.add(screenOn);
    if (throwUnavailable) throw const ScreenPowerUnavailable();
    return 'admin';
  }
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
    secureSettings: _GrantedSecureSettings(),
    screenPower: _AdminActiveScreenPower(),
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
      wsClientFactory: _inertWsClient,
      screenPower: _AdminActiveScreenPower(),
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
      wsClientFactory: _inertWsClient,
      screenPower: _AdminActiveScreenPower(),
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
      wsClientFactory: _inertWsClient,
      screenPower: _AdminActiveScreenPower(),
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
      wsClientFactory: _inertWsClient,
      screenPower: _AdminActiveScreenPower(),
      fallbackRetryInterval: const Duration(hours: 1),
    );
    await state.start();
    expect(state.phase, AppPhase.fallback);
    expect(state.error, contains('Server reachable'));
    state.dispose();
  });

  test('dispose() cancels the fallback retry timer', () async {
    final state = AppState(
      store: ConfigStore(),
      client: _ThrowingConfigClient(),
      healthCheck: _makeHealthCheck(pingOk: true),
      wsClientFactory: _inertWsClient,
      screenPower: _AdminActiveScreenPower(),
      fallbackRetryInterval: const Duration(milliseconds: 30),
    );
    await state.start();
    expect(state.phase, AppPhase.fallback);
    // Capture how many notifyListeners cycles fire after dispose; should be
    // zero since the timer is dead.
    var notified = 0;
    state.addListener(() => notified++);
    state.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(notified, 0,
        reason: 'no notifications should arrive after dispose');
  });

  test('completeOnboarding() persists URL + flag and connects', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = ConfigStore();
    final state = AppState(
      store: store,
      client: _OkConfigClient(),
      healthCheck: _makeHealthCheck(pingOk: true),
      wsClientFactory: _inertWsClient,
      screenPower: _AdminActiveScreenPower(),
      fallbackRetryInterval: const Duration(hours: 1),
    );
    await state.completeOnboarding('http://server:8080');
    expect(await store.loadServerUrl(), 'http://server:8080');
    expect(await store.isOnboardingComplete(), isTrue);
    expect(state.phase, AppPhase.displaying);
    state.dispose();
  });

  test('recheckPermissions() while displaying flips to fallback on regression',
      () async {
    // Start green so we land in displaying.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'hyacinth.serverUrl': 'http://127.0.0.1:8080',
      'hyacinth.onboardingComplete': true,
    });
    var pingOk = true;
    final mock = MockClient((request) async {
      return http.Response(pingOk ? '{"ok":true}' : '', pingOk ? 200 : 500);
    });
    final hc = HealthCheck(
      store: ConfigStore(),
      perms: _GrantedPerms(),
      httpClient: mock,
      secureSettings: _GrantedSecureSettings(),
      screenPower: _AdminActiveScreenPower(),
    );
    final state = AppState(
      store: ConfigStore(),
      client: _OkConfigClient(),
      healthCheck: hc,
      wsClientFactory: _inertWsClient,
      screenPower: _AdminActiveScreenPower(),
      fallbackRetryInterval: const Duration(hours: 1),
    );
    await state.start();
    expect(state.phase, AppPhase.displaying);
    // Now flip the ping red and re-check.
    pingOk = false;
    await state.recheckPermissions();
    expect(state.phase, AppPhase.fallback);
    expect(state.error, isNotNull);
    state.dispose();
  });

  group('M3 WebSocket integration', () {
    // Each AppState in this group is built with a WsClient factory that
    // captures the constructed client(s) so the test can poke them.
    late List<WsClient> created;
    WsClientFactory makeFactory() {
      created = <WsClient>[];
      return (baseUrl, onConfigUpdate, onScreenCommand) {
        // The WsClient takes a channelFactory; we hand it one that returns
        // a stream that never emits and a sink that swallows writes. The
        // AppState test doesn't need to drive the channel — it pokes
        // _applyConfig directly via debugApplyConfig.
        final ws = WsClient(
          baseUrl: baseUrl,
          channelFactory: (_) => _NeverChannel(),
          onConfigUpdate: onConfigUpdate,
          onScreenCommand: onScreenCommand,
        );
        created.add(ws);
        return ws;
      };
    }

    test('AppState opens a WsClient on entering displaying', () async {
      final state = AppState(
        store: ConfigStore(),
        client: _OkConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: makeFactory(),
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      expect(state.phase, AppPhase.displaying);
      expect(created, hasLength(1));
      expect(created.single.isDisposed, isFalse);
      state.dispose();
    });

    test('debugApplyConfig with equal config does NOT notify listeners',
        () async {
      final state = AppState(
        store: ConfigStore(),
        client: _OkConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: makeFactory(),
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      expect(state.phase, AppPhase.displaying);
      var fired = 0;
      state.addListener(() => fired++);
      // Identical to what _OkConfigClient returned.
      state.debugApplyConfig(const HyacinthConfig(
        content: 'https://example.com',
        contentRevision: 'r1',
        brightness: 'auto',
        screenTimeout: 'always-on',
      ));
      expect(fired, 0,
          reason:
              'an equal config update must be a no-op (no rebuild upstream)');
      state.dispose();
    });

    test(
        'debugApplyConfig with brightness-only delta DOES notify, '
        'but content/revision stay pinned', () async {
      final state = AppState(
        store: ConfigStore(),
        client: _OkConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: makeFactory(),
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      var fired = 0;
      state.addListener(() => fired++);
      state.debugApplyConfig(const HyacinthConfig(
        content: 'https://example.com',
        contentRevision: 'r1',
        brightness: '40', // changed
        screenTimeout: 'always-on',
      ));
      expect(fired, 1,
          reason: 'a brightness change is a real state delta and must notify');
      // The new config keeps the same content/revision so DisplayPage's
      // reload guard will see no reason to remount the WebView. This is
      // the M3 invariant; the actual no-rebuild assertion lives in
      // display_page_reload_guard_test.dart.
      expect(state.config!.content, 'https://example.com');
      expect(state.config!.contentRevision, 'r1');
      expect(state.config!.brightness, '40');
      state.dispose();
    });

    test('leaving displaying via goToFallback disconnects the WsClient',
        () async {
      final state = AppState(
        store: ConfigStore(),
        client: _OkConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: makeFactory(),
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      expect(state.phase, AppPhase.displaying);
      final ws = created.single;
      expect(ws.isDisposed, isFalse);
      state.goToFallback('test reason');
      expect(state.phase, AppPhase.fallback);
      expect(ws.isDisposed, isTrue,
          reason: 'WsClient must be disconnected when leaving displaying');
      state.dispose();
    });

    test('dispose() while displaying tears down the WsClient', () async {
      final state = AppState(
        store: ConfigStore(),
        client: _OkConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: makeFactory(),
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      final ws = created.single;
      state.dispose();
      expect(ws.isDisposed, isTrue);
    });
  });

  group('M5 resource pack hookup', () {
    const packCfg = HyacinthConfig(
      content: 'hyacinth://pack/neko/image.png',
      contentRevision: 'r1',
      brightness: 'auto',
      screenTimeout: 'always-on',
    );

    test('start() with pack content awaits ensure() before displaying',
        () async {
      final fake = _FakePackManager();
      final state = AppState(
        store: ConfigStore(),
        client: _PackConfigClient(packCfg),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: _inertWsClient,
        packManagerFactory: (_) => fake,
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      expect(state.phase, AppPhase.displaying);
      expect(fake.calls, <String>['neko']);
      expect(state.config?.content,
          'hyacinth://pack/neko/image.png');
      state.dispose();
    });

    test('start() with pack content goes to fallback when ensure() throws',
        () async {
      final fake = _FakePackManager(fail: true);
      final state = AppState(
        store: ConfigStore(),
        client: _PackConfigClient(packCfg),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: _inertWsClient,
        packManagerFactory: (_) => fake,
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      expect(state.phase, AppPhase.fallback);
      expect(state.error, contains('PackUnavailable'));
      expect(fake.calls, <String>['neko']);
      state.dispose();
    });

    test('start() with https content does NOT call ensure()', () async {
      final fake = _FakePackManager();
      final state = AppState(
        store: ConfigStore(),
        client: _OkConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: _inertWsClient,
        packManagerFactory: (_) => fake,
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      expect(state.phase, AppPhase.displaying);
      expect(fake.calls, isEmpty);
      state.dispose();
    });

    test(
        'start() with pack content calls syncToServer with preserveId',
        () async {
      final fake = _FakePackManager();
      final state = AppState(
        store: ConfigStore(),
        client: _PackConfigClient(packCfg),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: _inertWsClient,
        packManagerFactory: (_) => fake,
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      // Drain microtasks so the fire-and-forget sync call lands.
      await Future<void>.delayed(Duration.zero);
      expect(state.phase, AppPhase.displaying);
      expect(fake.syncCalls, <String?>['neko'],
          reason: 'auto-sync must preserve the currently-displayed pack');
      state.dispose();
    });

    test(
        'start() with https content still calls syncToServer (preserveId '
        'null)', () async {
      final fake = _FakePackManager();
      final state = AppState(
        store: ConfigStore(),
        client: _OkConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: _inertWsClient,
        packManagerFactory: (_) => fake,
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      await Future<void>.delayed(Duration.zero);
      expect(state.phase, AppPhase.displaying);
      expect(fake.syncCalls, <String?>[null]);
      state.dispose();
    });

    test('extractPackIdFromContent parses hyacinth URLs', () {
      expect(extractPackIdFromContent('https://example.com'), isNull);
      expect(
          extractPackIdFromContent('hyacinth://pack/neko/image.png'), 'neko');
      expect(
          extractPackIdFromContent('hyacinth://pack/foo-bar/sub/file.png'),
          'foo-bar');
      expect(extractPackIdFromContent('hyacinth://other/x'), isNull);
      expect(extractPackIdFromContent(''), isNull);
    });
  });

  group('M9.1 screen_command handling', () {
    test(
        'debugHandleScreenCommand with ScreenPowerUnavailable sets error and '
        'notifies', () async {
      final sp = _ProgrammableScreenPower()..throwUnavailable = true;
      final state = AppState(
        store: ConfigStore(),
        client: _OkConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: _inertWsClient,
        screenPower: sp,
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      var fired = 0;
      state.addListener(() => fired++);
      await state.debugHandleScreenCommand(false);
      expect(sp.calls, <bool>[false]);
      expect(state.screenPowerError, isNotNull);
      expect(state.screenPowerError, contains('capability'));
      expect(fired, 1);
      state.dispose();
    });

    test('successful apply clears a previously-set screenPowerError',
        () async {
      final sp = _ProgrammableScreenPower()..throwUnavailable = true;
      final state = AppState(
        store: ConfigStore(),
        client: _OkConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: _inertWsClient,
        screenPower: sp,
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      await state.debugHandleScreenCommand(false);
      expect(state.screenPowerError, isNotNull);
      sp.throwUnavailable = false;
      await state.debugHandleScreenCommand(true);
      expect(state.screenPowerError, isNull,
          reason: 'a successful apply must clear the error');
      state.dispose();
    });
  });

  group('M8.2 back gesture → MainActivity', () {
    late List<WsClient> created;
    WsClientFactory makeFactory() {
      created = <WsClient>[];
      return (baseUrl, onConfigUpdate, onScreenCommand) {
        final ws = WsClient(
          baseUrl: baseUrl,
          channelFactory: (_) => _NeverChannel(),
          onConfigUpdate: onConfigUpdate,
          onScreenCommand: onScreenCommand,
        );
        created.add(ws);
        return ws;
      };
    }

    test(
        'requestMainActivity while displaying → fallback, config preserved, '
        'error cleared', () async {
      final state = AppState(
        store: ConfigStore(),
        client: _OkConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: makeFactory(),
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      expect(state.phase, AppPhase.displaying);
      expect(state.config, isNotNull);
      state.requestMainActivity();
      expect(state.phase, AppPhase.fallback);
      expect(state.config, isNotNull,
          reason: 'cached config must survive back gesture');
      expect(state.error, isNull,
          reason: 'back is user-initiated, not an error');
      state.dispose();
    });

    test('requestMainActivity while already in fallback is a no-op',
        () async {
      final state = AppState(
        store: ConfigStore(),
        client: _ThrowingConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: makeFactory(),
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      expect(state.phase, AppPhase.fallback);
      var fired = 0;
      state.addListener(() => fired++);
      state.requestMainActivity();
      expect(state.phase, AppPhase.fallback);
      expect(fired, 0,
          reason: 'no-op transition must not notify listeners');
      state.dispose();
    });

    test('requestMainActivity tears down the active WsClient', () async {
      final state = AppState(
        store: ConfigStore(),
        client: _OkConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: makeFactory(),
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      expect(created, hasLength(1));
      final firstWs = created.single;
      expect(firstWs.isDisposed, isFalse);
      state.requestMainActivity();
      expect(firstWs.isDisposed, isTrue,
          reason: 'leaving displaying must disconnect the WsClient');
      state.dispose();
    });

    test(
        'returnToDisplaying with cached config → displaying, config unchanged',
        () async {
      final state = AppState(
        store: ConfigStore(),
        client: _OkConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: makeFactory(),
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      final cachedBefore = state.config;
      state.requestMainActivity();
      expect(state.phase, AppPhase.fallback);
      await state.returnToDisplaying();
      expect(state.phase, AppPhase.displaying);
      expect(state.config, same(cachedBefore),
          reason: 'returnToDisplaying must reuse the cached config');
      state.dispose();
    });

    test('returnToDisplaying with no cached config is a no-op', () async {
      final state = AppState(
        store: ConfigStore(),
        client: _ThrowingConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: makeFactory(),
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      expect(state.phase, AppPhase.fallback);
      expect(state.config, isNull);
      await state.returnToDisplaying();
      expect(state.phase, AppPhase.fallback,
          reason: 'no cached config means nothing to return to');
      state.dispose();
    });

    test('returnToDisplaying constructs a fresh WsClient', () async {
      final state = AppState(
        store: ConfigStore(),
        client: _OkConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: makeFactory(),
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      expect(created, hasLength(1));
      state.requestMainActivity();
      expect(created.first.isDisposed, isTrue);
      await state.returnToDisplaying();
      expect(state.phase, AppPhase.displaying);
      expect(created, hasLength(2),
          reason: 're-entering displaying must build a new WsClient');
      expect(created.last.isDisposed, isFalse);
      state.dispose();
    });

    test('returnToDisplaying while already displaying is a no-op', () async {
      final state = AppState(
        store: ConfigStore(),
        client: _OkConfigClient(),
        healthCheck: _makeHealthCheck(pingOk: true),
        wsClientFactory: makeFactory(),
        screenPower: _AdminActiveScreenPower(),
        fallbackRetryInterval: const Duration(hours: 1),
      );
      await state.start();
      expect(state.phase, AppPhase.displaying);
      expect(created, hasLength(1));
      await state.returnToDisplaying();
      expect(state.phase, AppPhase.displaying);
      expect(created, hasLength(1),
          reason: 'no fresh WsClient when already displaying');
      state.dispose();
    });
  });

}

/// A `WsConnection` whose stream never emits and whose sink no-ops. Used
/// by AppState tests that just want to verify the lifecycle wiring, not
/// the message decoding path.
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
