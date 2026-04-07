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
    HealthReport? initialReport,
  })  : _store = store,
        _healthCheck = healthCheck,
        _initialReport = initialReport;

  final AppState appState;
  final ConfigStore? _store;
  final HealthCheck? _healthCheck;

  /// Optional pre-baked report for widget tests; when provided we skip
  /// the initial async refresh entirely.
  final HealthReport? _initialReport;

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
    if (widget._initialReport != null) {
      _report = widget._initialReport;
    } else {
      _refresh();
    }
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
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (widget.appState.config != null) _returnToContentButton(),
          _healthSection(),
          SettingsBlock(
            appState: widget.appState,
            store: _store,
          ),
          _statusFooter(phase, error),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _statusFooter(AppPhase phase, String? error) {
    final scheme = Theme.of(context).colorScheme;
    String label;
    IconData icon;
    switch (phase) {
      case AppPhase.connecting:
        label = 'Connecting…';
        icon = Icons.sync;
        break;
      case AppPhase.fallback:
        label = 'Fallback';
        icon = Icons.warning_amber_outlined;
        break;
      case AppPhase.booting:
        label = 'Booting';
        icon = Icons.hourglass_empty;
        break;
      case AppPhase.displaying:
        label = 'Displaying';
        icon = Icons.check_circle_outline;
        break;
      case AppPhase.onboarding:
        label = 'Onboarding';
        icon = Icons.assignment_outlined;
        break;
    }
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Text(
                  'State: $label',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            if (error != null && error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: scheme.error,
                      ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _returnToContentButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: () => widget.appState.returnToDisplaying(),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Return to content'),
        ),
      ),
    );
  }

  Widget _healthSection() {
    final report = _report;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Health checks',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            if (_running && report == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
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
    final scheme = Theme.of(context).colorScheme;
    Color dot;
    switch (c.status) {
      case CheckStatus.ok:
        // Pull a clean green from the M3 surface palette by mixing primary
        // with a known-good accent. We use a fixed M3-friendly green so that
        // even with red-shifted dynamic colour the "ok" dot stays readable.
        dot = const Color(0xFF2E7D32);
        break;
      case CheckStatus.fail:
        dot = scheme.error;
        break;
      case CheckStatus.unknown:
        dot = scheme.tertiary;
        break;
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 14,
        height: 14,
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
      ),
      title: Text(c.name),
      subtitle: Text(
        c.message,
        style: const TextStyle(fontFamily: 'monospace'),
      ),
      trailing: c.fix != null
          ? TextButton(
              onPressed: () => _runFix(c.fix!),
              child: const Text('Fix'),
            )
          : null,
    );
  }
}
