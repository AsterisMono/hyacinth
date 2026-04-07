import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/config_model.dart';

/// Minimal wire-level abstraction over a WebSocket connection. Production
/// wraps `WebSocketChannel` (see [_defaultFactory]); tests implement this
/// directly with a `StreamController` + a list-backed sink so we never open
/// a real socket and can deterministically push frames into the client.
abstract class WsConnection {
  Stream<dynamic> get stream;
  void send(String data);
  void close();
}

class _WebSocketChannelConnection implements WsConnection {
  _WebSocketChannelConnection(this._channel);
  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  void close() {
    try {
      _channel.sink.close();
    } catch (_) {}
  }
}

/// Factory used by [WsClient] to mint a fresh transport per attempt. The
/// reconnect loop calls this on every retry.
typedef WsChannelFactory = WsConnection Function(Uri url);

WsConnection _defaultFactory(Uri url) =>
    _WebSocketChannelConnection(WebSocketChannel.connect(url));

/// Live config push channel.
///
/// Maintains a single WebSocket connection to `<base>/ws`, calls
/// [onConfigUpdate] whenever the server sends a `config_update` envelope,
/// and reconnects with exponential backoff + jitter when the connection
/// drops. A 20s ping is sent on the active connection; if no message is
/// observed for 45s the channel is force-closed and reconnect kicks in.
///
/// All timer scheduling goes through [Timer]/[Future.delayed] (no manual
/// `Stopwatch` polling) so that `package:fake_async` can drive virtual time
/// in tests without sleeping the test runner.
class WsClient {
  WsClient({
    required String baseUrl,
    required this.onConfigUpdate,
    WsChannelFactory? channelFactory,
    Duration pingInterval = const Duration(seconds: 20),
    Duration idleTimeout = const Duration(seconds: 45),
    Duration initialBackoff = const Duration(seconds: 1),
    Duration maxBackoff = const Duration(seconds: 30),
    Random? random,
  })  : _url = _wsUrlFor(baseUrl),
        _factory = channelFactory ?? _defaultFactory,
        _pingInterval = pingInterval,
        _idleTimeout = idleTimeout,
        _initialBackoff = initialBackoff,
        _maxBackoff = maxBackoff,
        _random = random ?? Random();

  final Uri _url;
  final WsChannelFactory _factory;
  final void Function(HyacinthConfig) onConfigUpdate;
  final Duration _pingInterval;
  final Duration _idleTimeout;
  final Duration _initialBackoff;
  final Duration _maxBackoff;
  final Random _random;

  WsConnection? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Timer? _idleTimer;
  Timer? _reconnectTimer;
  Duration _nextBackoff = const Duration(seconds: 1);
  bool _disposed = false;
  bool _hasReceivedMessage = false;

  /// Most recent backoff actually scheduled. Tests use this to assert the
  /// 1s/2s/4s schedule.
  Duration get debugLastScheduledBackoff => _lastScheduled;
  Duration _lastScheduled = Duration.zero;

  /// Whether [connect] has set up an active stream subscription. Used by
  /// tests after pushing fake frames to verify the live path took effect.
  bool get isConnected => _sub != null;

  /// True after [disconnect] has been called. Test seam used by AppState
  /// tests to verify the WS client gets torn down on phase changes.
  bool get isDisposed => _disposed;

  /// Establishes the connection. If it fails synchronously the reconnect
  /// loop is armed.
  void connect() {
    _disposed = false;
    _nextBackoff = _initialBackoff;
    _openOnce();
  }

  /// Tears everything down. Safe to call multiple times. After this returns
  /// no further reconnect attempts will be scheduled.
  void disconnect() {
    _disposed = true;
    _cancelTimers();
    _sub?.cancel();
    _sub = null;
    _channel?.close();
    _channel = null;
  }

  void _cancelTimers() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _openOnce() {
    if (_disposed) return;
    _hasReceivedMessage = false;
    try {
      final ch = _factory(_url);
      _channel = ch;
      _sub = ch.stream.listen(
        _onMessage,
        onError: (_) => _onClosed(),
        onDone: _onClosed,
        cancelOnError: true,
      );
      _armPing();
      _armIdle();
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _armPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      try {
        _channel?.send(jsonEncode(<String, String>{'type': 'ping'}));
      } catch (_) {
        _onClosed();
      }
    });
  }

  void _armIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, () {
      // No frame in 45s — force a reconnect.
      _onClosed();
    });
  }

  void _onMessage(dynamic raw) {
    if (_disposed) return;
    // Any traffic resets the idle deadline AND signals the connection is
    // good enough to reset the backoff schedule.
    _hasReceivedMessage = true;
    _nextBackoff = _initialBackoff;
    _armIdle();

    Map<String, dynamic> env;
    try {
      env = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>))
          as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = env['type'];
    if (type == 'config_update') {
      final cfg = env['config'];
      if (cfg is Map<String, dynamic>) {
        try {
          onConfigUpdate(HyacinthConfig.fromJson(cfg));
        } catch (_) {
          // Forward-compat: a malformed config payload should not crash
          // the WS client.
        }
      }
    }
    // Unknown envelope types are ignored on purpose (forward compat per
    // plan.md L121).
  }

  void _onClosed() {
    if (_disposed) return;
    _sub?.cancel();
    _sub = null;
    _channel?.close();
    _channel = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    final base = _nextBackoff;
    // ±20% jitter.
    final jitterFraction = (_random.nextDouble() * 0.4) - 0.2;
    final jittered = Duration(
      microseconds:
          (base.inMicroseconds * (1.0 + jitterFraction)).round().clamp(
                1,
                _maxBackoff.inMicroseconds * 2,
              ),
    );
    _lastScheduled = jittered;
    _reconnectTimer = Timer(jittered, _openOnce);
    // Double for next failure, capped.
    final doubled = base * 2;
    _nextBackoff = doubled > _maxBackoff ? _maxBackoff : doubled;
    // If the previous attempt actually received a frame we already reset
    // back to initial in _onMessage, so this doubling only applies to
    // consecutive failures (failures with no message between them).
    if (_hasReceivedMessage) {
      _nextBackoff = _initialBackoff;
    }
  }

  static Uri _wsUrlFor(String base) {
    final trimmed = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final parsed = Uri.parse(trimmed);
    final scheme = parsed.scheme == 'https' ? 'wss' : 'ws';
    return parsed.replace(scheme: scheme, path: '${parsed.path}/ws');
  }
}
