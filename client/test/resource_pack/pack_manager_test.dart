import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hyacinth/resource_pack/pack_cache.dart';
import 'package:hyacinth/resource_pack/pack_manager.dart';
import 'package:hyacinth/resource_pack/pack_manifest.dart';
import 'package:hyacinth/resource_pack/wifi_guard.dart';

class _FakeWifi extends WifiGuard {
  _FakeWifi(this.wifi) : super();
  bool wifi;
  @override
  Future<bool> isOnWifi() async => wifi;
  @override
  Stream<bool> onWifiChanged() => const Stream.empty();
}

PackManifest _manifest({
  String id = 'neko',
  int version = 1,
  required List<int> bytes,
}) {
  return PackManifest(
    id: id,
    version: version,
    type: 'png',
    filename: 'image.png',
    sha256: sha256.convert(bytes).toString(),
    size: bytes.length,
    createdAt: '2026-04-07T10:00:00Z',
  );
}

http.Client _serverClient({
  required PackManifest manifest,
  required List<int> bytes,
  void Function(String path)? onHit,
}) {
  return MockClient.streaming((req, body) async {
    onHit?.call(req.url.path);
    if (req.url.path.endsWith('/manifest')) {
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(manifest.toJson()))),
        200,
      );
    }
    if (req.url.path.endsWith('/download')) {
      return http.StreamedResponse(Stream.value(bytes), 200);
    }
    return http.StreamedResponse(const Stream.empty(), 404);
  });
}

void main() {
  late Directory tmp;
  late PackCache cache;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hyacinth_pack_mgr_');
    cache = PackCache(overrideRoot: tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('Wi-Fi + cold cache: downloads, verifies, swaps current', () async {
    final bytes = List<int>.generate(64, (i) => i);
    final m = _manifest(bytes: bytes);
    final mgr = PackManager(
      serverBaseUrl: 'http://server',
      cache: cache,
      wifiGuard: _FakeWifi(true),
      httpClient: _serverClient(manifest: m, bytes: bytes),
    );
    final got = await mgr.ensure('neko');
    expect(got, m);
    expect(await cache.currentVersion('neko'), 1);
    final f = await cache.currentContentFile('neko', 'image.png');
    expect(f, isNotNull);
    expect(await f!.readAsBytes(), bytes);
  });

  test('Wi-Fi + up-to-date cache: no download', () async {
    final bytes = List<int>.generate(32, (i) => i * 2);
    final m = _manifest(bytes: bytes);
    // Pre-populate the cache as if a previous ensure had succeeded.
    final f = await cache.stagingFile('neko', 1, 'image.png');
    await f.writeAsBytes(bytes);
    await cache.writeManifest('neko', 1, m);
    await cache.swapCurrent('neko', 1);

    int downloadHits = 0;
    final mgr = PackManager(
      serverBaseUrl: 'http://server',
      cache: cache,
      wifiGuard: _FakeWifi(true),
      httpClient: _serverClient(
        manifest: m,
        bytes: bytes,
        onHit: (p) {
          if (p.endsWith('/download')) downloadHits++;
        },
      ),
    );
    final got = await mgr.ensure('neko');
    expect(got, m);
    expect(downloadHits, 0,
        reason: 'cache is at the latest version — no download should be made');
  });

  test('Wi-Fi + stale cache: downloads new version and swaps', () async {
    final v1 = List<int>.generate(8, (i) => i);
    final m1 = _manifest(bytes: v1, version: 1);
    final f = await cache.stagingFile('neko', 1, 'image.png');
    await f.writeAsBytes(v1);
    await cache.writeManifest('neko', 1, m1);
    await cache.swapCurrent('neko', 1);

    final v2 = List<int>.generate(16, (i) => 0xFF - i);
    final m2 = _manifest(bytes: v2, version: 2);

    final mgr = PackManager(
      serverBaseUrl: 'http://server',
      cache: cache,
      wifiGuard: _FakeWifi(true),
      httpClient: _serverClient(manifest: m2, bytes: v2),
    );
    final got = await mgr.ensure('neko');
    expect(got.version, 2);
    expect(await cache.currentVersion('neko'), 2);
    final newFile = await cache.currentContentFile('neko', 'image.png');
    expect(await newFile!.readAsBytes(), v2);
  });

  test('Mobile + cached version: returns cached without network', () async {
    final bytes = List<int>.generate(8, (i) => i);
    final m = _manifest(bytes: bytes);
    final f = await cache.stagingFile('neko', 1, 'image.png');
    await f.writeAsBytes(bytes);
    await cache.writeManifest('neko', 1, m);
    await cache.swapCurrent('neko', 1);

    final mgr = PackManager(
      serverBaseUrl: 'http://server',
      cache: cache,
      wifiGuard: _FakeWifi(false),
      httpClient: MockClient((_) async {
        throw StateError('mobile path must not hit the network');
      }),
    );
    final got = await mgr.ensure('neko');
    expect(got, m);
  });

  test('Mobile + cold cache: throws PackUnavailable', () async {
    final mgr = PackManager(
      serverBaseUrl: 'http://server',
      cache: cache,
      wifiGuard: _FakeWifi(false),
      httpClient: MockClient((_) async => http.Response('nope', 500)),
    );
    await expectLater(
      mgr.ensure('neko'),
      throwsA(isA<PackUnavailable>()),
    );
  });

  test('Wi-Fi + sha mismatch: throws PackChecksumMismatch, no swap',
      () async {
    final bytes = List<int>.generate(64, (i) => i);
    // Manifest claims a wrong sha256 — server actually returns `bytes`.
    final lying = PackManifest(
      id: 'neko',
      version: 1,
      type: 'png',
      filename: 'image.png',
      sha256: '0' * 64,
      size: bytes.length,
      createdAt: 't',
    );
    final mgr = PackManager(
      serverBaseUrl: 'http://server',
      cache: cache,
      wifiGuard: _FakeWifi(true),
      httpClient: _serverClient(manifest: lying, bytes: bytes),
    );
    await expectLater(
      mgr.ensure('neko'),
      throwsA(isA<PackChecksumMismatch>()),
    );
    expect(await cache.currentVersion('neko'), isNull,
        reason: 'no swap should occur on a mismatch');
  });
}
