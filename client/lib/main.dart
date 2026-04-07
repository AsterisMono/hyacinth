import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// M0: hardcoded server URL. The Android emulator reaches the host machine
// at 10.0.2.2; this will become configurable in M2 (onboarding).
const String configUrl = 'http://10.0.2.2:8080/config';

void main() {
  runApp(const HyacinthApp());
}

class HyacinthApp extends StatelessWidget {
  const HyacinthApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Hyacinth',
      home: ConfigScreen(),
    );
  }
}

class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  String _body = 'loading...';

  @override
  void initState() {
    super.initState();
    _fetchConfig();
  }

  Future<void> _fetchConfig() async {
    try {
      final response = await http.get(Uri.parse(configUrl));
      final body = 'HTTP ${response.statusCode}\n${response.body}';
      debugPrint('hyacinth /config response:\n$body');
      if (!mounted) return;
      setState(() {
        _body = body;
      });
    } catch (e) {
      final err = 'error: $e';
      debugPrint('hyacinth /config $err');
      if (!mounted) return;
      setState(() {
        _body = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hyacinth M0')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Text(
            _body,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
      ),
    );
  }
}
