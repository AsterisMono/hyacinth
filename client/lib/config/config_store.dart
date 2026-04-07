import 'package:shared_preferences/shared_preferences.dart';

/// Default server URL used for the "seed" value in the onboarding wizard.
/// On the Android emulator, `10.0.2.2` is the loopback back to the host.
/// The operator can override this in onboarding or in the fallback settings.
const String defaultServerUrl = 'http://10.0.2.2:8080';

/// Persists operator-supplied display settings across app launches.
///
/// M2 introduces an explicit `onboardingComplete` flag so the boot flow no
/// longer has to infer it from the presence of a server URL (which caused
/// the "just use the default" shortcut in M1).
class ConfigStore {
  static const String _serverUrlKey = 'hyacinth.serverUrl';
  static const String _onboardingCompleteKey = 'hyacinth.onboardingComplete';
  // M8.1 — root self-grant cache. `_rootCheckedKey` becomes true the
  // first time the user runs the onboarding root probe (regardless of
  // outcome); `_rootAvailableKey` becomes true only when `su -c id`
  // returned `uid=0`. Boot-time silent re-grant gates on the latter.
  static const String _rootCheckedKey = 'hyacinth.root.checked';
  static const String _rootAvailableKey = 'hyacinth.root.available';

  Future<String?> loadServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverUrlKey);
  }

  Future<void> saveServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, url);
  }

  Future<bool> isOnboardingComplete() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_onboardingCompleteKey) ?? false;
  }

  Future<void> setOnboardingComplete(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingCompleteKey, value);
  }

  Future<bool> getRootChecked() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_rootCheckedKey) ?? false;
  }

  Future<void> setRootChecked(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_rootCheckedKey, value);
  }

  Future<bool> getRootAvailable() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_rootAvailableKey) ?? false;
  }

  Future<void> setRootAvailable(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_rootAvailableKey, value);
  }
}
