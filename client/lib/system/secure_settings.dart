import 'package:flutter/services.dart';

/// Thrown when a secure-settings write fails because
/// `WRITE_SECURE_SETTINGS` has not been granted to the app via
/// `adb shell pm grant ...`. Display-layer code catches this and falls
/// back to window-only brightness control.
class SecureSettingsDenied implements Exception {
  const SecureSettingsDenied([this.message]);
  final String? message;

  @override
  String toString() =>
      'SecureSettingsDenied${message == null ? '' : ': $message'}';
}

/// Thin wrapper around the `io.hyacinth/secure_settings` MethodChannel
/// implemented in `MainActivity.kt`. All getters return `null` on
/// failure (the most common cause is that the underlying setting has
/// never been written, which is fine — the field doesn't exist yet).
/// Setters throw [SecureSettingsDenied] when the underlying call hits
/// a [SecurityException] on the Android side.
class SecureSettings {
  SecureSettings({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('io.hyacinth/secure_settings');

  final MethodChannel _channel;

  /// `Integer.MAX_VALUE` — used as the screen-off timeout for "always on".
  /// Mirrors what we'd write from Kotlin (`Int.MAX_VALUE`).
  static const int alwaysOnTimeoutMs = 2147483647;

  Future<bool> hasPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('hasPermission');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<int?> currentBrightness() => _safeGetInt('currentBrightness');

  Future<int?> currentBrightnessMode() =>
      _safeGetInt('currentBrightnessMode');

  Future<int?> currentScreenOffTimeout() =>
      _safeGetInt('currentScreenOffTimeout');

  Future<int?> _safeGetInt(String method) async {
    try {
      return await _channel.invokeMethod<int>(method);
    } catch (_) {
      return null;
    }
  }

  Future<void> setBrightness(int value) async {
    final clamped = value.clamp(0, 255);
    await _invokeWriting('setBrightness', {'value': clamped});
  }

  Future<void> setBrightnessMode(int mode) async {
    // 0 = manual, 1 = automatic. Anything else is rejected upstream;
    // we still pass through to let the platform decide.
    await _invokeWriting('setBrightnessMode', {'mode': mode});
  }

  Future<void> setScreenOffTimeout(int ms) async {
    await _invokeWriting('setScreenOffTimeout', {'ms': ms});
  }

  Future<void> _invokeWriting(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        throw SecureSettingsDenied(e.message);
      }
      rethrow;
    }
  }
}
