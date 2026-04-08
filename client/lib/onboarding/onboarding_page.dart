import 'package:flutter/material.dart';

import '../app_state.dart';
import '../config/config_store.dart';
import '../permissions/perm_manager.dart';
import '../system/root_helper.dart';

/// First-run wizard.
///
/// Steps (in order): explain → root → notifications → battery opt → server URL.
/// The "root" step (M8.1) is always shown but reduces to a single tap on
/// non-rooted tablets ("Skip"). When `RootHelper.autoGrantAll` reports a
/// permission landed via root, the corresponding follow-up step (notifications,
/// battery) is removed from the wizard before we advance — both the step
/// list and the progress indicator denominator reflect the post-grant
/// reality, not a placeholder count.
///
/// All permission steps are skippable but warn; the user lands in fallback
/// if they skip something that later matters. The final step saves the
/// server URL, marks onboarding complete, and asks [AppState] to transition
/// into the connect flow.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    required this.appState,
    this.perms = const PermManager(),
    this.store,
    this.root,
  });

  final AppState appState;
  final PermManager perms;

  /// Optional [ConfigStore]. Tests inject one backed by
  /// `SharedPreferences.setMockInitialValues({})`. In production we let
  /// [AppState.completeOnboarding] do the persistence; the wizard only
  /// touches the store directly so widget tests can assert the writes
  /// landed.
  final ConfigStore? store;

  /// Optional [RootHelper]. Tests inject a fake to drive the M8.1 root
  /// probe / grant flow without hitting a real `su` binary.
  final RootHelper? root;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

