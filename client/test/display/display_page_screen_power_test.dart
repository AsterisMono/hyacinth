// M9.1 — DisplayPage integration tests for the screenPowerError banner.
//
// The screen-power apply path now lives in AppState; DisplayPage only
// renders the latest error string (if any) as an errorContainer banner
// over the WebView. The reload-guard invariant still matters: rebuilding
// the page with a new screenPowerError MUST NOT remount the WebView.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/config/config_model.dart';
import 'package:hyacinth/display/display_page.dart';
import 'package:hyacinth/display/webview_controller.dart';
import 'package:hyacinth/system/brightness.dart';
import 'package:hyacinth/system/secure_settings.dart';

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
      'screenPowerError change preserves WebView Element identity',
      (tester) async {
    const cfg = HyacinthConfig(
      content: 'https://video.example/',
      contentRevision: 'r1',
      brightness: 'auto',
      screenTimeout: 'always-on',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DisplayPage(
          config: cfg,
          windowBrightness: _FakeWindowBrightness(),
          secureSettings: _FakeSecureSettings(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final elementBefore = tester.element(find.byType(HyacinthWebView));
    final widgetBefore = elementBefore.widget;

    // Flip screenPowerError on.
    await tester.pumpWidget(
      MaterialApp(
        home: DisplayPage(
          config: cfg,
          screenPowerError: 'Something broke',
          windowBrightness: _FakeWindowBrightness(),
          secureSettings: _FakeSecureSettings(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final elementAfter = tester.element(find.byType(HyacinthWebView));
    expect(
      identical(elementAfter, elementBefore),
      isTrue,
      reason: 'screenPowerError change must NOT rebuild the cached HyacinthWebView',
    );
    expect(
      identical(elementAfter.widget, widgetBefore),
      isTrue,
      reason: 'The cached HyacinthWebView widget instance must be reused.',
    );
    expect(find.text('Something broke'), findsOneWidget);

    // Clear it again.
    await tester.pumpWidget(
      MaterialApp(
        home: DisplayPage(
          config: cfg,
          windowBrightness: _FakeWindowBrightness(),
          secureSettings: _FakeSecureSettings(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final elementThird = tester.element(find.byType(HyacinthWebView));
    expect(identical(elementThird, elementBefore), isTrue);
    expect(find.text('Something broke'), findsNothing);
  });

  testWidgets(
      'screenPowerError renders the error string verbatim over the WebView',
      (tester) async {
    const cfg = HyacinthConfig(
      content: 'https://video.example/',
      contentRevision: 'r1',
      brightness: 'auto',
      screenTimeout: 'always-on',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DisplayPage(
          config: cfg,
          screenPowerError:
              'ScreenPower: no capability (need root or Device Admin)',
          windowBrightness: _FakeWindowBrightness(),
          secureSettings: _FakeSecureSettings(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('no capability'),
      findsOneWidget,
    );
    expect(find.byType(HyacinthWebView), findsOneWidget);
  });
}
