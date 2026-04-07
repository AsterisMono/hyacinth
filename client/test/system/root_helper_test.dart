// Hermetic tests for the M8.1 RootHelper. Drives the
// `io.hyacinth/root` MethodChannel via the test binary messenger so we
// never touch a real `su` binary.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/system/root_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.hyacinth/root');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Tracks every call placed on the channel during a test, in order.
  // Tests use it to assert which methods were invoked AND how many
  // times — `autoGrantAll` short-circuiting on root absence is checked
  // by counting invocations.
  late List<String> calls;

  setUp(() => calls = <String>[]);

  void install(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call.method);
      return handler(call);
    });
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('hasRoot', () {
    test('returns true when channel returns true', () async {
      install((_) async => true);
      expect(await RootHelper().hasRoot(), isTrue);
      expect(calls, ['hasRoot']);
    });

    test('returns false when channel returns false', () async {
      install((_) async => false);
      expect(await RootHelper().hasRoot(), isFalse);
    });

    test('returns false when channel throws', () async {
      install((_) async => throw PlatformException(code: 'ERROR'));
      expect(await RootHelper().hasRoot(), isFalse);
    });
  });

  group('grant methods (happy path)', () {
    test('grantWriteSecureSettings → true', () async {
      install((_) async => true);
      expect(await RootHelper().grantWriteSecureSettings(), isTrue);
      expect(calls, ['grantWriteSecureSettings']);
    });

    test('grantPostNotifications → true', () async {
      install((_) async => true);
      expect(await RootHelper().grantPostNotifications(), isTrue);
      expect(calls, ['grantPostNotifications']);
    });

    test('whitelistBatteryOpt → true', () async {
      install((_) async => true);
      expect(await RootHelper().whitelistBatteryOpt(), isTrue);
      expect(calls, ['whitelistBatteryOpt']);
    });
  });

  group('grant methods on channel exception', () {
    test('grantWriteSecureSettings → false', () async {
      install((_) async => throw PlatformException(code: 'ERROR'));
      expect(await RootHelper().grantWriteSecureSettings(), isFalse);
    });

    test('grantPostNotifications → false', () async {
      install((_) async => throw PlatformException(code: 'ERROR'));
      expect(await RootHelper().grantPostNotifications(), isFalse);
    });

    test('whitelistBatteryOpt → false', () async {
      install((_) async => throw PlatformException(code: 'ERROR'));
      expect(await RootHelper().whitelistBatteryOpt(), isFalse);
    });
  });

  group('autoGrantAll', () {
    test('no root → all-false summary, no grant calls placed', () async {
      install((call) async => call.method == 'hasRoot' ? false : true);
      final summary = await RootHelper().autoGrantAll();
      expect(summary.rootAvailable, isFalse);
      expect(summary.writeSecureSettings, isFalse);
      expect(summary.postNotifications, isFalse);
      expect(summary.batteryOpt, isFalse);
      expect(summary.allGranted, isFalse);
      // The four grants must NOT have been attempted.
      expect(calls, ['hasRoot']);
    });

    test('root + all granted → all-true summary, allGranted', () async {
      install((_) async => true);
      final summary = await RootHelper().autoGrantAll();
      expect(summary.rootAvailable, isTrue);
      expect(summary.writeSecureSettings, isTrue);
      expect(summary.postNotifications, isTrue);
      expect(summary.batteryOpt, isTrue);
      expect(summary.allGranted, isTrue);
      expect(calls, [
        'hasRoot',
        'grantWriteSecureSettings',
        'grantPostNotifications',
        'whitelistBatteryOpt',
      ]);
    });

    test('root + one denied → mixed summary, all three still attempted',
        () async {
      install((call) async {
        // POST_NOTIFICATIONS denied; everything else fine.
        if (call.method == 'grantPostNotifications') return false;
        return true;
      });
      final summary = await RootHelper().autoGrantAll();
      expect(summary.rootAvailable, isTrue);
      expect(summary.writeSecureSettings, isTrue);
      expect(summary.postNotifications, isFalse);
      expect(summary.batteryOpt, isTrue);
      expect(summary.allGranted, isFalse);
      // All four invocations must have been placed despite the denial.
      expect(calls, [
        'hasRoot',
        'grantWriteSecureSettings',
        'grantPostNotifications',
        'whitelistBatteryOpt',
      ]);
    });
  });
}
