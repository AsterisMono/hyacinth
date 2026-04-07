import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../config/config_store.dart';
import '../permissions/perm_manager.dart';

/// Default home-settings launcher used in production. Lifted out of the
/// widget so tests can swap it for a no-op closure.
Future<void> defaultOpenHomeSettings() async {
  const intent = AndroidIntent(action: 'android.settings.HOME_SETTINGS');
  await intent.launch();
}

/// First-run wizard.
///
/// Steps (in order): explain → notifications → battery opt → home role →
/// server URL. All permission steps are skippable but warn; the user lands
/// in fallback if they skip something that later matters. The final step
/// saves the server URL, marks onboarding complete, and asks [AppState]
/// to transition into the connect flow.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    required this.appState,
    this.perms = const PermManager(),
    this.store,
    this.onOpenHomeSettings = defaultOpenHomeSettings,
  });

  final AppState appState;
  final PermManager perms;

  /// Optional [ConfigStore]. Tests inject one backed by
  /// `SharedPreferences.setMockInitialValues({})`. In production we let
  /// [AppState.completeOnboarding] do the persistence; the wizard only
  /// touches the store directly so widget tests can assert the writes
  /// landed.
  final ConfigStore? store;

  /// Hook for the "Open Home settings" button. Defaults to firing the
  /// `HOME_SETTINGS` intent; tests pass an in-memory recorder.
  final Future<void> Function() onOpenHomeSettings;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _pageController = PageController();
  final TextEditingController _urlController =
      TextEditingController(text: defaultServerUrl);
  int _step = 0;
  String? _urlError;
  static const int _stepCount = 5;

  @override
  void dispose() {
    _pageController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _next() {
    if (_step >= _stepCount - 1) return;
    setState(() => _step += 1);
    _pageController.animateToPage(
      _step,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
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
                _explainStep(),
                _notificationsStep(),
                _batteryStep(),
                _homeRoleStep(),
                _serverUrlStep(),
              ],
            ),
          ),
          _stepIndicator(),
        ],
      ),
    );
  }

  Widget _stepIndicator() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        children: [
          LinearProgressIndicator(
            value: (_step + 1) / _stepCount,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_stepCount, (i) {
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
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
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
          const Spacer(),
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

  Widget _homeRoleStep() {
    return _heroStep(
      icon: Icons.home_outlined,
      title: 'Pick Hyacinth as your Home app',
      body: 'So pressing Home always returns to the display, select Hyacinth '
          'as the default launcher in the Android "Home app" settings. '
          'Tap Open, pick Hyacinth, then come back and tap "I picked it".',
      actions: [
        TextButton(
          onPressed: () => widget.onOpenHomeSettings(),
          child: const Text('Open'),
        ),
        FilledButton(
          onPressed: _next,
          child: const Text('I picked it'),
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
            size: 96,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 24),
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
