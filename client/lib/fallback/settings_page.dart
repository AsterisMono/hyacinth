import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../app_state.dart';
import '../config/config_store.dart';
import '../permissions/perm_manager.dart';

/// Settings block composed inside [MainActivityPage].
///
/// Kept as a widget (not a route) per the M2 layout: the fallback page
/// is a single scrollable surface, not a multi-screen settings app.
class SettingsBlock extends StatefulWidget {
  const SettingsBlock({
    super.key,
    required this.appState,
    required this.store,
    this.perms = const PermManager(),
    this.httpClient,
  });

  final AppState appState;
  final ConfigStore store;
  final PermManager perms;
  final http.Client? httpClient;

  @override
  State<SettingsBlock> createState() => _SettingsBlockState();
}

class _SettingsBlockState extends State<SettingsBlock> {
  final TextEditingController _urlCtrl = TextEditingController();
  String? _testResult;
  bool _testing = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final url = await widget.store.loadServerUrl();
    if (!mounted) return;
    setState(() {
      _urlCtrl.text = url ?? defaultServerUrl;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    await widget.store.saveServerUrl(url);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Server URL saved.')),
    );
  }

  Future<void> _testConnection() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _testResult = 'Enter a URL first.');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final client = widget.httpClient ?? http.Client();
    try {
      final base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
      final resp = await client
          .get(Uri.parse('$base/health'))
          .timeout(const Duration(seconds: 3));
      if (!mounted) return;
      setState(() {
        _testResult = resp.statusCode == 200
            ? 'OK (${resp.statusCode}) ${resp.body}'
            : 'HTTP ${resp.statusCode}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _testResult = '$e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _reRequestPermissions() async {
    await widget.perms.requestNotifications();
    await widget.perms.requestBatteryOptimization();
    await widget.appState.recheckPermissions();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Permission requests sent.')),
    );
  }

  void _clearPackCache() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No pack cache yet (M5)')),
    );
  }

  Future<void> _reloadNow() async {
    await widget.appState.retryConnect();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Settings',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _testing ? null : _testConnection,
                  child: Text(_testing ? 'Testing…' : 'Test connection'),
                ),
                FilledButton(
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ],
            ),
            if (_testResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Test: $_testResult',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            const Divider(height: 32),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _reRequestPermissions,
                  child: const Text('Re-request permissions'),
                ),
                OutlinedButton(
                  onPressed: _clearPackCache,
                  child: const Text('Clear pack cache'),
                ),
                OutlinedButton(
                  onPressed: _reloadNow,
                  child: const Text('Reload now'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
