// M7 brightness/timeout policy tests for DisplayPage.
//
// Uses fake `WindowBrightness` and `SecureSettings` injected through the
// constructor seams added in M7. The fakes record every call so we can
// assert exactly which methods were invoked, in which order, with which
// arguments. No mockito.
//
// The WebView is stubbed via the existing `debugSetWebViewBuilder` hook
// from the M3 reload-guard test — needed because the real
// `flutter_inappwebview` requires a platform view we can't mount headless.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/config/config_model.dart';
import 'package:hyacinth/display/display_page.dart';
import 'package:hyacinth/display/webview_controller.dart';
import 'package:hyacinth/system/brightness.dart';
import 'package:hyacinth/system/secure_settings.dart';

class FakeWindowBrightness extends WindowBrightness {
  FakeWindowBrightness() : super();

  final List<String> calls = <String>[];
  double currentValue = 0.7;

  @override
  Future<double> current() async {
    calls.add('current');
    return currentValue;
  }

  @override
  Future<void> setOverride(double v) async {
    calls.add('setOverride($v)');
  }

  @override
  Future<void> reset() async {
    calls.add('reset');
  }
}

class FakeSecureSettings extends SecureSettings {
  FakeSecureSettings({this.granted = true}) : super();

  final bool granted;
  final List<String> calls = <String>[];
  int? brightnessReturn = 100;
  int? brightnessModeReturn = 0;
  int? screenOffTimeoutReturn = 30000;

  @override
  Future<bool> hasPermission() async {
    calls.add('hasPermission->$granted');
    return granted;
  }

  @override
  Future<int?> currentBrightness() async {
    calls.add('currentBrightness');
    return brightnessReturn;
  }

  @override
  Future<int?> currentBrightnessMode() async {
    calls.add('currentBrightnessMode');
    return brightnessModeReturn;
  }

  @override
  Future<int?> currentScreenOffTimeout() async {
    calls.add('currentScreenOffTimeout');
    return screenOffTimeoutReturn;
  }

  @override
  Future<void> setBrightness(int value) async {
    calls.add('setBrightness($value)');
  }

  @override
  Future<void> setBrightnessMode(int mode) async {
    calls.add('setBrightnessMode($mode)');
  }

  @override
  Future<void> setScreenOffTimeout(int ms) async {
    calls.add('setScreenOffTimeout($ms)');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugSetWebViewBuilder((context, url) {
      return Container(
        key: const ValueKey<String>('stub-webview-body'),
        child: Text('stub:$url'),
      );
    });
  });

  tearDown(() {
    debugSetWebViewBuilder(null);
  });

  Future<void> mountAndSettle(
    WidgetTester tester, {
    required HyacinthConfig config,
    required FakeWindowBrightness wb,
    required FakeSecureSettings ss,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DisplayPage(
          config: config,
          windowBrightness: wb,
          secureSettings: ss,
        ),
      ),
    );
    // The snapshot+apply happens in a fire-and-forget future kicked off
    // from initState. Let it drain.
    await tester.pumpAndSettle();
  }

  testWidgets('brightness "50" sets window override to 0.5', (tester) async {
    final wb = FakeWindowBrightness();
    final ss = FakeSecureSettings(granted: false);
    await mountAndSettle(
      tester,
      config: const HyacinthConfig(
        content: 'https://x/',
        contentRevision: 'r1',
        brightness: '50',
        screenTimeout: 'always-on',
      ),
      wb: wb,
      ss: ss,
    );
    expect(
      wb.calls.any((c) => c == 'setOverride(0.5)'),
      isTrue,
      reason: 'wb calls were: ${wb.calls}',
    );
  });

  testWidgets('brightness "auto" calls window reset', (tester) async {
    final wb = FakeWindowBrightness();
    final ss = FakeSecureSettings(granted: false);
    await mountAndSettle(
      tester,
      config: const HyacinthConfig(
        content: 'https://x/',
        contentRevision: 'r1',
        brightness: 'auto',
        screenTimeout: 'always-on',
      ),
      wb: wb,
      ss: ss,
    );
    expect(wb.calls, contains('reset'));
  });

  testWidgets(
      'always-on + permission granted writes Integer.MAX_VALUE timeout',
      (tester) async {
    final wb = FakeWindowBrightness();
    final ss = FakeSecureSettings(granted: true);
    await mountAndSettle(
      tester,
      config: const HyacinthConfig(
        content: 'https://x/',
        contentRevision: 'r1',
        brightness: 'auto',
        screenTimeout: 'always-on',
      ),
      wb: wb,
      ss: ss,
    );
    expect(
      ss.calls.any((c) => c == 'setScreenOffTimeout(2147483647)'),
      isTrue,
      reason: 'ss calls were: ${ss.calls}',
    );
  });

  testWidgets('manual brightness writes system mode + value', (tester) async {
    final wb = FakeWindowBrightness();
    final ss = FakeSecureSettings(granted: true);
    await mountAndSettle(
      tester,
      config: const HyacinthConfig(
        content: 'https://x/',
        contentRevision: 'r1',
        brightness: '100',
        screenTimeout: 'always-on',
      ),
      wb: wb,
      ss: ss,
    );
    expect(ss.calls, contains('setBrightnessMode(0)'));
    expect(ss.calls, contains('setBrightness(255)'));
  });

  testWidgets('no permission → no system writes attempted', (tester) async {
    final wb = FakeWindowBrightness();
    final ss = FakeSecureSettings(granted: false);
    await mountAndSettle(
      tester,
      config: const HyacinthConfig(
        content: 'https://x/',
        contentRevision: 'r1',
        brightness: '50',
        screenTimeout: '30s',
      ),
      wb: wb,
      ss: ss,
    );
    expect(ss.calls.any((c) => c.startsWith('setBrightness')), isFalse);
    expect(ss.calls.any((c) => c.startsWith('setScreenOffTimeout')), isFalse);
    // But window brightness is still applied.
    expect(wb.calls, contains('setOverride(0.5)'));
  });

  testWidgets('didUpdateWidget reapplies brightness on change',
      (tester) async {
    final wb = FakeWindowBrightness();
    final ss = FakeSecureSettings(granted: false);
    const cfg = HyacinthConfig(
      content: 'https://x/',
      contentRevision: 'r1',
      brightness: '20',
      screenTimeout: 'always-on',
    );
    await mountAndSettle(tester, config: cfg, wb: wb, ss: ss);
    wb.calls.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: DisplayPage(
          config: cfg.copyWith(brightness: '80'),
          windowBrightness: wb,
          secureSettings: ss,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      wb.calls.any((c) => c == 'setOverride(0.8)'),
      isTrue,
      reason: 'wb calls after update were: ${wb.calls}',
    );
  });

  testWidgets('dispose attempts restoration', (tester) async {
    final wb = FakeWindowBrightness();
    final ss = FakeSecureSettings(granted: true)
      ..brightnessReturn = 90
      ..brightnessModeReturn = 1
      ..screenOffTimeoutReturn = 60000;
    await mountAndSettle(
      tester,
      config: const HyacinthConfig(
        content: 'https://x/',
        contentRevision: 'r1',
        brightness: '50',
        screenTimeout: '30s',
      ),
      wb: wb,
      ss: ss,
    );
    ss.calls.clear();
    wb.calls.clear();
    // Replace with an empty page to trigger DisplayPage.dispose.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(wb.calls, contains('reset'));
    expect(ss.calls, contains('setBrightnessMode(1)'));
    expect(ss.calls, contains('setBrightness(90)'));
    expect(ss.calls, contains('setScreenOffTimeout(60000)'));
  });
}
