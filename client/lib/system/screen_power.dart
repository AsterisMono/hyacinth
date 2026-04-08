import 'package:flutter/services.dart';

/// Thrown when the operator requested a screen-on/off transition but
/// the device has neither root nor an active Device Admin. The caller
/// (DisplayPage) catches this and surfaces an error banner.
class ScreenPowerUnavailable implements Exception {
  const ScreenPowerUnavailable();
  @override
  String toString() => 'ScreenPower: no capability (need root or Device Admin)';
}

/// Wrapper around the `io.hyacinth/screen_power` MethodChannel implemented
/// in `MainActivity.kt`. Mirrors the shape of M7's [SecureSettings]: all
/// getters degrade to a safe default on channel error; [apply] is the
/// single write path that may throw.
class ScreenPower {
  ScreenPower({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('io.hyacinth/screen_power');

  final MethodChannel _channel;

  Future<bool> isInteractive() async {
    try {
      return (await _channel.invokeMethod<bool>('isInteractive')) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isAdminActive() async {
    try {
      return (await _channel.invokeMethod<bool>('isAdminActive')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Fires the system Add-device-admin dialog. The result of the user
  /// action is observed via a follow-up [isAdminActive] call — this
  /// method returns as soon as the intent is dispatched.
  Future<void> requestAdmin() async {
    try {
      await _channel.invokeMethod<void>('requestAdmin');
    } catch (_) {
      // The intent failed to fire. Caller will re-check isAdminActive.
    }
  }

  /// Drives the panel to the requested state. Returns the tier that
  /// fulfilled the request: `'noop'` (already in state), `'root'`, or
  /// `'admin'`. Throws [ScreenPowerUnavailable] when neither tier is
  /// available; other [PlatformException]s are rethrown unchanged.
  Future<String> apply(bool screenOn) async {
    try {
      final tier = await _channel.invokeMethod<String>(
        'setScreenOn',
        <String, dynamic>{'on': screenOn},
      );
      return tier ?? 'unknown';
    } on PlatformException catch (e) {
      if (e.code == 'no_capability') {
        throw const ScreenPowerUnavailable();
      }
      rethrow;
    }
  }
}
