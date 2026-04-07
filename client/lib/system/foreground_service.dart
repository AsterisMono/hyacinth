import 'package:flutter/services.dart';

/// Thin wrapper around the `io.hyacinth/foreground_service` MethodChannel
/// implemented in `MainActivity.kt`.
///
/// The Android side is a stub foreground service whose only job is to
/// pin the Hyacinth process foreground so Doze doesn't reap the WS
/// heartbeat. We don't surface failures from start/stop — if the
/// Android side throws (no notification permission, missing service
/// permission on a hostile OEM ROM, etc.) we just log and continue.
/// The app still works, the WS is just more likely to die under Doze.
class ForegroundService {
  ForegroundService({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('io.hyacinth/foreground_service');

  final MethodChannel _channel;

  /// Best-effort start. Returns true on success, false on any failure.
  Future<bool> start() async {
    try {
      await _channel.invokeMethod<void>('start');
      return true;
    } on MissingPluginException {
      // Test / desktop / iOS — no platform implementation. Pretend
      // success so callers don't crash.
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Best-effort stop. Always returns; never throws.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No-op outside Android.
    } catch (_) {
      // Swallow — there's nothing useful to do here.
    }
  }
}
