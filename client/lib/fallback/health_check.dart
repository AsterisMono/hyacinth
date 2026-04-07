import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../config/config_store.dart';
import '../permissions/perm_manager.dart';
import '../resource_pack/wifi_guard.dart';
import '../system/root_helper.dart';
import '../system/secure_settings.dart';

/// Thrown by a `Fix` callback when the underlying root grant fails.
/// The fallback page catches this and surfaces a snackbar pointing the
/// operator at the manual `adb` instructions in the README.
class RootGrantFailed implements Exception {
  const RootGrantFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Outcome of a single [HealthCheck] row.
///
/// `warn` is a soft failure — the row renders in amber and doesn't block
/// the connect flow. Introduced in M5 for the "on mobile data" case: the
/// app still works off a cached pack but new downloads are deferred.
enum CheckStatus { ok, warn, fail, unknown }

/// A single row in the fallback HealthCheck list.
///
/// [fix] is optional; when non-null the fallback UI renders a "Fix" button
/// that invokes it (permission request, settings intent, etc.).
class CheckResult {
  const CheckResult({
    required this.name,
    required this.status,
    required this.message,
    this.fix,
  });

  final String name;
  final CheckStatus status;
  final String message;
  final Future<void> Function()? fix;
}

/// Snapshot of all health checks.
class HealthReport {
  const HealthReport(this.checks);

  final List<CheckResult> checks;

  /// True when every check is green. Used by [AppState] to decide whether
  /// the connect flow may proceed to `/config`.
  bool get allOk => checks.every((c) => c.status == CheckStatus.ok);
}

/// Runs the M2 health checks.
///
/// The M2 check set is intentionally small:
///   * server URL set (ConfigStore)
///   * server reachable (`GET <base>/health`)
///   * notifications permission
///   * battery-optimisation exemption
class HealthCheck {
  HealthCheck({
    ConfigStore? store,
    PermManager? perms,
    http.Client? httpClient,
    WifiGuard? wifiGuard,
    SecureSettings? secureSettings,
    RootHelper? rootHelper,
  })  : _store = store ?? ConfigStore(),
        _perms = perms ?? const PermManager(),
        _http = httpClient ?? http.Client(),
        _wifiGuard = wifiGuard ?? WifiGuard(),
        _secureSettings = secureSettings ?? SecureSettings(),
        _rootHelper = rootHelper ?? RootHelper();

  static const Duration _pingTimeout = Duration(seconds: 3);

  final ConfigStore _store;
  final PermManager _perms;
  final http.Client _http;
  final WifiGuard _wifiGuard;
  final SecureSettings _secureSettings;
  final RootHelper _rootHelper;

  Future<HealthReport> run() async {
    final results = <CheckResult>[];

    final serverUrl = await _store.loadServerUrl();
    final hasUrl = serverUrl != null && serverUrl.trim().isNotEmpty;
    results.add(CheckResult(
      name: 'Server URL set',
      status: hasUrl ? CheckStatus.ok : CheckStatus.fail,
      message: hasUrl ? serverUrl : 'No server URL configured.',
    ));

    if (hasUrl) {
      results.add(await _pingServer(serverUrl));
    } else {
      results.add(const CheckResult(
        name: 'Server reachable',
        status: CheckStatus.fail,
        message: 'Set a server URL first.',
      ));
    }

    results.add(await _notificationCheck());
    results.add(await _batteryCheck());
    results.add(await _wifiCheck());
    results.add(await _secureSettingsCheck());
    results.add(await _rootCheck());

    return HealthReport(results);
  }

