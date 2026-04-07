import 'package:archive/archive.dart';

import 'pack_cache.dart' show isSafeRelPath;

/// Caps mirrored from `server/packs.go` so a corrupt or malicious pack
/// can't be installed even if the server is compromised. The numbers
/// match the server constants — keep these in sync.
const int maxZipUncompressed = 200 * 1024 * 1024; // 200 MiB
const int maxZipEntryUncompr = 50 * 1024 * 1024; //  50 MiB
const int maxZipEntries = 5000;

/// Pure-function validator for a decoded [Archive]. Returns `null` when
/// the archive is acceptable, or a human-readable failure reason. The
/// rules mirror `server/packs.go::validateZipEntries`:
///
///   - non-empty
///   - has `index.html` (case-insensitive) at the archive root
///   - no entry with a path that fails [isSafeRelPath] (no `..`, leading
///     `/`, backslash, or null byte)
///   - no entry larger than [maxZipEntryUncompr] uncompressed
///   - total uncompressed size ≤ [maxZipUncompressed]
///   - at most [maxZipEntries] entries
String? validateArchive(Archive archive) {
  final files = archive.files;
  if (files.isEmpty) return 'empty archive';
  if (files.length > maxZipEntries) {
    return 'too many entries (${files.length} > $maxZipEntries)';
  }
  var total = 0;
  var hasIndex = false;
  for (final f in files) {
    if (f.name.isEmpty) return 'entry with empty name';
    if (!isSafeRelPath(f.name)) return 'unsafe entry name "${f.name}"';
    if (f.size > maxZipEntryUncompr) {
      return 'entry "${f.name}" exceeds $maxZipEntryUncompr bytes';
    }
    total += f.size;
    if (total > maxZipUncompressed) {
      return 'uncompressed total exceeds $maxZipUncompressed bytes';
    }
    if (f.isFile && f.name.toLowerCase() == 'index.html') {
      hasIndex = true;
    }
  }
  if (!hasIndex) return 'missing index.html at archive root';
  return null;
}
