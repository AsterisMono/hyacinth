import 'package:flutter/material.dart';

import '../app_state.dart';
import '../config/config_store.dart';
import 'health_check.dart';
import 'settings_page.dart';

/// Always-visible recovery UI shown whenever the app is not in
/// [AppPhase.displaying]. The plan names this `MainActivity` because it's
/// the screen mounted "at rest": onboarding exits here, connect failures
/// land here, and the background retry timer promotes back to Displaying
/// when health + `/config` both succeed again.
class MainActivityPage extends StatefulWidget {
  const MainActivityPage({
    super.key,
    required this.appState,
    ConfigStore? store,
    HealthCheck? healthCheck,
  })  : _store = store,
        _healthCheck = healthCheck;

  final AppState appState;
  final ConfigStore? _store;
  final HealthCheck? _healthCheck;

  @override
  State<MainActivityPage> createState() => _MainActivityPageState();
}

class _MainActivityPageState extends State<MainActivityPage> {
  late final ConfigStore _store = widget._store ?? ConfigStore();
  late final HealthCheck _healthCheck = widget._healthCheck ?? HealthCheck();
  HealthReport? _report;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _running = true);
    try {
      final r = await _healthCheck.run();
      if (!mounted) return;
      setState(() => _report = r);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _runFix(Future<void> Function() fix) async {
    await fix();
    await _refresh();
    await widget.appState.recheckPermissions();
  }

  @override
  Widget build(BuildContext context) {
    final phase = widget.appState.phase;
    final error = widget.appState.error;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hyacinth'),
        actions: [
          IconButton(
            tooltip: 'Re-run checks',
            onPressed: _running ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        children: [
          _statusBanner(phase, error),
          _healthSection(),
          SettingsBlock(
            appState: widget.appState,
            store: _store,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _statusBanner(AppPhase phase, String? error) {
    Color bg;
    String label;
    switch (phase) {
      case AppPhase.connecting:
        bg = Colors.blueGrey;
        label = 'Connecting…';
        break;
      case AppPhase.fallback:
        bg = Colors.red.shade700;
        label = 'Fallback';
        break;
      case AppPhase.booting:
        bg = Colors.grey;
        label = 'Booting';
        break;
      case AppPhase.displaying:
        bg = Colors.green.shade700;
        label = 'Displaying';
        break;
      case AppPhase.onboarding:
        bg = Colors.orange;
        label = 'Onboarding';
        break;
    }
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'State: $label',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (error != null && error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error,
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _healthSection() {
    final report = _report;
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Health checks',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (_running && report == null)
              const Padding(
                padding: EdgeInsets.all(8),
                child: LinearProgressIndicator(),
              ),
            if (report != null)
              ...report.checks.map(_checkRow),
          ],
        ),
      ),
    );
  }

  Widget _checkRow(CheckResult c) {
    Color dot;
    switch (c.status) {
      case CheckStatus.ok:
        dot = Colors.green;
        break;
      case CheckStatus.fail:
        dot = Colors.red;
        break;
      case CheckStatus.unknown:
        dot = Colors.amber;
        break;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 12,
            height: 12,
            margin: const EdgeInsets.only(top: 4, right: 12),
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  c.message,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          if (c.fix != null)
            TextButton(
              onPressed: () => _runFix(c.fix!),
              child: const Text('Fix'),
            ),
        ],
      ),
    );
  }
}
