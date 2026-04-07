// Hermetic tests for ConfigClient. Uses package:http/testing's MockClient
// to inject canned responses, so we never open a real socket.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hyacinth/net/config_client.dart';

void main() {
  test('200 + valid JSON parses', () async {
    final client = ConfigClient(
      httpClient: MockClient((request) async {
        expect(request.url.path, '/config');
        return http.Response(
          '{"content":"https://example.com",'
          '"contentRevision":"r1",'
          '"brightness":"auto",'
          '"screenTimeout":"always-on"}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final cfg = await client.fetch('http://server:8080');
    expect(cfg.content, 'https://example.com');
    expect(cfg.contentRevision, 'r1');
  });

  test('non-200 throws', () async {
    final client = ConfigClient(
      httpClient: MockClient((_) async => http.Response('nope', 503)),
    );
    expect(
      () => client.fetch('http://server:8080'),
      throwsA(isA<Exception>()),
    );
  });

  test('malformed JSON throws', () async {
    final client = ConfigClient(
      httpClient: MockClient((_) async => http.Response('{not json', 200)),
    );
    expect(
      () => client.fetch('http://server:8080'),
      throwsA(anything),
    );
  });

  test('strips trailing slash from base URL', () async {
    Uri? seen;
    final client = ConfigClient(
      httpClient: MockClient((req) async {
        seen = req.url;
        return http.Response(
          '{"content":"x","contentRevision":"r","brightness":"auto",'
          '"screenTimeout":"always-on"}',
          200,
        );
      }),
    );
    await client.fetch('http://server:8080/');
    expect(seen?.toString(), 'http://server:8080/config');
  });

  test('slow server triggers TimeoutException with injected short timeout',
      () async {
    final client = ConfigClient(
      fetchTimeout: const Duration(milliseconds: 20),
      httpClient: MockClient((_) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return http.Response('{}', 200);
      }),
    );
    await expectLater(
      client.fetch('http://server:8080'),
      throwsA(isA<TimeoutException>()),
    );
  });
}
