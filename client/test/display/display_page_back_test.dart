// M8.2: verify DisplayPage intercepts the system Back gesture and routes
// the event back up to its parent via the injected `onBackRequested`
// callback (which in production wires to `AppState.requestMainActivity`).
//
// We can't mount the real InAppWebView in `flutter test`, so we reuse the
// `debugSetWebViewBuilder` stub the other M3/M7 DisplayPage tests
// already install. PopScope intercepts are driven by finding the PopScope
// widget in the tree and invoking its `onPopInvokedWithResult(false, null)`
// directly — `tester.binding.handlePopRoute()` is a no-op when `canPop`
// is false because the Navigator short-circuits before the callback fires.

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

  const cfg = HyacinthConfig(
    content: 'https://video.example/',
    contentRevision: 'r1',
    brightness: 'auto',
    screenTimeout: 'always-on',
  );

  testWidgets(
      'back gesture while mounted invokes onBackRequested exactly once',
      (tester) async {
    var backCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DisplayPage(
          config: cfg,
          onBackRequested: () => backCount++,
        ),
      ),
    );
    // Settle any fire-and-forget async in initState so the PopScope is
    // definitely in the tree.
    await tester.pumpAndSettle();

    // Grab the PopScope guarding the DisplayPage tree and drive its
    // callback the way the framework would after the system emits a Back.
    final popScope = tester.widget<PopScope>(
      find.byWidgetPredicate((w) => w is PopScope),
    );
    expect(popScope.canPop, isFalse,
        reason:
            'DisplayPage must set canPop:false so Flutter does not tear '
            'down the route when Back is pressed.');

    popScope.onPopInvokedWithResult?.call(false, null);
    expect(backCount, 1);
  });

  testWidgets('onBackRequested is a no-op when not provided', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: DisplayPage(config: cfg)),
    );
    await tester.pumpAndSettle();

    final popScope = tester.widget<PopScope>(
      find.byWidgetPredicate((w) => w is PopScope),
    );
    // Must not throw — the null-aware `?.call` inside the page guards it.
    popScope.onPopInvokedWithResult?.call(false, null);
  });
}
