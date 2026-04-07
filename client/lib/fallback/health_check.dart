import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../config/config_store.dart';
import '../permissions/perm_manager.dart';

/// Outcome of a single [HealthCheck] row.
enum CheckStatus { ok, fail, unknown }

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
  })  : _store = store ?? ConfigStore(),
        _perms = perms ?? const PermManager(),
        _http = httpClient ?? http.Client();

  static const Duration _pingTimeout = Duration(seconds: 3);

  final ConfigStore _store;
  final PermManager _perms;
  final http.Client _http;

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

    return HealthReport(results);
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