enum _StepKind { explain, root, notifications, battery, serverUrl }

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _pageController = PageController();
  final TextEditingController _urlController =
      TextEditingController(text: defaultServerUrl);

  /// The currently-active list of steps. Mutated when the root step
  /// completes — successful grants pop their follow-up steps off the
  /// list before we advance. Order is preserved.
  late List<_StepKind> _steps;
  int _step = 0;
  String? _urlError;

  // Root step state.
  bool _rootChecking = false;
  RootGrantSummary? _rootSummary;
  bool _didGrantWriteSecureSettings = false;

  late final RootHelper _root;

  @override
  void initState() {
    super.initState();
    _root = widget.root ?? RootHelper();
    _steps = const [
      _StepKind.explain,
      _StepKind.root,
      _StepKind.notifications,
      _StepKind.battery,
      _StepKind.serverUrl,
    ];
  }

  @override
  void dispose() {
    _pageController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _next() {
    if (_step >= _steps.length - 1) return;
    setState(() => _step += 1);
    _pageController.animateToPage(
      _step,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// Called when the user taps Continue on the root step. If grants
  /// succeeded for notifications / battery, those steps are dropped
  /// from `_steps` BEFORE advancing — that way the progress indicator
  /// denominator is honest and we never animate into a step that we
  /// will then immediately leave.
  void _advanceFromRoot() {
    final summary = _rootSummary;
    if (summary != null) {
      final next = <_StepKind>[];
      for (final s in _steps) {
        if (s == _StepKind.notifications && summary.postNotifications) continue;
        if (s == _StepKind.battery && summary.batteryOpt) continue;
        next.add(s);
      }
      setState(() => _steps = next);
    }
    _next();
  }

  Future<void> _runRootProbe() async {
    setState(() => _rootChecking = true);
    final summary = await _root.autoGrantAll();
    // Production code path leaves widget.store null and we used to skip
    // the writes entirely — that meant the HealthCheck "Root access" row
    // stayed grey forever after onboarding. Always persist via either the
    // injected store (test) or a fresh ConfigStore() (prod).
    final store = widget.store ?? ConfigStore();
    await store.setRootChecked(true);
    await store.setRootAvailable(summary.rootAvailable);
    if (!mounted) return;
    setState(() {
      _rootChecking = false;
      _rootSummary = summary;
      _didGrantWriteSecureSettings = summary.writeSecureSettings;
    });
  }

  Future<void> _finish() async {
    final raw = _urlController.text.trim();
    final parsed = Uri.tryParse(raw);
    if (raw.isEmpty ||
        parsed == null ||
        !parsed.hasScheme ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.isEmpty) {
      setState(() => _urlError = 'Enter a full http:// or https:// URL.');
      return;
    }
    setState(() => _urlError = null);
    // Persist directly to the (possibly injected) store as well so widget
    // tests can assert without having to drive the full AppState.
    final store = widget.store;
    if (store != null) {
      await store.saveServerUrl(raw);
      await store.setOnboardingComplete(true);
    }
    await widget.appState.completeOnboarding(raw);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome to Hyacinth')),
      body: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final s in _steps) _wrap(_buildStep(s)),
              ],
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: _stepIndicator(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep(_StepKind kind) {
    switch (kind) {
      case _StepKind.explain:
        return _explainStep();
      case _StepKind.root:
        return _rootStep();
      case _StepKind.notifications:
        return _notificationsStep();
      case _StepKind.battery:
        return _batteryStep();
      case _StepKind.serverUrl:
        return _serverUrlStep();
    }
  }

  /// Constrains step content to a comfortable M3 reading width on
  /// landscape tablets. Without this the wizard's hero icon and headline
  /// look lost on a 1280dp-wide display.
  Widget _wrap(Widget child) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: child,
      ),
    );
  }

  Widget _stepIndicator() {
    final scheme = Theme.of(context).colorScheme;
    final stepCount = _steps.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        children: [
          LinearProgressIndicator(
            value: (_step + 1) / stepCount,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(stepCount, (i) {
              final active = i == _step;
              return Container(
                width: active ? 20 : 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: active
                      ? scheme.primary
                      : scheme.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _heroStep({
    required IconData icon,
    required String title,
    required String body,
    required List<Widget> actions,
    List<Widget> extras = const [],
  }) {
    final theme = Theme.of(context);
    // The root step extras list (per-permission summary) can push the
    // body taller than the available viewport on small landscape
    // tablets in test mode. Wrap the content in a SingleChildScrollView
    // so it remains accessible without overflow.
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  Icon(
                    icon,
                    size: 96,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    title,
                    style: theme.textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    body,
                    style: theme.textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                  ...extras,
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: _spacedActions(actions),
          ),
        ],
      ),
    );
  }

  List<Widget> _spacedActions(List<Widget> actions) {
    final out = <Widget>[];
    for (var i = 0; i < actions.length; i++) {
      if (i > 0) out.add(const SizedBox(width: 12));
      out.add(actions[i]);
    }
    return out;
  }

  Widget _explainStep() {
    return _heroStep(
      icon: Icons.dashboard_customize_outlined,
      title: 'Always-on display for your Ita-Bag',
      body: 'Hyacinth turns this tablet into a permanently-mounted display '
          'that renders content pushed from your self-hosted Hyacinth '
          'server. The next few steps grant the permissions it needs '
          'to stay on.',
      actions: [
        FilledButton(onPressed: _next, child: const Text('Continue')),
      ],
    );
  }

  Widget _rootStep() {
    final theme = Theme.of(context);
    final summary = _rootSummary;

    final List<Widget> extras;
    final List<Widget> actions;

    if (_rootChecking) {
      extras = const [
        SizedBox(height: 24),
        Center(child: CircularProgressIndicator()),
      ];
      actions = const [];
    } else if (summary == null) {
      extras = const [];
      actions = [
        TextButton(onPressed: _next, child: const Text('Skip')),
        FilledButton(
          onPressed: _runRootProbe,
          child: const Text('Check for root and grant'),
        ),
      ];
    } else {
      // Render the per-permission summary list.
      extras = [
        const SizedBox(height: 24),
        _grantRow(
          label: 'Root access',
          granted: summary.rootAvailable,
          deniedLabel: 'Not available',
        ),
        _grantRow(
          label: 'WRITE_SECURE_SETTINGS',
          granted: summary.writeSecureSettings,
        ),
        _grantRow(
          label: 'POST_NOTIFICATIONS',
          granted: summary.postNotifications,
        ),
        _grantRow(
          label: 'Battery optimization exemption',
          granted: summary.batteryOpt,
        ),
        if (!summary.rootAvailable)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              'Root not detected. You can still grant the remaining '
              'permissions through the next steps.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
      ];
      actions = [
        FilledButton(
          onPressed: _advanceFromRoot,
          child: const Text('Continue'),
        ),
      ];
    }

    return _heroStep(
      icon: Icons.security_outlined,
      title: 'Root access (optional)',
      body: 'Hyacinth can grant its own permissions on rooted tablets. '
          "We'll check now — this may show a Magisk/KernelSU prompt.",
      actions: actions,
      extras: extras,
    );
  }

  Widget _grantRow({
    required String label,
    required bool granted,
    String deniedLabel = 'Skipped',
  }) {
    final theme = Theme.of(context);
    final colour = granted
        ? const Color(0xFF2E7D32)
        : theme.colorScheme.onSurface.withValues(alpha: 0.5);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            granted ? Icons.check_circle : Icons.cancel_outlined,
            color: colour,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Text(
            granted ? 'Granted' : deniedLabel,
            style: theme.textTheme.bodySmall?.copyWith(color: colour),
          ),
        ],
      ),
    );
  }

  Widget _notificationsStep() {
    return _heroStep(
      icon: Icons.notifications_outlined,
      title: 'Notifications permission',
      body: 'Hyacinth shows a persistent status notification while running. '
          'Without this, Android may kill the app in the background.',
      actions: [
        TextButton(onPressed: _next, child: const Text('Skip')),
        FilledButton(
          onPressed: () async {
            await widget.perms.requestNotifications();
            _next();
          },
          child: const Text('Grant'),
        ),
      ],
    );
  }

  Widget _batteryStep() {
    return _heroStep(
      icon: Icons.battery_charging_full_outlined,
      title: 'Battery optimization exemption',
      body: 'Android aggressively suspends background apps to save battery. '
          'Hyacinth needs to be exempt so the display stays live.',
      actions: [
        TextButton(onPressed: _next, child: const Text('Skip')),
        FilledButton(
          onPressed: () async {
            await widget.perms.requestBatteryOptimization();
            _next();
          },
          child: const Text('Grant'),
        ),
      ],
    );
  }

  Widget _serverUrlStep() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          Icon(
            Icons.link_outlined,
            size: 72,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            'Server URL',
            style: theme.textTheme.headlineMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            'Enter the base URL of your Hyacinth server, '
            'e.g. http://192.168.1.10:8080',
            style: theme.textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'Server URL',
              errorText: _urlError,
              border: const OutlineInputBorder(),
            ),
          ),
          if (!_didGrantWriteSecureSettings) ...[
            const SizedBox(height: 16),
            Text(
              'Brightness and screen-timeout enforcement are best-effort '
              'until WRITE_SECURE_SETTINGS is granted via adb. See README.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton(
                onPressed: _finish,
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
