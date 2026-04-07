// Hermetic tests for WsClient.
//
// We never open a socket: a `_FakeChannel` exposes a stream controller the
// test pushes frames into and a sink that records writes. `fake_async`
// drives virtual time so we can assert the reconnect schedule (1s -> 2s ->
// ...) without actually waiting.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/config/config_model.dart';
import 'package:hyacinth/net/ws_client.dart';

class _FakeChannel implements WsConnection {
  _FakeChannel() : _controller = StreamController<dynamic>.broadcast();

  final StreamController<dynamic> _controller;
  final List<String> writes = <String>[];
  bool closed = false;

  void push(dynamic frame) => _controller.add(frame);
  void closeRemote() => _controller.close();

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  void send(String data) => writes.add(data);

  @override
  void close() {
    closed = true;
  }
}

void main() {
  test('config_update envelope invokes onConfigUpdate with parsed config',
      () async {
    final fake = _FakeChannel();
    HyacinthConfig? received;
    final ws = WsClient(
      baseUrl: 'http://server:8080',
      channelFactory: (_) => fake,
      onConfigUpdate: (cfg) => received = cfg,
    );
    ws.connect();
    fake.push(jsonEncode({
      'type': 'config_update',
      'config': {
        'content': 'https://x.example/',
        'contentRevision': 'r9',
        'brightness': 'auto',
        'screenTimeout': '30s',
      },
    }));
    await Future<void>.delayed(Duration.zero);
    expect(received, isNotNull);
    expect(received!.content, 'https://x.example/');
    expect(received!.contentRevision, 'r9');
    expect(received!.screenTimeout, '30s');
    ws.disconnect();
  });

  test('unknown envelope types are ignored (forward-compat)', () async {
    final fake = _FakeChannel();
    var calls = 0;
    final ws = WsClient(
      baseUrl: 'http://server:8080',
      channelFactory: (_) => fake,
      onConfigUpdate: (_) => calls++,
    );
    ws.connect();
    fake.push(jsonEncode({'type': 'something_new', 'data': 42}));
    fake.push(jsonEncode({'type': 'pong'}));
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);
    ws.disconnect();
  });

  test('reconnect backoff schedule is 1s then 2s on consecutive failures', () {
    fakeAsync((async) {
      final attempts = <DateTime>[];
      final ws = WsClient(
        baseUrl: 'http://server:8080',
        // Each attempt yields a fresh fake channel that immediately closes
        // its stream → triggers `_onClosed` → schedules a reconnect.
        channelFactory: (_) {
          attempts.add(DateTime.now());
          final ch = _FakeChannel();
          // Close on next microtask so the listener is in place first.
          scheduleMicrotask(() => ch.closeRemote());
          return ch;
        },
        onConfigUpdate: (_) {},
        // Disable jitter by passing a Random whose nextDouble returns 0.5
        // (→ jitterFraction = 0.0).
        random: _ZeroJitterRandom(),
      );
      ws.connect();
      async.flushMicrotasks();
      expect(attempts.length, 1);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(attempts.length, 2,
          reason: 'first reconnect should fire ~1s after first failure');

      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(attempts.length, 3,
          reason: 'second reconnect should fire ~2s after second failure');

      ws.disconnect();
    });
  });

  test('disconnect() cancels pending reconnect and ping timers', () {
    fakeAsync((async) {
      var attempts = 0;
      final ws = WsClient(
        baseUrl: 'http://server:8080',
        channelFactory: (_) {
          attempts++;
          final ch = _FakeChannel();
          scheduleMicrotask(() => ch.closeRemote());
          return ch;
        },
        onConfigUpdate: (_) {},
        random: _ZeroJitterRandom(),
      );
      ws.connect();
      async.flushMicrotasks();
      expect(attempts, 1);
      // The first failure has scheduled a 1s reconnect. Disconnect now.
      ws.disconnect();
      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();
      expect(attempts, 1,
          reason: 'no further reconnects should be attempted after disconnect');
    });
  });

  test('idle timeout fires reconnect when no traffic arrives', () {
    fakeAsync((async) {
      var attempts = 0;
      final ws = WsClient(
        baseUrl: 'http://server:8080',
        idleTimeout: const Duration(seconds: 5),
        pingInterval: const Duration(seconds: 60),
        channelFactory: (_) {
          attempts++;
          return _FakeChannel(); // never closes; we rely on idle timer
        },
        onConfigUpdate: (_) {},
        random: _ZeroJitterRandom(),
      );
      ws.connect();
      async.flushMicrotasks();
      expect(attempts, 1);
      async.elapse(const Duration(seconds: 5)); // idle fires
      async.elapse(const Duration(seconds: 1)); // backoff fires
      async.flushMicrotasks();
      expect(attempts, 2);
      ws.disconnect();
    });
  });
}

class _ZeroJitterRandom implements Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0.5; // → (0.5 * 0.4 - 0.2) = 0 jitter

  @override
  int nextInt(int max) => 0;
}
