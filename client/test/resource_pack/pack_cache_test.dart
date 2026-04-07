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
}
