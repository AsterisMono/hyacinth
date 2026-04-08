import 'package:flutter/material.dart';

import '../resource_pack/pack_cache.dart';

/// M8.4 — "Cached packs" panel rendered below the Settings card on
/// [MainActivityPage]. Reads the local [PackCache] via
/// [PackCache.listCachedPacks] and shows one row per cached pack with
/// id / type+version / on-disk size. The header carries a refresh
/// button so the operator can re-list after a server-side push.
///
/// This is intentionally read-only. Per-pack delete is out of scope —
/// the manual "Clear pack cache" button in `SettingsBlock` wipes
/// everything, and server-side deletes propagate via the M8.3 auto-sync
/// path on the next connect.
class CachedPacksCard extends StatefulWidget {
  const CachedPacksCard({
    super.key,
    required this.cache,
  });

  final PackCache cache;

  @override
  State<CachedPacksCard> createState() => _CachedPacksCardState();
}

class _CachedPacksCardState extends State<CachedPacksCard> {
  late Future<List<CachedPackInfo>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.cache.listCachedPacks();
  }

  void _refresh() {
    setState(() {
      _future = widget.cache.listCachedPacks();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('cachedPacksCard'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Cached packs',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Re-list cached packs',
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 4),
            FutureBuilder<List<CachedPackInfo>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  // Static placeholder rather than a LinearProgressIndicator
                  // because the indeterminate indicator schedules animation
                  // frames forever and pins `pumpAndSettle` in widget tests.
                  // The local listing resolves on the next microtask anyway,
                  // so users essentially never see this branch.
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Reading cache…',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                if (snapshot.hasError) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Failed to list packs: ${snapshot.error}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  );
                }
                final packs = snapshot.data ?? const <CachedPackInfo>[];
                if (packs.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'No packs cached yet',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final p in packs)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          p.manifest.type == 'zip'
                              ? Icons.folder_zip_outlined
                              : Icons.image_outlined,
                          color: theme.colorScheme.primary,
                        ),
                        title: Text(p.id),
                        subtitle: Text(
                          '${p.manifest.type} v${p.version} · '
                          '${humanSize(p.sizeBytes)}',
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Public so the widget test can assert formatted strings without
/// reaching into the widget's private state.
String humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}
