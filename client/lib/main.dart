// M1 transition seam.
//
// `_M1Bootstrap` below exists to keep `DisplayPage` render-only while M1
// still has no proper app-level state machine. In M2 this bootstrap logic
// moves into `AppState` (loading, error, onboarding, displaying states),
// and `DisplayPage` will be mounted only in the `Displaying` state with a
// `HyacinthConfig` already in hand. When that lands, delete `_M1Bootstrap`.

import 'package:flutter/material.dart';

import 'config/config_model.dart';
import 'config/config_store.dart';
import 'display/display_page.dart';
import 'net/config_client.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HyacinthApp());
}

class HyacinthApp extends StatelessWidget {
  const HyacinthApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Hyacinth',
      debugShowCheckedModeBanner: false,
      home: _M1Bootstrap(),
    );
  }
}

/// M1 transition seam: loads the persisted server URL (seeding with the M1
/// default if absent), fetches `/config`, and mounts [DisplayPage] on
/// success. Shows a spinner while loading and an error panel on failure.
///
/// This widget will be replaced by `AppState` in M2.
class _M1Bootstrap extends StatefulWidget {
  const _M1Bootstrap({
    ConfigStore? configStore,
    ConfigClient? configClient,
  })  : _configStore = configStore,
        _configClient = configClient;

  final ConfigStore? _configStore;
  final ConfigClient? _configClient;

  @override
  State<_M1Bootstrap> createState() => _M1BootstrapState();
}

class _M1BootstrapState extends State<_M1Bootstrap> {
  late final ConfigStore _store = widget._configStore ?? ConfigStore();
  late final ConfigClient _client = widget._configClient ?? ConfigClient();

  HyacinthConfig? _config;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      var serverUrl = await _store.loadServerUrl();
      if (serverUrl == null || serverUrl.isEmpty) {
        serverUrl = defaultServerUrl;
        // TODO(M2): use a separate onboardingComplete flag instead of presence of serverUrl
        await _store.saveServerUrl(serverUrl);
      }
      final config = await _client.fetch(serverUrl);
      if (!mounted) return;
      setState(() {
        _config = config;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Failed to load /config:\n$error',
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final config = _config;
    if (config == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }
    return DisplayPage(config: config);
  }
}
