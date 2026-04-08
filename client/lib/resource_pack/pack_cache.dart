import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'pack_manifest.dart';

/// Mirrors the server's `isSafeRelPath`. Rejects relative paths that
/// could escape a pack's `content/` directory or that contain control
/// characters. Used both by [PackCache.currentContentFileByPath] and by
/// the zip extractor in `pack_manager.dart`.
bool isSafeRelPath(String relPath) {
  if (relPath.isEmpty) return false;
  if (relPath.contains('\\') || relPath.contains('\x00')) return false;
  if (relPath.startsWith('/')) return false;
  for (final seg in relPath.split('/')) {
    if (seg == '..') return false;
  }
  return true;
}

/// On-disk pack cache. Layout under [root]:
///
/// ```
/// packs/<pack_id>/
///   current             # text file: active version number
///   <version>/
///     manifest.json
///     content/
///       image.<ext>
/// ```
///
/// Atomicity rules:
///   - Writes go to a `.tmp` sibling and are committed via `File.rename`.
///   - The `current` pointer is the only file the WebView ever reads
///     through, and it is rewritten last so a half-finished download can
///     never be served.
///   - [gc] keeps the last `keepLast` versions per pack so the previous
///     version is available for rollback.
class PackCache {
  PackCache({Directory? overrideRoot}) : _overrideRoot = overrideRoot;

  /// Test seam: when non-null, [root] returns this directory directly
  /// instead of consulting `path_provider`.
  final Directory? _overrideRoot;

  Directory? _cachedRoot;

  /// Returns (and creates) the top-level pack-cache directory.
  Future<Directory> root() async {
    if (_cachedRoot != null) return _cachedRoot!;
    final base = _overrideRoot ?? await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/packs');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cachedRoot = dir;
    return dir;
  }

