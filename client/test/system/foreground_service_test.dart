import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/system/foreground_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.hyacinth/foreground_service');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('start invokes the channel and returns true on success', () async {
    final calls = <String>[];
    install((call) async {
      calls.add(call.method);
      return null;
    });
    expect(await ForegroundService().start(), isTrue);
    expect(calls, ['start']);
  });

  test('start swallows platform errors and returns false', () async {
    install((_) async => throw PlatformException(code: 'PERMISSION_DENIED'));
    expect(await ForegroundService().start(), isFalse);
  });

  test('start returns true when no plugin is registered', () async {
    // No handler installed → MissingPluginException → wrapper returns true.
    expect(await ForegroundService().start(), isTrue);
  });

  test('stop calls through and never throws on errors', () async {
    final calls = <String>[];
    install((call) async {
      calls.add(call.method);
      return null;
    });
    await ForegroundService().stop();
    expect(calls, ['stop']);

    install((_) async => throw PlatformException(code: 'ERROR'));
    // Must not throw.
    await ForegroundService().stop();
  });
}
