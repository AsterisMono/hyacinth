import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'pack_cache.dart';
import 'pack_manifest.dart';
import 'wifi_guard.dart';
import 'zip_validation.dart';

/// Thrown when [PackManager.ensure] cannot satisfy the request because the
/// pack is not in cache and the device is not on Wi-Fi (or any other
/// non-recoverable "no bytes available" condition).
class PackUnavailable implements Exception {
  PackUnavailable(this.message);
  final String message;
  @override
  String toString() => 'PackUnavailable: $message';
}

/// Thrown when the downloaded payload's sha256 does not match the
/// manifest. The staging file is deleted and the active `current` pointer
/// is left untouched.
class PackChecksumMismatch implements Exception {
  PackChecksumMismatch({required this.expected, required this.actual});
  final String expected;
  final String actual;
  @override
  String toString() =>
      'PackChecksumMismatch: expected $expected, got $actual';
}

/// Thrown when a downloaded zip pack fails client-side validation
/// (missing index.html at the root, path traversal, oversized entry,
/// too many entries, or zip-bomb total). The staging directory is wiped
/// and the active `current` pointer is left untouched.
class PackArchiveInvalid implements Exception {
  PackArchiveInvalid(this.message);
  final String message;
  @override
  String toString() => 'PackArchiveInvalid: $message';
}

/// Orchestrates "make sure pack `<id>` is locally available at the latest
/// version". The flow is, on Wi-Fi:
///
///   1. GET `<base>/packs/<id>/manifest`
///   2. If our local `current` already matches the remote version → return
///      the cached manifest.
///   3. Otherwise GET `<base>/packs/<id>/download`, stream to a staging
///      file, verify sha256 against the manifest, write the manifest, and
///      atomically swap the `current` pointer.
///
/// Off Wi-Fi:
///   - If a cached version exists → return it (no network).
///   - Else throw [PackUnavailable].
class PackManager {
  PackManager({
    required String serverBaseUrl,
    required this.cache,
    required this.wifiGuard,
    http.Client? httpClient,
  })  : _baseUrl = _normalizeBase(serverBaseUrl),
        _http = httpClient ?? http.Client();

