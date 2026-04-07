import 'package:shared_preferences/shared_preferences.dart';

/// M1 default server URL. The Android emulator reaches the host machine at
/// 10.0.2.2; the operator will override this in M2 onboarding.
const String defaultServerUrl = 'http://10.0.2.2:8080';

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
