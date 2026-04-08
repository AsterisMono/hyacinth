import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/system/cpu_governor.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.hyacinth/cpu_governor');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('isSupported', () {
    test('false when root not cached (channel never queried)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.root.available': false,
      });
      var channelCalled = false;
      install((call) async {
        channelCalled = true;
        return true;
      });
      expect(await CpuGovernor().isSupported(), isFalse);
      expect(channelCalled, isFalse);
    });

    test('true when root cached AND channel returns true', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.root.available': true,
      });
      install((call) async {
        expect(call.method, 'isSupported');
        return true;
      });
      expect(await CpuGovernor().isSupported(), isTrue);
    });

    test('false when root cached but channel returns false', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.root.available': true,
      });
      install((_) async => false);
      expect(await CpuGovernor().isSupported(), isFalse);
    });

    test('false when channel throws', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.root.available': true,
      });
      install((_) async => throw PlatformException(code: 'ERROR'));
      expect(await CpuGovernor().isSupported(), isFalse);
    });

    test('false when key missing (default unchecked)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      var channelCalled = false;
      install((_) async {
        channelCalled = true;
        return true;
      });
      expect(await CpuGovernor().isSupported(), isFalse);
      expect(channelCalled, isFalse);
    });
  });

  group('enterPowersave', () {
    test('returns false when unsupported (never calls enterPowersave)',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.root.available': false,
      });
      final seenMethods = <String>[];
      install((call) async {
        seenMethods.add(call.method);
        return null;
      });
      expect(await CpuGovernor().enterPowersave(), isFalse);
      expect(seenMethods.contains('enterPowersave'), isFalse);
    });

    test('returns true when channel reports ok', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.root.available': true,
      });
      install((call) async {
        if (call.method == 'isSupported') return true;
        if (call.method == 'enterPowersave') {
          return <String, Object?>{
            'ok': true,
            'policies': 4,
            'error': null,
          };
        }
        return null;
      });
      expect(await CpuGovernor().enterPowersave(), isTrue);
    });

    test('returns false when channel reports ok=false', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.root.available': true,
      });
      install((call) async {
        if (call.method == 'isSupported') return true;
        if (call.method == 'enterPowersave') {
          return <String, Object?>{
            'ok': false,
            'policies': 0,
            'error': 'no root',
          };
        }
        return null;
      });
      expect(await CpuGovernor().enterPowersave(), isFalse);
    });

    test('returns false when channel throws', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hyacinth.root.available': true,
      });
      install((call) async {
        if (call.method == 'isSupported') return true;
        throw PlatformException(code: 'ERROR', message: 'kaboom');
      });
      expect(await CpuGovernor().enterPowersave(), isFalse);
    });
  });

  group('restore', () {
    test('returns true when channel reports ok', () async {
      install((call) async {
        expect(call.method, 'restore');
        return <String, Object?>{
          'ok': true,
          'policies': 4,
          'error': null,
        };
      });
      expect(await CpuGovernor().restore(), isTrue);
    });

    test('returns false when channel reports ok=false', () async {
      install((_) async => <String, Object?>{
            'ok': false,
            'policies': 0,
            'error': 'restore failed',
          });
      expect(await CpuGovernor().restore(), isFalse);
    });

    test('returns false when channel throws', () async {
      install((_) async => throw PlatformException(code: 'ERROR'));
      expect(await CpuGovernor().restore(), isFalse);
    });
  });

  group('CpuGovernorUnavailable', () {
    test('toString includes reason', () {
      expect(
        const CpuGovernorUnavailable('no root').toString(),
        'CpuGovernorUnavailable: no root',
      );
    });
  });
}
