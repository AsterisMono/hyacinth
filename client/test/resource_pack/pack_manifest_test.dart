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
