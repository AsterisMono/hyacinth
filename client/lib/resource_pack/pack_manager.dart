import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'pack_cache.dart';
import 'pack_manifest.dart';
import 'wifi_guard.dart';

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

    // Stream the bytes to a staging file, hashing as we go.
    final staging = await cache.stagingFile(
      packId,
      remote.version,
      remote.filename,
    );
    final downloadUri = Uri.parse('$_baseUrl/packs/$packId/download');
    final req = http.Request('GET', downloadUri);
    final resp = await _http.send(req);
    if (resp.statusCode != 200) {
      throw PackUnavailable(
        'Download HTTP ${resp.statusCode} for "$packId"',
      );
    }
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
      // Don't pollute the cache. Best-effort cleanup of the staged file.
      try {
        await staging.delete();
      } catch (_) {}
      throw PackChecksumMismatch(
        expected: remote.sha256,
        actual: actualHash,
      );
    }
    await cache.writeManifest(packId, remote.version, remote);
    await cache.swapCurrent(packId, remote.version);
    // Best-effort GC; don't fail the ensure() call if cleanup misbehaves.
    try {
      await cache.gc(packId);
    } catch (_) {}
    return remote;
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
