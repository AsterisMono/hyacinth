import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/config_model.dart';

/// Fetches the `/config` JSON document from a Hyacinth server base URL.
class ConfigClient {
  ConfigClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  /// Maximum time to wait for `/config` before giving up. On timeout the
  /// underlying `TimeoutException` propagates to the caller, which in M1
  /// lands in the bootstrap's try/catch and surfaces as an error panel.
  static const Duration _fetchTimeout = Duration(seconds: 5);

  final http.Client _http;

  Future<HyacinthConfig> fetch(String serverBaseUrl) async {
    final base = serverBaseUrl.endsWith('/')
        ? serverBaseUrl.substring(0, serverBaseUrl.length - 1)
        : serverBaseUrl;
    final uri = Uri.parse('$base/config');
    final response = await _http.get(uri).timeout(_fetchTimeout);
    if (response.statusCode != 200) {
      throw Exception(
        'GET $uri returned HTTP ${response.statusCode}: ${response.body}',
      );
    }
    final decoded = json.decode(response.body) as Map<String, dynamic>;
    return HyacinthConfig.fromJson(decoded);
  }
}
