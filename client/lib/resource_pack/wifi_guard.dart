import 'package:connectivity_plus/connectivity_plus.dart';

/// Thin wrapper around [Connectivity] so [PackManager] doesn't depend on
/// the platform plugin directly. Tests provide a fake by extending this
/// class and overriding [isOnWifi] / [onWifiChanged].
class WifiGuard {
  WifiGuard({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  /// Returns true iff the device currently has a Wi-Fi connection. The
  /// `connectivity_plus` v6 API returns a *list* of active transports
  /// (a phone may be on Wi-Fi and Bluetooth simultaneously); we treat any
  /// list containing `wifi` or `ethernet` as "Wi-Fi" for the purpose of
  /// the resource-pack guard, since LAN over Ethernet is the same risk
  /// profile (no metered cellular bytes).
  Future<bool> isOnWifi() async {
    final results = await _connectivity.checkConnectivity();
    return _isWifiList(results);
  }

  /// Stream of "is currently on Wi-Fi" booleans, deduplicated.
  Stream<bool> onWifiChanged() {
    return _connectivity.onConnectivityChanged
        .map(_isWifiList)
        .distinct();
  }

  static bool _isWifiList(List<ConnectivityResult> results) {
    return results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
  }
}