  /// M8.1 — `WRITE_SECURE_SETTINGS` row. Fix button calls
  /// `RootHelper.grantWriteSecureSettings()`. The button is exposed even
  /// when we don't yet know whether root is available — Magisk will
  /// prompt for consent if needed, and the call returns false if root
  /// is absent.
  Future<CheckResult> _secureSettingsCheck() async {
    final ok = await _secureSettings.hasPermission();
    if (ok) {
      return const CheckResult(
        name: 'System brightness/timeout permission',
        status: CheckStatus.ok,
        message: 'Granted',
      );
    }
    return CheckResult(
      name: 'System brightness/timeout permission',
      status: CheckStatus.warn,
      message: 'Not granted — brightness/timeout fall back to window-only.',
      fix: () async {
        final granted = await _rootHelper.grantWriteSecureSettings();
        if (!granted) {
          throw const RootGrantFailed(
            'pm grant via root failed. See the README for the manual '
            '`adb shell pm grant` command.',
          );
        }
      },
    );
  }

  /// M8.1 — root visibility row. Reads only the cached state from
  /// [ConfigStore]; we never call `hasRoot()` here because that would
  /// fire a Magisk prompt. Root absence is `unknown`, NEVER `fail`,
  /// since manual `pm grant` from a laptop is a perfectly valid setup.
  Future<CheckResult> _rootCheck() async {
    final checked = await _store.getRootChecked();
    if (!checked) {
      return const CheckResult(
        name: 'Root access',
        status: CheckStatus.unknown,
        message: 'Not checked',
      );
    }
    final available = await _store.getRootAvailable();
    if (available) {
      return const CheckResult(
        name: 'Root access',
        status: CheckStatus.ok,
        message: 'Available',
      );
    }
    return const CheckResult(
      name: 'Root access',
      status: CheckStatus.unknown,
      message: 'Not available — manual `pm grant` is fine',
    );
  }

  /// Wi-Fi connectivity row. Soft warning when off Wi-Fi (cached packs
  /// keep working, but new downloads are deferred). Never blocks the
  /// connect flow — see [HealthReport.allOk] semantics.
  Future<CheckResult> _wifiCheck() async {
    try {
      final onWifi = await _wifiGuard.isOnWifi();
      if (onWifi) {
        return const CheckResult(
          name: 'Wi-Fi',
          status: CheckStatus.ok,
          message: 'Connected',
        );
      }
      return const CheckResult(
        name: 'Wi-Fi',
        status: CheckStatus.warn,
        message: 'Not on Wi-Fi — pack downloads deferred until reconnected.',
      );
    } catch (e) {
      return CheckResult(
        name: 'Wi-Fi',
        status: CheckStatus.warn,
        message: 'Connectivity check failed: $e',
      );
    }
  }

  Future<CheckResult> _pingServer(String baseUrl) async {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$base/health');
    try {
      final resp = await _http.get(uri).timeout(_pingTimeout);
      if (resp.statusCode == 200) {
        return CheckResult(
          name: 'Server reachable',
          status: CheckStatus.ok,
          message: 'GET $uri -> 200',
        );
      }
      return CheckResult(
        name: 'Server reachable',
        status: CheckStatus.fail,
        message: 'GET $uri -> HTTP ${resp.statusCode}',
      );
    } catch (e) {
      return CheckResult(
        name: 'Server reachable',
        status: CheckStatus.fail,
        message: '$e',
      );
    }
  }

  Future<CheckResult> _notificationCheck() async {
    final status = await _perms.notificationStatus();
    final ok = status.isGranted;
    return CheckResult(
      name: 'Notifications permission',
      status: ok ? CheckStatus.ok : CheckStatus.fail,
      message: ok ? 'Granted' : 'Not granted ($status)',
      fix: ok ? null : () => _perms.requestNotifications(),
    );
  }

  Future<CheckResult> _batteryCheck() async {
    final status = await _perms.batteryOptimizationStatus();
    final ok = status.isGranted;
    return CheckResult(
      name: 'Battery optimization exemption',
      status: ok ? CheckStatus.ok : CheckStatus.fail,
      message: ok ? 'Exempt' : 'Not exempt ($status)',
      fix: ok ? null : () => _perms.requestBatteryOptimization(),
    );
  }

}
