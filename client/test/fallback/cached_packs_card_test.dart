import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/fallback/cached_packs_card.dart';
import 'package:hyacinth/resource_pack/pack_cache.dart';
import 'package:hyacinth/resource_pack/pack_manifest.dart';

void main() {
  late Directory tmp;
  late PackCache cache;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hyacinth_cached_packs_card_');
    cache = PackCache(overrideRoot: tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

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

  Future<void> mountAndSettle(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CachedPacksCard(cache: cache)),
      ),
    );
    // The FutureBuilder's future resolves on the next microtask
    // (listCachedPacks is sync inside an async wrapper). Two pumps —
    // one to drain microtasks, one to render the resolved state.
    // Avoids `pumpAndSettle`, which hangs on the M3 Card's elevation
    // tween animations.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('renders a row per cached pack with id and metadata',
      (tester) async {
    // seedPack uses real async filesystem I/O. testWidgets runs on a
    // fake clock by default, so the futures returned by Directory/File
    // operations never resolve unless we explicitly run them in
    // wall-clock time via `tester.runAsync`.
    await tester.runAsync(() async {
      await seedPack(
        id: 'neko',
        version: 1,
        type: 'png',
        filename: 'image.png',
        bytes: Uint8List(2048),
      );
      await seedPack(
        id: 'site',
        version: 3,
        type: 'zip',
        filename: 'index.html',
        bytes: Uint8List(4096),
      );
    });

    await mountAndSettle(tester);

    expect(find.text('Cached packs'), findsOneWidget);
    expect(find.text('neko'), findsOneWidget);
    expect(find.text('site'), findsOneWidget);
    expect(find.text('png v1 · 2.0 KiB'), findsOneWidget);
    expect(find.text('zip v3 · 4.0 KiB'), findsOneWidget);
  });

  testWidgets('shows the empty-state message when the cache is empty',
      (tester) async {
    await mountAndSettle(tester);

    expect(find.text('Cached packs'), findsOneWidget);
    expect(find.text('No packs cached yet'), findsOneWidget);
  });

  test('humanSize formats bytes / KiB / MiB / GiB', () {
    expect(humanSize(0), '0 B');
    expect(humanSize(512), '512 B');
    expect(humanSize(1024), '1.0 KiB');
    expect(humanSize(1536), '1.5 KiB');
    expect(humanSize(1024 * 1024), '1.00 MiB');
    expect(humanSize(5 * 1024 * 1024), '5.00 MiB');
    expect(humanSize(1024 * 1024 * 1024), '1.00 GiB');
  });
}
