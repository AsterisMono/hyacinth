// Hermetic tests for the M13 BatteryWatcher MethodChannel wrapper. The
// channel is one-way native→Dart, so instead of the usual
// `setMockMethodCallHandler` pattern (which intercepts Dart→native
// calls) these tests simulate a native push by feeding an encoded
// method call directly through the binary messenger.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/system/battery_watcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.hyacinth/battery.test');
  const codec = StandardMethodCodec();

  Future<void> pushNative(
    WidgetTester tester,
    String method, [
    Object? args,
  ]) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
    await tester.pump();
  }

  testWidgets('emits true on charging_changed:{connected:true}',
      (tester) async {
    final watcher = BatteryWatcher(channel: channel);
    addTearDown(() async => watcher.dispose());

    final emitted = <bool>[];
    final sub = watcher.onChargingChanged.listen(emitted.add);
    addTearDown(sub.cancel);

    await pushNative(tester, 'charging_changed', {'connected': true});

    expect(emitted, <bool>[true]);
  });

  testWidgets('emits false on charging_changed:{connected:false}',
      (tester) async {
    final watcher = BatteryWatcher(channel: channel);
    addTearDown(() async => watcher.dispose());

    final emitted = <bool>[];
    final sub = watcher.onChargingChanged.listen(emitted.add);
    addTearDown(sub.cancel);

    await pushNative(tester, 'charging_changed', {'connected': false});

    expect(emitted, <bool>[false]);
  });

  testWidgets('preserves order across multiple events', (tester) async {
    final watcher = BatteryWatcher(channel: channel);
    addTearDown(() async => watcher.dispose());

    final emitted = <bool>[];
    final sub = watcher.onChargingChanged.listen(emitted.add);
    addTearDown(sub.cancel);

    await pushNative(tester, 'charging_changed', {'connected': true});
    await pushNative(tester, 'charging_changed', {'connected': false});
    await pushNative(tester, 'charging_changed', {'connected': true});

    expect(emitted, <bool>[true, false, true]);
  });

  testWidgets('stream is broadcast — multiple subscribers both receive',
      (tester) async {
    final watcher = BatteryWatcher(channel: channel);
    addTearDown(() async => watcher.dispose());

    final a = <bool>[];
    final b = <bool>[];
    final subA = watcher.onChargingChanged.listen(a.add);
    final subB = watcher.onChargingChanged.listen(b.add);
    addTearDown(subA.cancel);
    addTearDown(subB.cancel);

    await pushNative(tester, 'charging_changed', {'connected': true});

    expect(a, <bool>[true]);
    expect(b, <bool>[true]);
  });

  testWidgets('unknown method name is ignored (no emit)', (tester) async {
    final watcher = BatteryWatcher(channel: channel);
    addTearDown(() async => watcher.dispose());

    final emitted = <bool>[];
    final sub = watcher.onChargingChanged.listen(emitted.add);
    addTearDown(sub.cancel);

    await pushNative(tester, 'some_future_method', {'connected': true});

    expect(emitted, isEmpty);
  });

  testWidgets('malformed args are ignored (no emit, no crash)',
      (tester) async {
    final watcher = BatteryWatcher(channel: channel);
    addTearDown(() async => watcher.dispose());

    final emitted = <bool>[];
    final sub = watcher.onChargingChanged.listen(emitted.add);
    addTearDown(sub.cancel);

    // args is not a Map
    await pushNative(tester, 'charging_changed', 'not a map');
    // args map has wrong-typed value
    await pushNative(tester, 'charging_changed', {'connected': 'yes'});
    // args map missing the key
    await pushNative(tester, 'charging_changed', {'other': true});

    expect(emitted, isEmpty);
  });
}
