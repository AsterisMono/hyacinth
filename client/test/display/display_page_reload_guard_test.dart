// Reload-guard tests for the M3 DisplayPage.
//
// We can't mount the real `InAppWebView` in headless `flutter test` (it
// needs a platform view), so the test installs a stub WebViewBuilder that
// returns a Container tagged with the URL it was asked to render. The
// guard is then exercised at two levels:
//
//   1. The pure `shouldReloadWebView(old, new)` predicate.
//   2. A real widget pump: render `DisplayPage` with config A, capture the
//      Element backing the inner HyacinthWebView, pump again with
//      brightness-only changes, and assert the SAME Element is preserved
//      (no rebuild). Then pump with a content change and assert the
//      Element is replaced.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/config/config_model.dart';
import 'package:hyacinth/display/display_page.dart';
import 'package:hyacinth/display/webview_controller.dart';

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

  group('shouldReloadWebView (pure predicate)', () {
    const a = HyacinthConfig(
      content: 'https://a.example/',
      contentRevision: 'r1',
      brightness: 'auto',
      screenTimeout: 'always-on',
    );

    test('false when only brightness changes', () {
      expect(shouldReloadWebView(a, a.copyWith(brightness: '40')), isFalse);
    });

    test('false when only screenTimeout changes', () {
      expect(shouldReloadWebView(a, a.copyWith(screenTimeout: '30s')), isFalse);
    });

    test('true when content changes', () {
      expect(
        shouldReloadWebView(a, a.copyWith(content: 'https://b.example/')),
        isTrue,
      );
    });

    test('true when contentRevision changes', () {
      expect(
        shouldReloadWebView(a, a.copyWith(contentRevision: 'r2')),
        isTrue,
      );
    });
  });

  testWidgets('brightness-only change preserves WebView Element instance',
      (tester) async {
    const cfg = HyacinthConfig(
      content: 'https://video.example/',
      contentRevision: 'r1',
      brightness: 'auto',
      screenTimeout: 'always-on',
    );
    await tester.pumpWidget(MaterialApp(home: DisplayPage(config: cfg)));
    final elementBefore =
        tester.element(find.byType(HyacinthWebView));
    final widgetBefore = elementBefore.widget;

    // Brightness-only update.
    await tester.pumpWidget(
      MaterialApp(
        home: DisplayPage(config: cfg.copyWith(brightness: '40')),
      ),
    );
    final elementAfter = tester.element(find.byType(HyacinthWebView));
    expect(
      identical(elementAfter, elementBefore),
      isTrue,
      reason: 'Element identity must be preserved across brightness changes; '
          'a new element means the WebView was remounted (= reload flicker).',
    );
    expect(
      identical(elementAfter.widget, widgetBefore),
      isTrue,
      reason:
          'The cached HyacinthWebView widget instance must be reused so the '
          'underlying native WebView is not torn down.',
    );
  });

  testWidgets('contentRevision change replaces the WebView Element',
      (tester) async {
    const cfg = HyacinthConfig(
      content: 'https://video.example/',
      contentRevision: 'r1',
      brightness: 'auto',
      screenTimeout: 'always-on',
    );
    await tester.pumpWidget(MaterialApp(home: DisplayPage(config: cfg)));
    final widgetBefore = tester.widget(find.byType(HyacinthWebView));

    await tester.pumpWidget(
      MaterialApp(
        home: DisplayPage(config: cfg.copyWith(contentRevision: 'r2')),
      ),
    );
    final widgetAfter = tester.widget(find.byType(HyacinthWebView));
    expect(
      identical(widgetAfter, widgetBefore),
      isFalse,
      reason: 'A revision bump MUST produce a new HyacinthWebView widget so '
          'the InAppWebView is remounted with the new URL.',
    );
  });

  testWidgets('content change replaces the WebView Element', (tester) async {
    const cfg = HyacinthConfig(
      content: 'https://a.example/',
      contentRevision: 'r1',
      brightness: 'auto',
      screenTimeout: 'always-on',
    );
    await tester.pumpWidget(MaterialApp(home: DisplayPage(config: cfg)));
    final widgetBefore = tester.widget(find.byType(HyacinthWebView));

    await tester.pumpWidget(
      MaterialApp(
        home: DisplayPage(config: cfg.copyWith(content: 'https://b.example/')),
      ),
    );
    final widgetAfter = tester.widget(find.byType(HyacinthWebView));
    expect(identical(widgetAfter, widgetBefore), isFalse);
  });

  // M12 — the WebView is wrapped in an unconditional IgnorePointer so bag
  // bumps / dust / strap rubs can't interact with whatever's displayed.
  // The wrapping is inside the DisplayPage's Stack, scoped only to the
  // WebView subtree (the screen-power error banner is a sibling in the
  // Stack and stays tappable).
  testWidgets('M12: IgnorePointer wraps the WebView and ignores touches',
      (tester) async {
    const cfg = HyacinthConfig(
      content: 'https://a.example/',
      contentRevision: 'r1',
      brightness: 'auto',
      screenTimeout: 'always-on',
    );
    await tester.pumpWidget(MaterialApp(home: DisplayPage(config: cfg)));

    // Flutter's Material framework (Scaffold et al.) introduces several
    // IgnorePointer widgets with `ignoring: false` for internal layout
    // reasons, so we can't `findsOneWidget` on the bare type — instead
    // pick the one with `ignoring: true`, which is unambiguously ours.
    final ourIgnoreFinder = find.byWidgetPredicate(
      (w) => w is IgnorePointer && w.ignoring == true,
    );
    expect(ourIgnoreFinder, findsOneWidget);

    // The WebView must be a descendant of our IgnorePointer — not a
    // sibling in the Stack.
    expect(
      find.descendant(
        of: ourIgnoreFinder,
        matching: find.byType(HyacinthWebView),
      ),
      findsOneWidget,
    );
  });
}
