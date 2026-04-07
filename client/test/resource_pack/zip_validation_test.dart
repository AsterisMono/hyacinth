import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/resource_pack/zip_validation.dart';

Archive _archive(Map<String, List<int>> files) {
  final a = Archive();
  files.forEach((name, bytes) {
    a.addFile(ArchiveFile.bytes(name, bytes));
  });
  return a;
}

void main() {
  test('happy path: index.html + assets passes', () {
    final a = _archive({
      'index.html': [1, 2, 3],
      'assets/app.js': [4, 5],
      'assets/app.css': [6],
    });
    expect(validateArchive(a), isNull);
  });

  test('rejects empty archive', () {
    expect(validateArchive(Archive()), 'empty archive');
  });

  test('rejects archive without index.html at root', () {
    final a = _archive({
      'main.js': [1],
      'sub/index.html': [2], // not at root
    });
    expect(validateArchive(a), contains('missing index.html'));
  });

  test('accepts case-insensitive INDEX.HTML', () {
    final a = _archive({'INDEX.HTML': [1]});
    expect(validateArchive(a), isNull);
  });

  test('rejects path traversal', () {
    for (final bad in [
      '../escape.txt',
      'a/../../etc/passwd',
      '/absolute.txt',
      'with\\backslash.txt',
    ]) {
      final a = _archive({'index.html': [1], bad: [2]});
      final err = validateArchive(a);
      expect(err, isNotNull, reason: 'should reject $bad');
      expect(err, contains('unsafe entry'));
    }
  });

  test('rejects oversized single entry', () {
    final big = List<int>.filled(maxZipEntryUncompr + 1, 0);
    final a = _archive({'index.html': [1], 'big.bin': big});
    expect(validateArchive(a), contains('exceeds'));
  });

  test('rejects total uncompressed exceeding cap', () {
    // 5 chunks just under per-entry cap = > 200 MiB total.
    final chunk = List<int>.filled(maxZipEntryUncompr - 1, 0);
    final files = <String, List<int>>{'index.html': [1]};
    for (int i = 0; i < 5; i++) {
      files['blob-$i.bin'] = chunk;
    }
    final a = _archive(files);
    final err = validateArchive(a);
    expect(err, isNotNull);
    expect(err, contains('uncompressed total'));
  });

  test('rejects too many entries', () {
    final files = <String, List<int>>{'index.html': [1]};
    for (int i = 0; i < maxZipEntries + 5; i++) {
      files['f$i.txt'] = [0];
    }
    final a = _archive(files);
    expect(validateArchive(a), contains('too many entries'));
  });
}
