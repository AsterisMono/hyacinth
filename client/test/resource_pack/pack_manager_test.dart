import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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

  // ---- Zip flow ------------------------------------------------------

  List<int> buildZip(Map<String, List<int>> files) {
    final a = Archive();
    files.forEach((name, bytes) {
      a.addFile(ArchiveFile.bytes(name, bytes));
    });
    final out = ZipEncoder().encode(a);
    return out;
  }

  PackManifest zipManifest({
    String id = 'site',
    int version = 1,
    required List<int> bytes,
  }) {
    return PackManifest(
      id: id,
      version: version,
      type: 'zip',
      filename: 'index.html',
      sha256: sha256.convert(bytes).toString(),
      size: bytes.length,
      createdAt: '2026-04-07T10:00:00Z',
    );
  }

  test('Zip + Wi-Fi + cold cache: downloads, validates, extracts, swaps',
      () async {
    final zb = buildZip({
      'index.html': 'hi'.codeUnits,
      'assets/app.js': 'let x=1;'.codeUnits,
    });
    final m = zipManifest(bytes: zb);
    final mgr = PackManager(
      serverBaseUrl: 'http://server',
      cache: cache,
      wifiGuard: _FakeWifi(true),
      httpClient: _serverClient(manifest: m, bytes: zb),
    );
    final got = await mgr.ensure('site');
    expect(got, m);
    expect(await cache.currentVersion('site'), 1);
    final idx = await cache.currentContentFileByPath('site', 'index.html');
    expect(idx, isNotNull);
    expect(await idx!.readAsString(), 'hi');
    final js = await cache.currentContentFileByPath('site', 'assets/app.js');
    expect(js, isNotNull);
    expect(await js!.readAsString(), 'let x=1;');
    // Staging dir must NOT linger.
    final staging = await cache.stagingVersionDir('site', 1);
    expect(await staging.exists(), isFalse);
  });

  test('Zip + missing index.html: throws PackArchiveInvalid, no swap',
      () async {
    final zb = buildZip({'main.js': 'x'.codeUnits});
    final m = zipManifest(bytes: zb);
    final mgr = PackManager(
      serverBaseUrl: 'http://server',
      cache: cache,
      wifiGuard: _FakeWifi(true),
      httpClient: _serverClient(manifest: m, bytes: zb),
    );
    await expectLater(
      mgr.ensure('site'),
      throwsA(isA<PackArchiveInvalid>()),
    );
    expect(await cache.currentVersion('site'), isNull);
    final staging = await cache.stagingVersionDir('site', 1);
    expect(await staging.exists(), isFalse);
  });

  test('Zip + path traversal: throws PackArchiveInvalid, no swap', () async {
    final zb = buildZip({
      'index.html': 'ok'.codeUnits,
      '../evil.txt': 'bad'.codeUnits,
    });
    final m = zipManifest(bytes: zb);
    final mgr = PackManager(
      serverBaseUrl: 'http://server',
      cache: cache,
      wifiGuard: _FakeWifi(true),
      httpClient: _serverClient(manifest: m, bytes: zb),
    );
    await expectLater(
      mgr.ensure('site'),
      throwsA(isA<PackArchiveInvalid>()),
    );
    expect(await cache.currentVersion('site'), isNull);
  });

  test('Zip + sha mismatch: throws PackChecksumMismatch, no swap',
      () async {
    final zb = buildZip({'index.html': 'ok'.codeUnits});
    // Lying manifest claims a wrong sha.
    final m = PackManifest(
      id: 'site',
      version: 1,
      type: 'zip',
      filename: 'index.html',
      sha256: '0' * 64,
      size: zb.length,
      createdAt: 't',
    );
    final mgr = PackManager(
      serverBaseUrl: 'http://server',
      cache: cache,
      wifiGuard: _FakeWifi(true),
      httpClient: _serverClient(manifest: m, bytes: zb),
    );
    await expectLater(
      mgr.ensure('site'),
      throwsA(isA<PackChecksumMismatch>()),
    );
    expect(await cache.currentVersion('site'), isNull);
    final staging = await cache.stagingVersionDir('site', 1);
    expect(await staging.exists(), isFalse,
        reason: 'staging must be cleaned up on sha mismatch');
  });

  group('syncToServer', () {
    Future<void> seed(String id) async {
      final f = await cache.stagingFile(id, 1, 'image.png');
      await f.writeAsBytes(<int>[1]);
      await cache.swapCurrent(id, 1);
    }

    Future<Set<String>> packDirs() async {
      final root = await cache.root();
      final names = <String>{};
      await for (final e in root.list()) {
        if (e is Directory) {
          names.add(e.uri.pathSegments.where((s) => s.isNotEmpty).last);
        }
      }
      return names;
    }

    test('deletes local packs that are missing from the server', () async {
      await seed('a');
      await seed('b');
      await seed('c');

      final client = MockClient((req) async {
        if (req.url.path == '/packs') {
          return http.Response(
            jsonEncode(<Map<String, dynamic>>[
              {'id': 'a', 'version': 1},
              {'id': 'c', 'version': 1},
            ]),
            200,
          );
        }
        return http.Response('nope', 404);
      });
      final mgr = PackManager(
        serverBaseUrl: 'http://server',
        cache: cache,
        wifiGuard: _FakeWifi(true),
        httpClient: client,
      );

      final deleted = await mgr.syncToServer();
      expect(deleted, equals(<String>['b']));
      expect(await packDirs(), equals(<String>{'a', 'c'}));
    });

    test('preserveId keeps the named pack even if missing server-side',
        () async {
      await seed('a');
      await seed('b');
      await seed('c');

      final client = MockClient((req) async {
        if (req.url.path == '/packs') {
          return http.Response(
            jsonEncode(<Map<String, dynamic>>[
              {'id': 'a', 'version': 1},
              {'id': 'c', 'version': 1},
            ]),
            200,
          );
        }
        return http.Response('nope', 404);
      });
      final mgr = PackManager(
        serverBaseUrl: 'http://server',
        cache: cache,
        wifiGuard: _FakeWifi(true),
        httpClient: client,
      );

      final deleted = await mgr.syncToServer(preserveId: 'b');
      expect(deleted, isEmpty);
      expect(await packDirs(), equals(<String>{'a', 'b', 'c'}));
    });

    test('HTTP 500 is a no-op — cache untouched', () async {
      await seed('a');
      await seed('b');

      final client = MockClient((req) async {
        return http.Response('boom', 500);
      });
      final mgr = PackManager(
        serverBaseUrl: 'http://server',
        cache: cache,
        wifiGuard: _FakeWifi(true),
        httpClient: client,
      );

      final deleted = await mgr.syncToServer();
      expect(deleted, isEmpty);
      expect(await packDirs(), equals(<String>{'a', 'b'}));
    });

    test('malformed body (not a list) is a no-op', () async {
      await seed('a');
      await seed('b');

      final client = MockClient((req) async {
        return http.Response('{"oops":true}', 200);
      });
      final mgr = PackManager(
        serverBaseUrl: 'http://server',
        cache: cache,
        wifiGuard: _FakeWifi(true),
        httpClient: client,
      );

      final deleted = await mgr.syncToServer();
      expect(deleted, isEmpty);
      expect(await packDirs(), equals(<String>{'a', 'b'}));
    });
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
