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
    final resp = await resolveHyacinthScheme(
      _req('hyacinth://pack/neko/image.png'),
      cache,
    );
    expect(resp, isNotNull);
    expect(resp!.contentType, 'image/png');
    expect(resp.data, <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
  });

  test('returns null for non-hyacinth requests', () async {
    final r = await resolveHyacinthScheme(
      _req('https://example.com/foo'),
      cache,
    );
    expect(r, isNull);
  });

  test('returns null for unknown pack id', () async {
    final r = await resolveHyacinthScheme(
      _req('hyacinth://pack/missing/image.png'),
      cache,
    );
    expect(r, isNull);
  });

  test('returns null when host is not "pack"', () async {
    final r = await resolveHyacinthScheme(
      _req('hyacinth://other/foo/bar'),
      cache,
    );
    expect(r, isNull);
  });

  test('guessHyacinthSchemeMime maps the common extensions', () {
    expect(guessHyacinthSchemeMime('image.png'), 'image/png');
    expect(guessHyacinthSchemeMime('PHOTO.JPG'), 'image/jpeg');
    expect(guessHyacinthSchemeMime('hi.jpeg'), 'image/jpeg');
    expect(guessHyacinthSchemeMime('a.webp'), 'image/webp');
    expect(guessHyacinthSchemeMime('a.gif'), 'image/gif');
    expect(guessHyacinthSchemeMime('mystery.bin'), 'application/octet-stream');
  });

  test('guessHyacinthSchemeMime maps zip-pack types', () {
    expect(guessHyacinthSchemeMime('index.html'), 'text/html');
    expect(guessHyacinthSchemeMime('assets/app.css'), 'text/css');
    expect(guessHyacinthSchemeMime('assets/app.js'), 'application/javascript');
    expect(guessHyacinthSchemeMime('app.mjs'), 'application/javascript');
    expect(guessHyacinthSchemeMime('data.json'), 'application/json');
    expect(guessHyacinthSchemeMime('icon.svg'), 'image/svg+xml');
    expect(guessHyacinthSchemeMime('favicon.ico'), 'image/x-icon');
    expect(guessHyacinthSchemeMime('font.woff2'), 'font/woff2');
    expect(guessHyacinthSchemeMime('font.woff'), 'font/woff');
    expect(guessHyacinthSchemeMime('font.ttf'), 'font/ttf');
    expect(guessHyacinthSchemeMime('font.otf'), 'font/otf');
    expect(guessHyacinthSchemeMime('clip.mp4'), 'video/mp4');
    expect(guessHyacinthSchemeMime('clip.webm'), 'video/webm');
    expect(guessHyacinthSchemeMime('readme.txt'), 'text/plain');
  });

  test('resolves a nested zip-pack file', () async {
    // Lay down a "site" pack with a nested asset.
    final root = await cache.root();
    final base = '${root.path}/site/1/content';
    await Directory('$base/assets').create(recursive: true);
    await File('$base/index.html').writeAsString('<html>hi</html>');
    await File('$base/assets/app.js').writeAsString('let x=1;');
    await cache.swapCurrent('site', 1);

    final idx = await resolveHyacinthScheme(
      _req('hyacinth://pack/site/index.html'),
      cache,
    );
    expect(idx, isNotNull);
    expect(idx!.contentType, 'text/html');

    final js = await resolveHyacinthScheme(
      _req('hyacinth://pack/site/assets/app.js'),
      cache,
    );
    expect(js, isNotNull);
    expect(js!.contentType, 'application/javascript');
    expect(String.fromCharCodes(js.data), 'let x=1;');
  });

  test('returns null for unsafe nested rel path', () async {
    final r = await resolveHyacinthScheme(
      _req('hyacinth://pack/neko/..%2Fevil.txt'),
      cache,
    );
    expect(r, isNull);
  });

  test('returns null when only the pack id is given (no file)', () async {
    final r = await resolveHyacinthScheme(
      _req('hyacinth://pack/neko'),
      cache,
    );
    expect(r, isNull);
  });
}