  /// Returns the directory for [packId], creating it if missing.
  Future<Directory> _packDir(String packId) async {
    final r = await root();
    final dir = Directory('${r.path}/$packId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Returns the version recorded in the `current` pointer file, or
  /// `null` if no version has been published yet.
  Future<int?> currentVersion(String packId) async {
    final dir = await _packDir(packId);
    final f = File('${dir.path}/current');
    if (!await f.exists()) return null;
    final raw = (await f.readAsString()).trim();
    return int.tryParse(raw);
  }

  /// Returns the active content file at the given relative path under
  /// the pack's `content/` dir, or `null` if no current version exists,
  /// the file is missing, or [relPath] is unsafe (contains `..`, leading
  /// `/`, backslash, or null byte).
  ///
  /// For image packs the relative path is the bare filename
  /// (e.g. `image.png`). For zip packs it can include nested directories
  /// (e.g. `assets/index-abc.js`).
  Future<File?> currentContentFileByPath(String packId, String relPath) async {
    if (!isSafeRelPath(relPath)) return null;
    final v = await currentVersion(packId);
    if (v == null) return null;
    final dir = await _packDir(packId);
    final f = File('${dir.path}/$v/content/$relPath');
    if (!await f.exists()) return null;
    return f;
  }

  /// Convenience wrapper retained for the M5 single-file (image) call
  /// sites. Equivalent to [currentContentFileByPath] with [filename] as
  /// the relative path.
  Future<File?> currentContentFile(String packId, String filename) {
    return currentContentFileByPath(packId, filename);
  }

  /// Returns the manifest file for the active version of [packId], or
  /// `null` if no current version exists.
  Future<PackManifest?> currentManifest(String packId) async {
    final v = await currentVersion(packId);
    if (v == null) return null;
    final dir = await _packDir(packId);
    final f = File('${dir.path}/$v/manifest.json');
    if (!await f.exists()) return null;
    final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    return PackManifest.fromJson(json);
  }

  /// Returns the destination [File] for staging a freshly-downloaded
  /// payload at [packId]/[version]/content/[filename]. Parent directories
  /// are created on demand. The returned file may already exist (and will
  /// be overwritten) — caller is responsible for opening for write.
  Future<File> stagingFile(String packId, int version, String filename) async {
    final dir = await _packDir(packId);
    final contentDir = Directory('${dir.path}/$version/content');
    if (!await contentDir.exists()) {
      await contentDir.create(recursive: true);
    }
    return File('${contentDir.path}/$filename');
  }

  /// Returns the canonical version directory `<packDir>/<version>` for
  /// the given pack. Used by the zip pipeline to compute the rename
  /// target. Does NOT create the directory.
  Future<Directory> versionDir(String packId, int version) async {
    final dir = await _packDir(packId);
    return Directory('${dir.path}/$version');
  }

  /// Returns the staging directory `<packDir>/<version>.staging` for
  /// the given pack. Used by the zip pipeline so the entire freshly-
  /// downloaded tree can be flipped into place via a single
  /// directory-rename. Does NOT create the directory — callers are
  /// expected to wipe + create as needed.
  Future<Directory> stagingVersionDir(String packId, int version) async {
    final dir = await _packDir(packId);
    return Directory('${dir.path}/$version.staging');
  }

  /// Persists [m] as the manifest.json for [packId]/[version]. Atomic
  /// (writes via `.tmp` + rename).
  Future<void> writeManifest(String packId, int version, PackManifest m) async {
    final dir = await _packDir(packId);
    final versionDir = Directory('${dir.path}/$version');
    if (!await versionDir.exists()) {
      await versionDir.create(recursive: true);
    }
    final dest = File('${versionDir.path}/manifest.json');
    final tmp = File('${dest.path}.tmp');
    await tmp.writeAsString(jsonEncode(m.toJson()), flush: true);
    await tmp.rename(dest.path);
  }

  /// Atomically swaps the `current` pointer to [newVersion]. Implemented
  /// as a tmp+rename so a crash mid-write can never produce a partial
  /// pointer file.
  Future<void> swapCurrent(String packId, int newVersion) async {
    final dir = await _packDir(packId);
    final dest = File('${dir.path}/current');
    final tmp = File('${dest.path}.tmp');
    await tmp.writeAsString('$newVersion', flush: true);
    await tmp.rename(dest.path);
  }

  /// Deletes every pack directory under [root] whose id is NOT in
  /// [liveIds]. If [preserveId] is non-null, that single pack id is
  /// kept regardless of whether it appears in [liveIds] — used by the
  /// auto-sync path so a transient operator delete doesn't immediately
  /// yank the currently-displayed pack.
  ///
  /// Returns the list of pack ids that were actually deleted.
  Future<List<String>> gcMissingPacks(
    Set<String> liveIds, {
    String? preserveId,
  }) async {
    final r = await root();
    if (!await r.exists()) return const <String>[];
    final deleted = <String>[];
    await for (final entry in r.list()) {
      if (entry is! Directory) continue;
      final segs = entry.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .toList();
      if (segs.isEmpty) continue;
      final id = segs.last;
      if (liveIds.contains(id)) continue;
      if (id == preserveId) continue;
      await entry.delete(recursive: true);
      deleted.add(id);
    }
    return deleted;
  }

  /// Removes the entire pack root, then recreates it empty. Used by the
  /// "Clear pack cache" button in the fallback Settings.
  Future<void> wipeAll() async {
    final r = await root();
    if (await r.exists()) {
      await r.delete(recursive: true);
    }
    // Recreate empty so subsequent operations don't have to special-case
    // the missing-root path.
    await r.create(recursive: true);
  }

  /// Garbage-collects old versions of [packId], keeping the [keepLast]
  /// highest version numbers. The active version (per `current`) is
  /// always retained even if it would otherwise fall outside the window.
  Future<void> gc(String packId, {int keepLast = 2}) async {
    final dir = await _packDir(packId);
    final active = await currentVersion(packId);
    final versions = <int>[];
    await for (final entry in dir.list()) {
      if (entry is Directory) {
        final name = entry.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last;
        final n = int.tryParse(name);
        if (n != null && n > 0) versions.add(n);
      }
    }
    versions.sort((a, b) => b.compareTo(a));
    if (versions.length <= keepLast) return;
    final keep = versions.take(keepLast).toSet();
    if (active != null) keep.add(active);
    for (final v in versions) {
      if (keep.contains(v)) continue;
      final d = Directory('${dir.path}/$v');
      if (await d.exists()) {
        await d.delete(recursive: true);
      }
    }
  }
}
