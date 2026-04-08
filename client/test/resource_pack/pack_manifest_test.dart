import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/resource_pack/pack_manifest.dart';

void main() {
  group('PackManifest', () {
    test('fromJson populates every field', () {
      final m = PackManifest.fromJson(<String, dynamic>{
        'id': 'neko',
        'version': 7,
        'type': 'png',
        'filename': 'image.png',
        'sha256': 'deadbeef',
        'size': 4096,
        'createdAt': '2026-04-07T10:15:00Z',
      });
      expect(m.id, 'neko');
      expect(m.version, 7);
      expect(m.type, 'png');
      expect(m.filename, 'image.png');
      expect(m.sha256, 'deadbeef');
      expect(m.size, 4096);
      expect(m.createdAt, '2026-04-07T10:15:00Z');
    });

    test('value equality and hashCode round-trip', () {
      const a = PackManifest(
        id: 'a',
        version: 1,
        type: 'png',
        filename: 'image.png',
        sha256: 'h',
        size: 10,
        createdAt: 't',
      );
      const b = PackManifest(
        id: 'a',
        version: 1,
        type: 'png',
        filename: 'image.png',
        sha256: 'h',
        size: 10,
        createdAt: 't',
      );
      const c = PackManifest(
        id: 'a',
        version: 2,
        type: 'png',
        filename: 'image.png',
        sha256: 'h',
        size: 10,
        createdAt: 't',
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a == c, isFalse);
    });

    test('toJson is the inverse of fromJson', () {
      const m = PackManifest(
        id: 'rt',
        version: 3,
        type: 'webp',
        filename: 'image.webp',
        sha256: 'abc',
        size: 5,
        createdAt: '2026-04-07T10:00:00Z',
      );
      expect(PackManifest.fromJson(m.toJson()), m);
    });

    // M16 — isVideo flag drives DisplayPage's renderer selection.
    test('isVideo true for mp4, false for image / zip', () {
      const mp4 = PackManifest(
        id: 'loop',
        version: 1,
        type: 'mp4',
        filename: 'video.mp4',
        sha256: 'a',
        size: 100,
        createdAt: 't',
      );
      expect(mp4.isVideo, isTrue);
      expect(mp4.isZip, isFalse);

      const png = PackManifest(
        id: 'cat',
        version: 1,
        type: 'png',
        filename: 'image.png',
        sha256: 'b',
        size: 50,
        createdAt: 't',
      );
      expect(png.isVideo, isFalse);

      const zip = PackManifest(
        id: 'site',
        version: 1,
        type: 'zip',
        filename: 'index.html',
        sha256: 'c',
        size: 200,
        createdAt: 't',
      );
      expect(zip.isVideo, isFalse);
    });

    test('toString includes the id and version', () {
      const m = PackManifest(
        id: 'k',
        version: 9,
        type: 'gif',
        filename: 'image.gif',
        sha256: '',
        size: 0,
        createdAt: '',
      );
      final s = m.toString();
      expect(s, contains('k'));
      expect(s, contains('9'));
    });
  });
}