  static String _normalizeBase(String url) {
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  final String _baseUrl;
  final PackCache cache;
  final WifiGuard wifiGuard;
  final http.Client _http;

  Future<PackManifest> ensure(String packId) async {
    final onWifi = await wifiGuard.isOnWifi();
    if (!onWifi) {
      final cached = await cache.currentManifest(packId);
      if (cached != null) return cached;
      throw PackUnavailable(
        'Pack "$packId" not in cache and device is not on Wi-Fi.',
      );
    }

    // Wi-Fi path: ask the server what the current version is.
    PackManifest remote;
    try {
      remote = await _fetchManifest(packId);
    } catch (e) {
      // Network failure on a Wi-Fi attempt. If we already have a cached
      // version, fall back to it; otherwise propagate.
      final cached = await cache.currentManifest(packId);
      if (cached != null) return cached;
      throw PackUnavailable('Failed to fetch manifest for "$packId": $e');
    }

    final localVersion = await cache.currentVersion(packId);
    if (localVersion == remote.version) {
      final cached = await cache.currentManifest(packId);
      if (cached != null) return cached;
      // current pointer existed but manifest disappeared — fall through
      // and re-download.
    }

    if (remote.isZip) {
      await _downloadAndStageZip(packId, remote);
    } else {
      await _downloadAndStageImage(packId, remote);
    }
    await cache.swapCurrent(packId, remote.version);
    // Best-effort GC; don't fail the ensure() call if cleanup misbehaves.
    try {
      await cache.gc(packId);
    } catch (_) {}
    return remote;
  }

  /// M5 image flow: stream the download into a single file under the
  /// final version dir, sha256 it, write the manifest. The cache layout
  /// for images is `<version>/content/<filename>` (single file).
  Future<void> _downloadAndStageImage(
    String packId,
    PackManifest remote,
  ) async {
    final staging = await cache.stagingFile(
      packId,
      remote.version,
      remote.filename,
    );
    final resp = await _getDownload(packId);
    final sink = staging.openWrite();
    final hasher = _StreamingSha256();
    try {
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        hasher.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    final actualHash = hasher.hexDigest();
    if (actualHash != remote.sha256) {
      try {
        await staging.delete();
      } catch (_) {}
      throw PackChecksumMismatch(
        expected: remote.sha256,
        actual: actualHash,
      );
    }
    await cache.writeManifest(packId, remote.version, remote);
  }

  /// M6 zip flow:
  ///   1. Stream the zip body into `<version>.staging/source.zip`.
  ///   2. Verify sha256 against the manifest.
  ///   3. Validate the archive (index.html at root, no traversal,
  ///      size caps, entry count cap).
  ///   4. Extract every entry into `<version>.staging/content/<rel>`.
  ///   5. Write `<version>.staging/manifest.json`.
  ///   6. Atomically rename `<version>.staging` → `<version>`.
  Future<void> _downloadAndStageZip(
    String packId,
    PackManifest remote,
  ) async {
    final stagingDir = await cache.stagingVersionDir(packId, remote.version);
    // Wipe any leftover staging from a previous crash.
    if (await stagingDir.exists()) {
      await stagingDir.delete(recursive: true);
    }
    await stagingDir.create(recursive: true);

    final sourceFile = File('${stagingDir.path}/source.zip');
    final resp = await _getDownload(packId);
    final sink = sourceFile.openWrite();
    final hasher = _StreamingSha256();
    try {
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        hasher.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    final actualHash = hasher.hexDigest();
    if (actualHash != remote.sha256) {
      try {
        await stagingDir.delete(recursive: true);
      } catch (_) {}
      throw PackChecksumMismatch(
        expected: remote.sha256,
        actual: actualHash,
      );
    }

    // Read the zip body back into memory and decode. Capped via the
    // server-side maxZipBodyBytes (60 MiB) so this is bounded. We can
    // safely use ZipDecoder.decodeBytes here.
    final bytes = await sourceFile.readAsBytes();
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (e) {
      try {
        await stagingDir.delete(recursive: true);
      } catch (_) {}
      throw PackArchiveInvalid('zip decode failed: $e');
    }

    final validationErr = validateArchive(archive);
    if (validationErr != null) {
      try {
        await stagingDir.delete(recursive: true);
      } catch (_) {}
      throw PackArchiveInvalid(validationErr);
    }

    // Extract.
    final contentDir = Directory('${stagingDir.path}/content');
    await contentDir.create(recursive: true);
    for (final f in archive) {
      if (!f.isFile) continue;
      // Extra defense (validateArchive already checked names).
      if (!isSafeRelPath(f.name)) {
        try {
          await stagingDir.delete(recursive: true);
        } catch (_) {}
        throw PackArchiveInvalid('unsafe entry name "${f.name}"');
      }
      final outFile = File('${contentDir.path}/${f.name}');
      await outFile.parent.create(recursive: true);
      final data = f.content as List<int>;
      await outFile.writeAsBytes(data, flush: true);
    }

    // Write manifest into the staging dir so the atomic rename brings it
    // along with everything else.
    final manifestFile = File('${stagingDir.path}/manifest.json');
    await manifestFile.writeAsString(jsonEncode(remote.toJson()), flush: true);

    // Final flip: rename staging dir to the real version dir. POSIX
    // rename of a directory onto a non-existing target is atomic.
    final finalDir = await cache.versionDir(packId, remote.version);
    if (await finalDir.exists()) {
      // Belt-and-braces: an unexpected leftover at the target would
      // make rename fail on most filesystems. Clear it.
      await finalDir.delete(recursive: true);
    }
    await stagingDir.rename(finalDir.path);
  }

  /// GETs `<base>/packs`, builds the set of live pack ids, and asks
  /// [cache] to delete any local pack that's missing from the server.
  /// Pass the currently-displayed pack id as [preserveId] so a stale
  /// operator delete doesn't immediately yank the screen.
  ///
  /// Best-effort. On any HTTP/JSON error this is a no-op (debug-print
  /// the failure and return) — the calling site is fire-and-forget.
  Future<List<String>> syncToServer({String? preserveId}) async {
    try {
      final resp = await _http.get(Uri.parse('$_baseUrl/packs'));
      if (resp.statusCode != 200) {
        debugPrint('PackManager.syncToServer: HTTP ${resp.statusCode}');
        return const <String>[];
      }
      final raw = jsonDecode(resp.body);
      if (raw is! List) {
        debugPrint('PackManager.syncToServer: body is not a list');
        return const <String>[];
      }
      final liveIds = <String>{};
      for (final entry in raw) {
        if (entry is Map<String, dynamic>) {
          final id = entry['id'];
          if (id is String && id.isNotEmpty) liveIds.add(id);
        }
      }
      final deleted = await cache.gcMissingPacks(
        liveIds,
        preserveId: preserveId,
      );
      if (deleted.isNotEmpty) {
        debugPrint(
          'PackManager.syncToServer: deleted ${deleted.join(", ")}',
        );
      }
      return deleted;
    } catch (e) {
      debugPrint('PackManager.syncToServer failed: $e');
      return const <String>[];
    }
  }

  Future<http.StreamedResponse> _getDownload(String packId) async {
    final downloadUri = Uri.parse('$_baseUrl/packs/$packId/download');
    final req = http.Request('GET', downloadUri);
    final resp = await _http.send(req);
    if (resp.statusCode != 200) {
      throw PackUnavailable(
        'Download HTTP ${resp.statusCode} for "$packId"',
      );
    }
    return resp;
  }

  Future<PackManifest> _fetchManifest(String packId) async {
    final uri = Uri.parse('$_baseUrl/packs/$packId/manifest');
    final resp = await _http.get(uri);
    if (resp.statusCode != 200) {
      throw HttpException('manifest HTTP ${resp.statusCode}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return PackManifest.fromJson(json);
  }
}

/// Thin wrapper that incrementally feeds bytes into the package:crypto
/// `sha256` accumulator. The package's hash() helper takes a single byte
/// list, which would defeat the streaming download — this routes each
/// chunk through `convert(Sink)` instead.
class _StreamingSha256 {
  _StreamingSha256() {
    _innerSink = sha256.startChunkedConversion(_outputSink);
  }

  late final Sink<List<int>> _innerSink;
  final _OutputSink _outputSink = _OutputSink();

  void add(List<int> chunk) {
    _innerSink.add(chunk);
  }

  String hexDigest() {
    _innerSink.close();
    return _outputSink.digest!.toString();
  }
}

class _OutputSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}
