import 'package:shared_preferences/shared_preferences.dart';

/// Persists the operator-supplied server base URL across app launches.
///
/// In M1 there is no onboarding screen (that's M2). Callers should
/// fall back to a hardcoded default when [loadServerUrl] returns null.
class ConfigStore {
  static const String _serverUrlKey = 'hyacinth.serverUrl';

  Future<String?> loadServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverUrlKey);
  }

  Future<void> saveServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, url);
  }
}
