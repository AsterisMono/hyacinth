import 'dart:async';

import 'package:flutter/services.dart';

/// Watches Android power-connected / power-disconnected broadcasts via the
/// `io.hyacinth/battery` MethodChannel and exposes them as a Dart stream.
///
/// M13: the channel is one-way native→Dart. The Kotlin side registers a
/// `BroadcastReceiver` for `ACTION_POWER_CONNECTED` /
/// `ACTION_POWER_DISCONNECTED` and pushes a `charging_changed` method
/// call with `{connected: bool}` on each transition. Dart never calls
/// back into the channel — there is no query for the current state
/// (restarting Hyacinth while already plugged in is rare enough that
/// the operator's manual screen-off is the fallback; M13 is purely a
/// transition listener).
///
/// Backed by a `StreamController.broadcast` so multiple listeners
/// (AppState today, a future HealthCheck row tomorrow) can subscribe.
/// Tests inject a `MethodChannel` via the constructor; production uses
/// the default const channel.
class BatteryWatcher {
  BatteryWatcher({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('io.hyacinth/battery') {
    _channel.setMethodCallHandler(_onChannelCall);
  }

  final MethodChannel _channel;
  final StreamController<bool> _controller =
      StreamController<bool>.broadcast();

  /// Emits `true` when the charger is just connected, `false` when just
  /// disconnected.
  Stream<bool> get onChargingChanged => _controller.stream;

  Future<dynamic> _onChannelCall(MethodCall call) async {
    if (call.method != 'charging_changed') return null;
    final args = call.arguments;
    if (args is Map) {
      final connected = args['connected'];
      if (connected is bool) {
        _controller.add(connected);
      }
    }
    return null;
  }

  /// Tear down the channel handler and the stream controller. Safe to
  /// call multiple times.
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}
