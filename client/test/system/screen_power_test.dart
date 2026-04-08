// Hermetic tests for the M9 ScreenPower MethodChannel wrapper. Drives the
// `io.hyacinth/screen_power` channel via the test binary messenger so the
// real Kotlin handler is never invoked.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/system/screen_power.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.hyacinth/screen_power');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('isInteractive', () {
    test('true when channel returns true', () async {
      install((_) async => true);
      expect(await ScreenPower().isInteractive(), isTrue);
    });
    test('false when channel returns false', () async {
      install((_) async => false);
      expect(await ScreenPower().isInteractive(), isFalse);
    });
    test('false when channel throws', () async {
      install((_) async => throw PlatformException(code: 'ERROR'));
      expect(await ScreenPower().isInteractive(), isFalse);
    });
  });

  group('isAdminActive', () {
    test('true when channel returns true', () async {
      install((_) async => true);
      expect(await ScreenPower().isAdminActive(), isTrue);
    });
    test('false when channel returns false', () async {
      install((_) async => false);
      expect(await ScreenPower().isAdminActive(), isFalse);
    });
    test('false when channel throws', () async {
      install((_) async => throw PlatformException(code: 'ERROR'));
      expect(await ScreenPower().isAdminActive(), isFalse);
    });
  });

  group('apply', () {
    test('"root" tier returned', () async {
      install((call) async {
        expect(call.method, 'setScreenOn');
        expect((call.arguments as Map)['on'], isFalse);
        return 'root';
      });
      expect(await ScreenPower().apply(false), 'root');
    });

    test('"admin" tier returned', () async {
      install((_) async => 'admin');
      expect(await ScreenPower().apply(false), 'admin');
    });

    test('"noop" short-circuit returned', () async {
      install((_) async => 'noop');
      expect(await ScreenPower().apply(true), 'noop');
    });

    test('no_capability → ScreenPowerUnavailable', () async {
      install((_) async => throw PlatformException(
            code: 'no_capability',
            message: 'neither tier',
          ));
      await expectLater(
        ScreenPower().apply(false),
        throwsA(isA<ScreenPowerUnavailable>()),
      );
    });

    test('other PlatformException is rethrown unchanged', () async {
      install((_) async => throw PlatformException(code: 'boom'));
      await expectLater(
        ScreenPower().apply(false),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'boom'),
        ),
      );
    });
  });

  group('requestAdmin', () {
    test('swallows channel errors', () async {
      install((_) async => throw PlatformException(code: 'ERROR'));
      // Must not throw.
      await ScreenPower().requestAdmin();
    });

    test('invokes the requestAdmin method on the channel', () async {
      var called = false;
      install((call) async {
        if (call.method == 'requestAdmin') {
          called = true;
          return null;
        }
        return null;
      });
      await ScreenPower().requestAdmin();
      expect(called, isTrue);
    });
  });
}
