import 'package:flutter/foundation.dart';
import 'package:screen_brightness/screen_brightness.dart';

/// Pure-Dart wrapper around the `screen_brightness` package, scoped to
/// "application window" brightness only. This is the always-available
/// fallback for the M7 brightness pipeline — it works without
/// `WRITE_SECURE_SETTINGS` and only affects our app's window. System
/// brightness writes go through [SecureSettings] separately.
class WindowBrightness {
  WindowBrightness({ScreenBrightness? backend})
      : _backend = backend ?? ScreenBrightness();

  final ScreenBrightness _backend;

  /// Returns the current *system* brightness in the 0..1 range. Used as
  /// the snapshot value when entering the displaying phase.
  Future<double> current() async {
    try {
      return await _backend.system;
    } catch (e) {
      debugPrint('WindowBrightness.current failed: $e');
      return 1.0;
    }
  }

  /// Pin the *application* window brightness to [v] (clamped to 0..1).
  Future<void> setOverride(double v) async {
    final clamped = v.clamp(0.0, 1.0);
    try {
      await _backend.setApplicationScreenBrightness(clamped);
    } catch (e) {
      debugPrint('WindowBrightness.setOverride($clamped) failed: $e');
    }
  }

  /// Drop the application override and let the system value take over.
  Future<void> reset() async {
    try {
      await _backend.resetApplicationScreenBrightness();
    } catch (e) {
      debugPrint('WindowBrightness.reset failed: $e');
    }
  }
}
