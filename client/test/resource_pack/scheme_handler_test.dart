import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/resource_pack/pack_cache.dart';
import 'package:hyacinth/resource_pack/pack_manifest.dart';
import 'package:hyacinth/resource_pack/scheme_handler.dart';

WebResourceRequest _req(String url) {
  return WebResourceRequest(url: WebUri(url));
}

void main() {
  late Directory tmp;
  late PackCache cache;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hyacinth_scheme_');
    cache = PackCache(overrideRoot: tmp);
    // Pre-populate the cache with one pack.
    final f = await cache.stagingFile('neko', 1, 'image.png');
    await f.writeAsBytes(<int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
    await cache.writeManifest('neko', 1, const PackManifest(
      id: 'neko',
      version: 1,
      type: 'png',
      filename: 'image.png',
      sha256: 'h',
      size: 8,
      createdAt: 't',
    ));
    await cache.swapCurrent('neko', 1);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('resolves a cached pack file', () async {
    final resp = await resolveAppScheme(
      _req('app-scheme://pack/neko/image.png'),
      cache,
    );
    expect(resp, isNotNull);
    expect(resp!.contentType, 'image/png');
    expect(resp.data, <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
  });

  test('returns null for non-app-scheme requests', () async {
    final r = await resolveAppScheme(
      _req('https://example.com/foo'),
      cache,
    );
    expect(r, isNull);
  });

  test('returns null for unknown pack id', () async {
    final r = await resolveAppScheme(
      _req('app-scheme://pack/missing/image.png'),
      cache,
    );
    expect(r, isNull);
  });

  test('returns null when host is not "pack"', () async {
    final r = await resolveAppScheme(
      _req('app-scheme://other/foo/bar'),
      cache,
    );
    expect(r, isNull);
  });

  test('guessAppSchemeMime maps the common extensions', () {
    expect(guessAppSchemeMime('image.png'), 'image/png');
    expect(guessAppSchemeMime('PHOTO.JPG'), 'image/jpeg');
    expect(guessAppSchemeMime('hi.jpeg'), 'image/jpeg');
    expect(guessAppSchemeMime('a.webp'), 'image/webp');
    expect(guessAppSchemeMime('a.gif'), 'image/gif');
    expect(guessAppSchemeMime('mystery.bin'), 'application/octet-stream');
  });
}
