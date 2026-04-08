import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/resource_pack/pack_cache.dart';
import 'package:hyacinth/resource_pack/pack_manifest.dart';

void main() {
  late Directory tmp;
  late PackCache cache;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hyacinth_pack_cache_');
    cache = PackCache(overrideRoot: tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  test('currentVersion returns null when no pack has been published', () async {
    expect(await cache.currentVersion('neko'), isNull);
    expect(await cache.currentContentFile('neko', 'image.png'), isNull);
    expect(await cache.currentManifest('neko'), isNull);
  });

  test('writeManifest + swapCurrent + currentManifest round-trip', () async {
    const m = PackManifest(
      id: 'neko',
      version: 1,
      type: 'png',
      filename: 'image.png',
      sha256: 'abc',
      size: 4,
      createdAt: '2026-04-07T10:00:00Z',
    );
    final f = await cache.stagingFile('neko', 1, 'image.png');
    await f.writeAsBytes(<int>[1, 2, 3, 4]);
    await cache.writeManifest('neko', 1, m);
    await cache.swapCurrent('neko', 1);

    expect(await cache.currentVersion('neko'), 1);
    final loaded = await cache.currentManifest('neko');
    expect(loaded, m);
    final content = await cache.currentContentFile('neko', 'image.png');
    expect(content, isNotNull);
    expect(await content!.readAsBytes(), <int>[1, 2, 3, 4]);
  });

  test('swapCurrent is atomic — no partial pointer file remains', () async {
    await cache.swapCurrent('a', 5);
    final root = await cache.root();
    final dir = Directory('${root.path}/a');
    final entries = await dir.list().toList();
    final names = entries.map((e) => e.uri.pathSegments.last).toList();
    expect(names, contains('current'));
    // The .tmp must NOT linger after a successful swap.
    expect(names, isNot(contains('current.tmp')));
    expect(await cache.currentVersion('a'), 5);
  });

  test('gc keeps the last N versions', () async {
    // Lay down versions 1..5 with a content file each.
    for (int v = 1; v <= 5; v++) {
      final f = await cache.stagingFile('p', v, 'image.png');
      await f.writeAsBytes(<int>[v]);
    }
    await cache.swapCurrent('p', 5);
    await cache.gc('p', keepLast: 2);

    final root = await cache.root();
    final dir = Directory('${root.path}/p');
    final survivors = <int>{};
    await for (final e in dir.list()) {
      if (e is Directory) {
        final n = int.tryParse(e.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last);
        if (n != null) survivors.add(n);
      }
    }
    // keepLast=2 plus the active version (5, already in the top 2 here).
    expect(survivors, equals({4, 5}));
  });

  test('currentContentFileByPath resolves nested paths', () async {
    // Lay out a fake "zip pack" by writing files at nested paths.
    final root = await cache.root();
    final base = '${root.path}/site/3/content';
    await Directory('$base/assets').create(recursive: true);
    await File('$base/index.html').writeAsString('<html></html>');
    await File('$base/assets/app.js').writeAsString('console.log(1)');
    await cache.swapCurrent('site', 3);

    final idx = await cache.currentContentFileByPath('site', 'index.html');
    expect(idx, isNotNull);
    expect(await idx!.readAsString(), '<html></html>');

    final js = await cache.currentContentFileByPath('site', 'assets/app.js');
    expect(js, isNotNull);
    expect(await js!.readAsString(), 'console.log(1)');
  });

  test('currentContentFileByPath rejects unsafe relative paths', () async {
    // Even a populated pack must reject traversal attempts.
    final f = await cache.stagingFile('p2', 1, 'index.html');
    await f.writeAsString('ok');
    await cache.swapCurrent('p2', 1);

    expect(await cache.currentContentFileByPath('p2', '../../etc/passwd'),
        isNull);
    expect(await cache.currentContentFileByPath('p2', '/abs.txt'), isNull);
    expect(await cache.currentContentFileByPath('p2', 'a\\b.txt'), isNull);
    expect(await cache.currentContentFileByPath('p2', ''), isNull);
    expect(await cache.currentContentFileByPath('p2', 'sub/../etc'), isNull);
  });

  test('isSafeRelPath unit', () {
    expect(isSafeRelPath('index.html'), isTrue);
    expect(isSafeRelPath('assets/app.js'), isTrue);
    expect(isSafeRelPath('a/b/c/d.txt'), isTrue);
    expect(isSafeRelPath(''), isFalse);
    expect(isSafeRelPath('../etc'), isFalse);
    expect(isSafeRelPath('a/../b'), isFalse);
    expect(isSafeRelPath('/abs'), isFalse);
    expect(isSafeRelPath('sub\\back'), isFalse);
    expect(isSafeRelPath('null\x00byte'), isFalse);
  });

  group('gcMissingPacks + wipeAll', () {
    Future<void> seedPack(String id) async {
      final f = await cache.stagingFile(id, 1, 'image.png');
      await f.writeAsBytes(<int>[1, 2, 3]);
      await cache.swapCurrent(id, 1);
    }

    test('gcMissingPacks deletes packs missing from liveIds', () async {
      await seedPack('a');
      await seedPack('b');
      await seedPack('c');

      final deleted = await cache.gcMissingPacks(<String>{'a', 'c'});
      expect(deleted, contains('b'));
      expect(deleted, hasLength(1));

      final root = await cache.root();
      final survivors = <String>{};
      await for (final e in root.list()) {
        if (e is Directory) {
          survivors.add(e.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .last);
        }
      }
      expect(survivors, equals(<String>{'a', 'c'}));
      expect(await cache.currentVersion('b'), isNull);
      expect(await cache.currentVersion('a'), 1);
      expect(await cache.currentVersion('c'), 1);
    });

    test('gcMissingPacks with preserveId keeps that pack even if absent',
        () async {
      await seedPack('a');
      await seedPack('b');

      final deleted =
          await cache.gcMissingPacks(<String>{}, preserveId: 'a');
      expect(deleted, equals(<String>['b']));

      expect(await cache.currentVersion('a'), 1,
          reason: 'preserveId must survive empty liveIds');
      expect(await cache.currentVersion('b'), isNull);
    });

    test('gcMissingPacks on an empty cache root is a no-op', () async {
      final deleted = await cache.gcMissingPacks(<String>{'anything'});
      expect(deleted, isEmpty);
    });

    test('wipeAll removes everything and recreates the root', () async {
      await seedPack('a');
      await seedPack('b');

      await cache.wipeAll();

      final root = await cache.root();
      expect(await root.exists(), isTrue,
          reason: 'wipeAll must recreate the root empty');
      final remaining = await root.list().toList();
      expect(remaining, isEmpty);
      expect(await cache.currentVersion('a'), isNull);
      expect(await cache.currentVersion('b'), isNull);
    });

    test('wipeAll on a missing root is a no-op and creates the root',
        () async {
      // Start by nuking the root behind the cache's back.
      final root = await cache.root();
      await root.delete(recursive: true);
      expect(await root.exists(), isFalse);

      await cache.wipeAll();

      final rebuilt = await cache.root();
      expect(await rebuilt.exists(), isTrue);
      final entries = await rebuilt.list().toList();
      expect(entries, isEmpty);
    });
  });

  test('gc retains the active version even if outside the keep window',
      () async {
    for (int v = 1; v <= 4; v++) {
      final f = await cache.stagingFile('p', v, 'image.png');
      await f.writeAsBytes(<int>[v]);
    }
    // Active = 1 (an old version pinned manually).
    await cache.swapCurrent('p', 1);
    await cache.gc('p', keepLast: 1);
    // keepLast=1 wants only {4}, but active=1 must also survive.
    final root = await cache.root();
    final dir = Directory('${root.path}/p');
    final survivors = <int>{};
    await for (final e in dir.list()) {
      if (e is Directory) {
        final n = int.tryParse(e.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last);
        if (n != null) survivors.add(n);
      }
    }
    expect(survivors, containsAll(<int>{1, 4}));
  });

  group('M8.4 listCachedPacks', () {
    Future<void> seedPack({
      required String id,
      required int version,
      required String type,
      required String filename,
      required List<int> bytes,
    }) async {
      final f = await cache.stagingFile(id, version, filename);
      await f.writeAsBytes(bytes);
      await cache.writeManifest(
        id,
        version,
        PackManifest(
          id: id,
          version: version,
          type: type,
          filename: filename,
          sha256: 'sha-$id',
          size: bytes.length,
          createdAt: '2026-04-08T00:00:00Z',
        ),
      );
      await cache.swapCurrent(id, version);
    }

    test('returns one entry per cached pack, sorted by id', () async {
      await seedPack(
        id: 'b-img',
        version: 1,
        type: 'png',
        filename: 'image.png',
        bytes: <int>[1, 2, 3, 4, 5],
      );
      await seedPack(
        id: 'a-zip',
        version: 2,
        type: 'zip',
        filename: 'index.html',
        bytes: List<int>.filled(2048, 0x42),
      );

      final infos = await cache.listCachedPacks();
      expect(infos.length, 2);
      // Sorted alphabetically by id.
      expect(infos[0].id, 'a-zip');
      expect(infos[0].version, 2);
      expect(infos[0].manifest.type, 'zip');
      expect(infos[0].sizeBytes, 2048);
      expect(infos[1].id, 'b-img');
      expect(infos[1].version, 1);
      expect(infos[1].manifest.type, 'png');
      expect(infos[1].sizeBytes, 5);
    });

    test('skips a pack dir whose current pointer is missing', () async {
      // Lay down a manifest + content but never call swapCurrent.
      final f = await cache.stagingFile('orphan', 1, 'image.png');
      await f.writeAsBytes(<int>[9, 9, 9]);
      await cache.writeManifest(
        'orphan',
        1,
        const PackManifest(
          id: 'orphan',
          version: 1,
          type: 'png',
          filename: 'image.png',
          sha256: 'h',
          size: 3,
          createdAt: 't',
        ),
      );
      // And one good pack so we can verify the listing isn't empty.
      await seedPack(
        id: 'good',
        version: 1,
        type: 'png',
        filename: 'image.png',
        bytes: <int>[7],
      );
      final infos = await cache.listCachedPacks();
      expect(infos.map((p) => p.id), <String>['good']);
    });

    test('skips a pack with malformed manifest.json', () async {
      // Force a current pointer to point at a version with broken JSON.
      final root = await cache.root();
      final packDir = Directory('${root.path}/broken');
      await Directory('${packDir.path}/1/content').create(recursive: true);
      await File('${packDir.path}/1/manifest.json').writeAsString('not json');
      await File('${packDir.path}/1/content/image.png')
          .writeAsBytes(<int>[1, 2, 3]);
      await File('${packDir.path}/current').writeAsString('1');
      // And a good neighbour.
      await seedPack(
        id: 'ok',
        version: 1,
        type: 'png',
        filename: 'image.png',
        bytes: <int>[1],
      );
      final infos = await cache.listCachedPacks();
      expect(infos.map((p) => p.id), <String>['ok']);
    });

    test('returns empty list when the cache root is empty', () async {
      final infos = await cache.listCachedPacks();
      expect(infos, isEmpty);
    });
  });
}
