import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/config_store.dart';

/// Thrown by CpuGovernor callers that require support to already be
/// known-available. Currently nobody throws it in production; it's
/// available as a signaling exception for future callers that want a
/// stronger guarantee than a bool return.
class CpuGovernorUnavailable implements Exception {
  const CpuGovernorUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'CpuGovernorUnavailable: $reason';
}

/// Wrapper around the `io.hyacinth/cpu_governor` MethodChannel.
///
/// M11: called by [DisplayPage] on mount ([enterPowersave]) and unmount
/// ([restore]) to auto-tune the device's CPU governor while content is
/// being displayed. All operations are fire-and-forget — failures are
/// logged and swallowed, never surfaced to the operator, never block
/// the display from rendering.
///
/// This class is deliberately left un-`final` so tests can subclass and
/// override [isSupported] / [enterPowersave] / [restore] without having
/// to fake the underlying MethodChannel AND the `ConfigStore` at the
/// same time.
class CpuGovernor {
  CpuGovernor({MethodChannel? channel, ConfigStore? store})
      : _channel =
            channel ?? const MethodChannel('io.hyacinth/cpu_governor'),
        _store = store ?? ConfigStore();

  final MethodChannel _channel;
  final ConfigStore _store;

  /// Composite check: the native side reports whether the
  /// `/sys/devices/system/cpu/cpufreq` path exists, and we AND it with
  /// the M8.1 cached root-availability flag. Reading the cached flag
  /// means we never trigger a Magisk prompt at display-mount time — if
  /// root was never probed, we treat the feature as unavailable.
  Future<bool> isSupported() async {
    try {
      final rootAvail = await _store.getRootAvailable();
      if (!rootAvail) return false;
      final fs = await _channel.invokeMethod<bool>('isSupported');
      return fs ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Snapshots current per-policy governor + max_freq, then writes
  /// powersave + per-policy min available freq. Returns true if at
  /// least one policy was successfully tuned. No-op (false) if
  /// [isSupported] is false. Never throws.
  Future<bool> enterPowersave() async {
    try {
      if (!await isSupported()) {
        debugPrint('CpuGovernor: unsupported (no root or no cpufreq)');
        return false;
      }
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'enterPowersave',
      );
      final ok = (result?['ok'] as bool?) ?? false;
      final policies = (result?['policies'] as int?) ?? 0;
      if (ok) {
        debugPrint('CpuGovernor: entered powersave ($policies policies)');
      } else {
        final err = result?['error'] as String?;
        debugPrint('CpuGovernor: enter failed: ${err ?? "unknown"}');
      }
      return ok;
    } catch (e) {
      debugPrint('CpuGovernor: enter threw: $e');
      return false;
    }
  }

  /// Restores the snapshot captured by the previous [enterPowersave].
  /// No-op (true) if no snapshot exists. Never throws.
  Future<bool> restore() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'restore',
      );
      final ok = (result?['ok'] as bool?) ?? false;
      final policies = (result?['policies'] as int?) ?? 0;
      if (ok) {
        debugPrint('CpuGovernor: restored ($policies policies)');
      } else {
        final err = result?['error'] as String?;
        debugPrint('CpuGovernor: restore failed: ${err ?? "unknown"}');
      }
      return ok;
    } catch (e) {
      debugPrint('CpuGovernor: restore threw: $e');
      return false;
    }
  }
}
