// Hermetic tests for ConfigStore. Uses
// SharedPreferences.setMockInitialValues() so we never touch a real platform
// channel.

import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/config/config_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('loadServerUrl returns null when unset', () async {
    final store = ConfigStore();
    expect(await store.loadServerUrl(), isNull);
  });

  test('saveServerUrl round-trips', () async {
    final store = ConfigStore();
    await store.saveServerUrl('http://example.com:8080');
    expect(await store.loadServerUrl(), 'http://example.com:8080');
  });

  test('isOnboardingComplete defaults to false', () async {
    final store = ConfigStore();
    expect(await store.isOnboardingComplete(), isFalse);
  });

  test('setOnboardingComplete(true) round-trips', () async {
    final store = ConfigStore();
    await store.setOnboardingComplete(true);
    expect(await store.isOnboardingComplete(), isTrue);
  });

  test('getRootChecked defaults to false', () async {
    final store = ConfigStore();
    expect(await store.getRootChecked(), isFalse);
  });

  test('setRootChecked(true) round-trips', () async {
    final store = ConfigStore();
    await store.setRootChecked(true);
    expect(await store.getRootChecked(), isTrue);
  });

  test('getRootAvailable defaults to false', () async {
    final store = ConfigStore();
    expect(await store.getRootAvailable(), isFalse);
  });

  test('setRootAvailable(true) round-trips', () async {
    final store = ConfigStore();
    await store.setRootAvailable(true);
    expect(await store.getRootAvailable(), isTrue);
  });
}
