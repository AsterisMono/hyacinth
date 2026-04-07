import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/system/secure_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.hyacinth/secure_settings');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('hasPermission', () {
    test('returns true when channel returns true', () async {
      install((_) async => true);
      expect(await SecureSettings().hasPermission(), isTrue);
    });

    test('returns false when channel returns false', () async {
      install((_) async => false);
      expect(await SecureSettings().hasPermission(), isFalse);
    });

    test('returns false when channel throws', () async {
      install((_) async => throw PlatformException(code: 'ERROR'));
      expect(await SecureSettings().hasPermission(), isFalse);
    });
  });

  group('current* getters', () {
    test('currentBrightness returns int from channel', () async {
      install((call) async {
        expect(call.method, 'currentBrightness');
        return 128;
      });
      expect(await SecureSettings().currentBrightness(), 128);
    });

    test('currentBrightnessMode returns null on error', () async {
      install((_) async => throw PlatformException(code: 'ERROR'));
      expect(await SecureSettings().currentBrightnessMode(), isNull);
    });

    test('currentScreenOffTimeout returns int from channel', () async {
      install((call) async {
        expect(call.method, 'currentScreenOffTimeout');
        return 60000;
      });
      expect(await SecureSettings().currentScreenOffTimeout(), 60000);
    });
  });

  group('setBrightness', () {
    test('clamps below 0 → 0', () async {
      int? observed;
      install((call) async {
        expect(call.method, 'setBrightness');
        observed = (call.arguments as Map)['value'] as int;
        return null;
      });
      await SecureSettings().setBrightness(-50);
      expect(observed, 0);
    });

    test('clamps above 255 → 255', () async {
      int? observed;
      install((call) async {
        observed = (call.arguments as Map)['value'] as int;
        return null;
      });
      await SecureSettings().setBrightness(9999);
      expect(observed, 255);
    });

    test('passes mid-range value through', () async {
      int? observed;
      install((call) async {
        observed = (call.arguments as Map)['value'] as int;
        return null;
      });
      await SecureSettings().setBrightness(120);
      expect(observed, 120);
    });

    test('PERMISSION_DENIED → SecureSettingsDenied', () async {
      install((_) async => throw PlatformException(
            code: 'PERMISSION_DENIED',
            message: 'no grant',
          ));
      await expectLater(
        SecureSettings().setBrightness(100),
        throwsA(isA<SecureSettingsDenied>()),
      );
    });
  });

  group('setScreenOffTimeout', () {
    test('forwards ms argument', () async {
      int? observed;
      install((call) async {
        expect(call.method, 'setScreenOffTimeout');
        observed = (call.arguments as Map)['ms'] as int;
        return null;
      });
      await SecureSettings().setScreenOffTimeout(45000);
      expect(observed, 45000);
    });

    test('alwaysOnTimeoutMs == Integer.MAX_VALUE', () {
      expect(SecureSettings.alwaysOnTimeoutMs, 2147483647);
    });
  });

  group('setBrightnessMode', () {
    test('forwards mode', () async {
      int? observed;
      install((call) async {
        expect(call.method, 'setBrightnessMode');
        observed = (call.arguments as Map)['mode'] as int;
        return null;
      });
      await SecureSettings().setBrightnessMode(1);
      expect(observed, 1);
    });
  });
}
