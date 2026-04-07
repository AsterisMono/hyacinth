import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/config_model.dart';
import '../config/config_store.dart';
import '../net/config_client.dart';
import 'webview_controller.dart';

/// M1 default server URL. The Android emulator reaches the host machine at
/// 10.0.2.2; the operator will override this in M2 onboarding.
const String defaultServerUrl = 'http://10.0.2.2:8080';

/// Top-level fullscreen display surface.
///
/// On startup it loads the persisted server URL (or seeds it with the M1
/// default), fetches `/config`, and renders the URL in an InAppWebView.
///
/// Immersive sticky mode is applied at construction and re-applied when the
/// app resumes. A wakelock keeps the screen on while this widget is mounted.
class DisplayPage extends StatefulWidget {
  const DisplayPage({
    super.key,
    ConfigStore? configStore,
    ConfigClient? configClient,
  })  : _configStore = configStore,
        _configClient = configClient;

  final ConfigStore? _configStore;
  final ConfigClient? _configClient;

  @override
  State<DisplayPage> createState() => _DisplayPageState();
}

class _DisplayPageState extends State<DisplayPage>
    with WidgetsBindingObserver {
  late final ConfigStore _store = widget._configStore ?? ConfigStore();
  late final ConfigClient _client = widget._configClient ?? ConfigClient();

  HyacinthConfig? _config;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enterImmersive();
    WakelockPlus.enable();
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _enterImmersive();
    }
  }

  void _enterImmersive() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _bootstrap() async {
    try {
      var serverUrl = await _store.loadServerUrl();
      if (serverUrl == null || serverUrl.isEmpty) {
        serverUrl = defaultServerUrl;
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Failed to load /config:\n$error',
            style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final config = _config;
    if (config == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return HyacinthWebView(url: config.content);
  }
}
