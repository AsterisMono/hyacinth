import 'dart:async';

import 'package:flutter/foundation.dart';

import 'config/config_model.dart';
import 'config/config_store.dart';
import 'fallback/health_check.dart';
import 'net/config_client.dart';
import 'net/ws_client.dart';
import 'resource_pack/pack_cache.dart';
import 'resource_pack/pack_manager.dart';
import 'resource_pack/pack_manifest.dart';
import 'resource_pack/wifi_guard.dart';

/// Signature for a function that builds a [WsClient] given a base URL and
/// the callback to invoke on every `config_update`. Injectable so unit
/// tests can substitute a fake client without opening a socket.
typedef WsClientFactory = WsClient Function(
  String baseUrl,
  void Function(HyacinthConfig) onConfigUpdate,
);

/// Signature for a function that builds a [PackManager] for a given
/// server base URL. Injected via [AppState] so tests can hand in a fake
/// manager whose `ensure` is a hand-rolled stub.
typedef PackManagerFactory = PackManager Function(String baseUrl);

WsClient _defaultWsClientFactory(
  String baseUrl,
  void Function(HyacinthConfig) onConfigUpdate,
) =>
    WsClient(baseUrl: baseUrl, onConfigUpdate: onConfigUpdate);

/// Pulls a `<id>` out of `app-scheme://pack/<id>/...` URLs. Returns null
/// for any other shape (regular `https://`, malformed, etc.).
String? extractPackIdFromContent(String content) {
  Uri uri;
  try {
    uri = Uri.parse(content);
  } catch (_) {
    return null;
  }
  if (uri.scheme != 'app-scheme') return null;
  if (uri.host != 'pack') return null;
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) return null;
  return segs.first;
}

/// High-level lifecycle phases the app can be in.
///
/// M2 deliberately does not include a `reconnecting` phase — that only
/// becomes meaningful once M3 adds the WebSocket client. For now the
/// transitions are: `booting -> (onboarding | connecting) -> displaying`
/// with `fallback` as the recovery state on any failure.
enum AppPhase { booting, onboarding, connecting, displaying, fallback }

/// Central state machine for the Hyacinth client.
///
/// Owns the current [AppPhase], the resolved [HyacinthConfig] (when in
/// `displaying`), and the most recent error message (when in `fallback`).
/// The UI in `main.dart` listens via [ChangeNotifier] and picks a page to
/// render from the current phase.
class AppState extends ChangeNotifier {
  AppState({
    ConfigStore? store,
    ConfigClient? client,
    HealthCheck? healthCheck,
    WsClientFactory? wsClientFactory,
    PackCache? packCache,
    PackManagerFactory? packManagerFactory,
    Duration fallbackRetryInterval = const Duration(seconds: 10),
  })  : _store = store ?? ConfigStore(),
        _client = client ?? ConfigClient(),
        _healthCheck = healthCheck ?? HealthCheck(),
        _wsClientFactory = wsClientFactory ?? _defaultWsClientFactory,
        _packCache = packCache ?? PackCache(),
        _packManagerFactory = packManagerFactory,
        _fallbackRetryInterval = fallbackRetryInterval;

  final ConfigStore _store;
  final ConfigClient _client;
  final HealthCheck _healthCheck;
  final WsClientFactory _wsClientFactory;
  final PackCache _packCache;
  final PackManagerFactory? _packManagerFactory;
  final Duration _fallbackRetryInterval;
  WsClient? _wsClient;
  PackManager? _packManager;

  PackCache get packCache => _packCache;

  AppPhase _phase = AppPhase.booting;
  HyacinthConfig? _config;
  String? _error;
  HealthReport? _lastHealthReport;
  Timer? _fallbackTimer;
  bool _disposed = false;

  AppPhase get phase => _phase;
  HyacinthConfig? get config => _config;
  String? get error => _error;
  HealthReport? get lastHealthReport => _lastHealthReport;

