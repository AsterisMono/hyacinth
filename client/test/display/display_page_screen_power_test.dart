// M9 — DisplayPage integration tests for the ScreenPower layer.
//
// Two invariants:
//   1. Toggling `config.screenOn` MUST NOT rebuild the cached
//      HyacinthWebView (same Element identity across the toggle), and
//      the fake ScreenPower sees the apply() call.
//   2. When ScreenPower.apply() throws ScreenPowerUnavailable, the
//      DisplayPage renders an error banner over the WebView.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/config/config_model.dart';
import 'package:hyacinth/display/display_page.dart';
import 'package:hyacinth/display/webview_controller.dart';
import 'package:hyacinth/system/brightness.dart';
import 'package:hyacinth/system/screen_power.dart';
import 'package:hyacinth/system/secure_settings.dart';

class _FakeScreenPower implements ScreenPower {
  final List<bool> calls = <bool>[];
  bool throwUnavailable = false;

  @override
  Future<bool> isInteractive() async => true;

  @override
  Future<bool> isAdminActive() async => true;

  @override
  Future<void> requestAdmin() async {}

  @override
  Future<String> apply(bool screenOn) async {
    calls.add(screenOn);
    if (throwUnavailable) throw const ScreenPowerUnavailable();
    return 'admin';
  }
}

class _FakeWindowBrightness extends WindowBrightness {
  _FakeWindowBrightness() : super();
  @override
  Future<double> current() async => 1.0;
  @override
  Future<void> setOverride(double v) async {}
  @override
  Future<void> reset() async {}
}

class _FakeSecureSettings extends SecureSettings {
  _FakeSecureSettings() : super();
  @override
  Future<bool> hasPermission() async => false;
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

  testWidgets(
      'screenOn toggle preserves WebView Element identity and triggers apply',
      (tester) async {
    final sp = _FakeScreenPower();
    const cfg = HyacinthConfig(
      content: 'https://video.example/',
      contentRevision: 'r1',
      brightness: 'auto',
      screenTimeout: 'always-on',
      screenOn: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DisplayPage(
          config: cfg,
          windowBrightness: _FakeWindowBrightness(),
          secureSettings: _FakeSecureSettings(),
          screenPower: sp,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final elementBefore = tester.element(find.byType(HyacinthWebView));
    final widgetBefore = elementBefore.widget;

    // First apply (initial pump) passed `true`.
    expect(sp.calls, isNotEmpty);
    expect(sp.calls.last, isTrue);
    final countAfterInit = sp.calls.length;

    // Toggle screenOn → false.
    await tester.pumpWidget(
      MaterialApp(
        home: DisplayPage(
          config: cfg.copyWith(screenOn: false),
          windowBrightness: _FakeWindowBrightness(),
          secureSettings: _FakeSecureSettings(),
          screenPower: sp,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final elementAfter = tester.element(find.byType(HyacinthWebView));
    expect(
      identical(elementAfter, elementBefore),
      isTrue,
      reason: 'screenOn toggle must NOT rebuild the cached HyacinthWebView',
    );
    expect(
      identical(elementAfter.widget, widgetBefore),
      isTrue,
      reason: 'The cached HyacinthWebView widget instance must be reused.',
    );
    expect(sp.calls.length, greaterThan(countAfterInit));
    expect(sp.calls.last, isFalse);

    // Toggle back → true.
    await tester.pumpWidget(
      MaterialApp(
        home: DisplayPage(
          config: cfg.copyWith(screenOn: true),
          windowBrightness: _FakeWindowBrightness(),
          secureSettings: _FakeSecureSettings(),
          screenPower: sp,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final elementThird = tester.element(find.byType(HyacinthWebView));
    expect(identical(elementThird, elementBefore), isTrue);
    expect(sp.calls.last, isTrue);
  });

  testWidgets(
      'ScreenPowerUnavailable surfaces an error banner over the WebView',
      (tester) async {
    final sp = _FakeScreenPower()..throwUnavailable = true;
    const cfg = HyacinthConfig(
      content: 'https://video.example/',
      contentRevision: 'r1',
      brightness: 'auto',
      screenTimeout: 'always-on',
      screenOn: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DisplayPage(
          config: cfg,
          windowBrightness: _FakeWindowBrightness(),
          secureSettings: _FakeSecureSettings(),
          screenPower: sp,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Screen-off requested but no capability'),
      findsOneWidget,
    );
    // The WebView remains mounted — no cosmetic black overlay.
    expect(find.byType(HyacinthWebView), findsOneWidget);
  });
}
