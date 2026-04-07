import 'package:permission_handler/permission_handler.dart';

/// Thin wrapper around `permission_handler` for the M2 permission set.
///
/// M2 deliberately only covers runtime-prompt permissions that the user
/// grants through the normal Android dialogs:
///   * `POST_NOTIFICATIONS` (API 33+)
///   * `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`
///
/// `WRITE_SECURE_SETTINGS`, device admin, keyguard control, and root-gated
/// power-profile tweaks are all deferred to M7 / M7.5.
class PermManager {
  const PermManager();

  Future<PermissionStatus> notificationStatus() {
    return Permission.notification.status;
  }

  Future<PermissionStatus> batteryOptimizationStatus() {
    return Permission.ignoreBatteryOptimizations.status;
  }

  Future<PermissionStatus> requestNotifications() {
    return Permission.notification.request();
  }

  Future<PermissionStatus> requestBatteryOptimization() {
    return Permission.ignoreBatteryOptimizations.request();
  }
}