  /// Entry point called by `main.dart` right after constructing the state.
  /// Reads the onboarding flag and dispatches to either the onboarding
  /// wizard or the connect flow.
  Future<void> start() async {
    _setPhase(AppPhase.booting);
    final complete = await _store.isOnboardingComplete();
    final serverUrl = await _store.loadServerUrl();
    if (!complete || serverUrl == null || serverUrl.trim().isEmpty) {
      _setPhase(AppPhase.onboarding);
      return;
    }
    await _connect();
  }

  /// Called by the onboarding wizard once the user has entered a server
  /// URL and accepted (or explicitly skipped) the permission prompts.
  Future<void> completeOnboarding(String serverUrl) async {
    await _store.saveServerUrl(serverUrl);
    await _store.setOnboardingComplete(true);
    await _connect();
  }

  /// "Reload now" / "Retry" button in the fallback page.
  Future<void> retryConnect() async {
    await _connect();
  }

  /// Forces a transition into `fallback` with an explicit reason. Used by
  /// e.g. `recheckPermissions()` when it detects a regression.
  void goToFallback(String reason) {
    _error = reason;
    _setPhase(AppPhase.fallback);
    _startFallbackTimer();
  }

  /// Re-runs the health checks on demand. If any previously-green check
  /// has regressed, flips into `fallback` (the "revoking a permission
  /// flips the UI" behaviour in the M2 verification steps).
  Future<void> recheckPermissions() async {
    final report = await _healthCheck.run();
    _lastHealthReport = report;
    final hardFail = report.checks.any((c) => c.status == CheckStatus.fail);
    if (hardFail && _phase == AppPhase.displaying) {
      goToFallback('A health check regressed.');
    } else {
      notifyListeners();
    }
  }

  Future<void> _connect() async {
    _setPhase(AppPhase.connecting);
    _error = null;
    try {
      final report = await _healthCheck.run();
      _lastHealthReport = report;
      if (!report.allOk) {
        final hardFail = report.checks.any(
          (c) => c.status == CheckStatus.fail,
        );
        if (hardFail) {
          final firstFail = report.checks
              .firstWhere((c) => c.status == CheckStatus.fail);
          _error = 'Health check failed: ${firstFail.name} — '
              '${firstFail.message}';
          _setPhase(AppPhase.fallback);
          _startFallbackTimer();
          return;
        }
      }
      final serverUrl = await _store.loadServerUrl();
      if (serverUrl == null || serverUrl.trim().isEmpty) {
        _error = 'No server URL configured.';
        _setPhase(AppPhase.fallback);
        _startFallbackTimer();
        return;
      }
      final cfg = await _client.fetch(serverUrl);
      // If the new content URL is an `app-scheme://pack/<id>/...`, we
      // must materialize the pack on disk before mounting DisplayPage —
      // otherwise the WebView's first GET hits the cache miss path and
      // shows broken content. ensurePackForConfig() throws PackUnavailable
      // / PackChecksumMismatch / network errors, all of which we catch
      // below and surface as a fallback transition.
      await _ensurePackForConfig(cfg, serverUrl);
      _config = cfg;
      _error = null;
      _cancelFallbackTimer();
      _openWsClient(serverUrl);
      _setPhase(AppPhase.displaying);
    } catch (e) {
      _error = '$e';
      _setPhase(AppPhase.fallback);
      _startFallbackTimer();
    }
  }

  void _startFallbackTimer() {
    _cancelFallbackTimer();
    _fallbackTimer = Timer.periodic(_fallbackRetryInterval, (_) async {
      if (_phase != AppPhase.fallback) {
        _cancelFallbackTimer();
        return;
      }
      await _connect();
    });
  }

  void _cancelFallbackTimer() {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
  }

