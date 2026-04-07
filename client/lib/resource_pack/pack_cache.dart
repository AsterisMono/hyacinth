import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'pack_manifest.dart';

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

  /// Returns the active content file for [packId] / [filename], or `null`
  /// if no current version exists or the file is missing.
  Future<File?> currentContentFile(String packId, String filename) async {
    final v = await currentVersion(packId);
    if (v == null) return null;
    final dir = await _packDir(packId);
    final f = File('${dir.path}/$v/content/$filename');
    if (!await f.exists()) return null;
    return f;
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
