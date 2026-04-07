import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../config/config_store.dart';
import '../permissions/perm_manager.dart';

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
  });

  final AppState appState;
  final PermManager perms;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _pageController = PageController();
  final TextEditingController _urlController =
      TextEditingController(text: defaultServerUrl);
  int _step = 0;
  String? _urlError;

  @override
  void dispose() {
    _pageController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _next() {
    if (_step >= 4) return;
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
    await widget.appState.completeOnboarding(raw);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome to Hyacinth')),
      body: PageView(
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
    );
  }

  Widget _wrap(String title, String body, List<Widget> actions) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(body, style: Theme.of(context).textTheme.bodyLarge),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: actions,
          ),
        ],
      ),
    );
  }

  Widget _explainStep() {
    return _wrap(
      'Always-on display for your Ita-Bag',
      'Hyacinth turns this tablet into a permanently-mounted display that '
          'renders content pushed from your self-hosted Hyacinth server. '
          'The next few steps grant the permissions it needs to stay on.',
      [
        FilledButton(onPressed: _next, child: const Text('Continue')),
      ],
    );
  }

  Widget _notificationsStep() {
    return _wrap(
      'Notifications permission',
      'Hyacinth shows a persistent status notification while running. '
          'Without this, Android may kill the app in the background.',
      [
        TextButton(onPressed: _next, child: const Text('Skip')),
        const SizedBox(width: 8),
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
    return _wrap(
      'Battery optimization exemption',
      'Android aggressively suspends background apps to save battery. '
          'Hyacinth needs to be exempt so the display stays live.',
      [
        TextButton(onPressed: _next, child: const Text('Skip')),
        const SizedBox(width: 8),
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
    return _wrap(
      'Pick Hyacinth as your Home app',
      'So pressing Home always returns to the display, select Hyacinth '
          'as the default launcher in the Android "Home app" settings. '
          'Tap Open, pick Hyacinth, then come back and tap "I picked it".',
      [
        TextButton(
          onPressed: () async {
            const intent =
                AndroidIntent(action: 'android.settings.HOME_SETTINGS');
            await intent.launch();
          },
          child: const Text('Open'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _next,
          child: const Text('I picked it'),
        ),
      ],
    );
  }

  Widget _serverUrlStep() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Server URL',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text(
            'Enter the base URL of your Hyacinth server, e.g. '
            'http://192.168.1.10:8080',
          ),
          const SizedBox(height: 16),
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
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton(
                onPressed: _finish,
                child: const Text('Save & continue'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
