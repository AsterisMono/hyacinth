import 'package:flutter/services.dart';

/// Result of a single onboarding-time root grant pass.
///
/// `rootAvailable` reflects whether `su -c id` succeeded with `uid=0`.
/// The three boolean grant flags reflect the exit status of each
/// `pm grant` / `dumpsys deviceidle whitelist` invocation. They are
/// independent — a partial success (e.g. write_secure_settings landed
/// but battery whitelist failed) is normal and the onboarding wizard
/// uses the per-flag status to decide which subsequent steps to skip.
class RootGrantSummary {
  const RootGrantSummary({
    required this.rootAvailable,
    required this.writeSecureSettings,
    required this.postNotifications,
    required this.batteryOpt,
  });

  final bool rootAvailable;
  final bool writeSecureSettings;
  final bool postNotifications;
  final bool batteryOpt;

  bool get allGranted =>
      rootAvailable && writeSecureSettings && postNotifications && batteryOpt;
}

/// Thin wrapper around the `io.hyacinth/root` MethodChannel implemented
/// in `MainActivity.kt`. The Kotlin side exposes named, audited grant
/// methods (NOT a generic `runAsRoot(cmd)`); we mirror them here.
///
/// IMPORTANT: do not call any of these methods on every app start.
/// `hasRoot()` triggers a Magisk/KernelSU consent dialog on first use,
/// and the grant methods do too. They are reserved for explicit user
/// moments — onboarding "Check for root" and HealthCheck "Fix" — with
/// the single exception of [grantWriteSecureSettings] called silently
/// from app boot when [ConfigStore.getRootAvailable] is already true.
class RootHelper {
  RootHelper({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('io.hyacinth/root');

  final MethodChannel _channel;

  Future<bool> hasRoot() => _invokeBool('hasRoot');

  Future<bool> grantWriteSecureSettings() =>
      _invokeBool('grantWriteSecureSettings');

  Future<bool> grantPostNotifications() =>
      _invokeBool('grantPostNotifications');

  Future<bool> whitelistBatteryOpt() => _invokeBool('whitelistBatteryOpt');

  Future<bool> _invokeBool(String method) async {
    try {
      final result = await _channel.invokeMethod<bool>(method);
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Probes root and, if available, runs all three grants in sequence.
  /// All four channel calls fire even if one returns false — the user
  /// only sees ONE Magisk consent prompt during this whole sequence,
  /// and we want maximum information about which permissions landed.
  Future<RootGrantSummary> autoGrantAll() async {
    final root = await hasRoot();
    if (!root) {
      return const RootGrantSummary(
        rootAvailable: false,
        writeSecureSettings: false,
        postNotifications: false,
        batteryOpt: false,
      );
    }
    final wss = await grantWriteSecureSettings();
    final notif = await grantPostNotifications();
    final batt = await whitelistBatteryOpt();
    return RootGrantSummary(
      rootAvailable: true,
      writeSecureSettings: wss,
      postNotifications: notif,
      batteryOpt: batt,
    );
  }
}
