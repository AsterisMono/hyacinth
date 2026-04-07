import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/config_model.dart';

/// Fetches the `/config` JSON document from a Hyacinth server base URL.
class ConfigClient {
  ConfigClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  Future<HyacinthConfig> fetch(String serverBaseUrl) async {
    final base = serverBaseUrl.endsWith('/')
        ? serverBaseUrl.substring(0, serverBaseUrl.length - 1)
        : serverBaseUrl;
    final uri = Uri.parse('$base/config');
    final response = await _http.get(uri);
    if (response.statusCode != 200) {
      throw Exception(
        'GET $uri returned HTTP ${response.statusCode}: ${response.body}',
      );
    }
    final decoded = json.decode(response.body) as Map<String, dynamic>;
    return HyacinthConfig.fromJson(decoded);
  }
}