  void _setPhase(AppPhase phase) {
    final leavingDisplaying =
        _phase == AppPhase.displaying && phase != AppPhase.displaying;
    _phase = phase;
    if (leavingDisplaying) {
      _closeWsClient();
    }
    if (!_disposed) notifyListeners();
  }

  /// Returns a [PackManager] for the given base URL, lazily constructing
  /// one and caching it for subsequent calls. Tests can hand in a custom
  /// factory via the constructor.
  PackManager _ensurePackManager(String baseUrl) {
    final existing = _packManager;
    if (existing != null) return existing;
    final factory = _packManagerFactory ??
        (url) => PackManager(
              serverBaseUrl: url,
              cache: _packCache,
              wifiGuard: WifiGuard(),
            );
    final mgr = factory(baseUrl);
    _packManager = mgr;
    return mgr;
  }

  /// If [cfg.content] is an `app-scheme://pack/<id>/...` URL, asks the
  /// pack manager to fetch/verify it. No-op for `https://` URLs. Throws
  /// on failure — callers in [_connect] / [_applyConfig] decide what to
  /// do with that.
  Future<void> _ensurePackForConfig(
    HyacinthConfig cfg,
    String serverBaseUrl,
  ) async {
    final packId = extractPackIdFromContent(cfg.content);
    if (packId == null) return;
    final mgr = _ensurePackManager(serverBaseUrl);
    final PackManifest result = await mgr.ensure(packId);
    debugPrint(
      'PackManager.ensure($packId) -> v${result.version} (${result.sha256})',
    );
  }

  void _openWsClient(String baseUrl) {
    _closeWsClient();
    final ws = _wsClientFactory(baseUrl, _applyConfig);
    _wsClient = ws;
    ws.connect();
  }

  void _closeWsClient() {
    _wsClient?.disconnect();
    _wsClient = null;
  }

  /// Diff guard for live config pushes. If the incoming config is value-
  /// equal to the current one we drop the update silently — no notify, no
  /// rebuild. Otherwise we swap and notify; the DisplayPage's own reload
  /// guard then decides whether to remount the WebView.
  ///
  /// Crucial M3 invariant: brightness/timeout-only changes still notify
  /// listeners (state DID change), but the new HyacinthConfig keeps the
  /// same `content`/`contentRevision`, so the WebView reload guard sees
  /// no reason to rebuild and the playing video doesn't flicker.
  void _applyConfig(HyacinthConfig next) {
    if (_phase != AppPhase.displaying) return;
    if (_config == next) return;
    final newPackId = extractPackIdFromContent(next.content);
    final oldPackId = extractPackIdFromContent(_config?.content ?? '');
    final needsPackEnsure = newPackId != null &&
        (newPackId != oldPackId || next.content != _config?.content);
    if (needsPackEnsure) {
      // Ensure the pack BEFORE swapping the config so the WebView is
      // never asked to render an `app-scheme://` URL whose bytes aren't
      // on disk yet. On failure we leave the existing config in place
      // and log — the operator will see the old content keep showing.
      // ignore: discard_returned_future
      _ensurePackBeforeSwap(next);
      return;
    }
    _config = next;
    if (!_disposed) notifyListeners();
  }

  Future<void> _ensurePackBeforeSwap(HyacinthConfig next) async {
    try {
      final serverUrl = await _store.loadServerUrl();
      if (serverUrl == null || serverUrl.trim().isEmpty) return;
      await _ensurePackForConfig(next, serverUrl);
    } catch (e) {
      debugPrint('PackManager.ensure (live update) failed: $e');
      return; // keep showing the old config
    }
    if (_disposed || _phase != AppPhase.displaying) return;
    if (_config == next) return;
    _config = next;
    notifyListeners();
  }

  /// Test seam: drive the diff guard directly without an actual WS push.
  void debugApplyConfig(HyacinthConfig next) => _applyConfig(next);

  @override
  void dispose() {
    _disposed = true;
    _cancelFallbackTimer();
    _closeWsClient();
    super.dispose();
  }
}
