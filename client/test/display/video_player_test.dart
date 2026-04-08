// M16 — HyacinthVideoPlayer widget tests + DisplayPage renderer-selection
// tests for the video pack path.
//
// We can't mount the real `chewie` / `video_player` chain in headless
// `flutter test` (it needs ExoPlayer / a platform view), so the tests
// install a stub VideoPlayerBuilder that returns a Container tagged with
// the file path it was asked to render. Mirrors the existing
// `debugSetWebViewBuilder` seam used by the M3 reload-guard test.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/config/config_model.dart';
import 'package:hyacinth/display/display_page.dart';
import 'package:hyacinth/display/video_player.dart';
import 'package:hyacinth/display/webview_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Stub both renderers so DisplayPage can mount in test mode regardless
    // of which path it picks.
    debugSetWebViewBuilder((context, url) {
      return Container(
        key: const ValueKey<String>('stub-webview-body'),
        child: Text('stub:webview:$url'),
      );
    });
    debugSetVideoPlayerBuilder((context, file) {
      return Container(
        key: const ValueKey<String>('stub-video-body'),
        child: Text('stub:video:${file.path}'),
      );
    });
  });

  tearDown(() {
    debugSetWebViewBuilder(null);
    debugSetVideoPlayerBuilder(null);
  });

  group('HyacinthVideoPlayer (with debug builder)', () {
    testWidgets('mounts the injected stub instead of touching chewie',
        (tester) async {
      final tmp = File('${Directory.systemTemp.path}/m16-stub.mp4');
      await tester.pumpWidget(
        MaterialApp(home: HyacinthVideoPlayer(file: tmp)),
      );
      // The stub builder returns a Container with the known key.
      expect(
        find.byKey(const ValueKey<String>('stub-video-body')),
        findsOneWidget,
      );
      // And the file path is plumbed through.
      expect(find.text('stub:video:${tmp.path}'), findsOneWidget);
    });
  });

  group('DisplayPage renderer selection (M16)', () {
    const cfg = HyacinthConfig(
      content: 'hyacinth://pack/loop/video.mp4',
      contentRevision: 'r1',
      brightness: 'auto',
      screenTimeout: 'always-on',
    );

    testWidgets('mp4 path: mounts HyacinthVideoPlayer, NOT HyacinthWebView',
        (tester) async {
      final tmp = File('${Directory.systemTemp.path}/m16-loop.mp4');
      await tester.pumpWidget(
        MaterialApp(
          home: DisplayPage(config: cfg, videoFile: tmp),
        ),
      );
      expect(find.byType(HyacinthVideoPlayer), findsOneWidget);
      expect(find.byType(HyacinthWebView), findsNothing);
      // Sanity: the stub video Container body is on screen.
      expect(
        find.byKey(const ValueKey<String>('stub-video-body')),
        findsOneWidget,
      );
    });

    testWidgets('null videoFile: falls back to HyacinthWebView',
        (tester) async {
      const httpsCfg = HyacinthConfig(
        content: 'https://video.example/',
        contentRevision: 'r1',
        brightness: 'auto',
        screenTimeout: 'always-on',
      );
      await tester.pumpWidget(
        MaterialApp(home: DisplayPage(config: httpsCfg)),
      );
      expect(find.byType(HyacinthWebView), findsOneWidget);
      expect(find.byType(HyacinthVideoPlayer), findsNothing);
    });

    testWidgets(
        'reload guard: brightness-only change preserves video Element identity',
        (tester) async {
      final tmp = File('${Directory.systemTemp.path}/m16-loop.mp4');
      await tester.pumpWidget(
        MaterialApp(
          home: DisplayPage(config: cfg, videoFile: tmp),
        ),
      );
      final elementBefore =
          tester.element(find.byType(HyacinthVideoPlayer));
      final widgetBefore = elementBefore.widget;

      // Brightness-only update — must not rebuild the video renderer.
      await tester.pumpWidget(
        MaterialApp(
          home: DisplayPage(
            config: cfg.copyWith(brightness: '40'),
            videoFile: tmp,
          ),
        ),
      );
      final elementAfter =
          tester.element(find.byType(HyacinthVideoPlayer));
      expect(
        identical(elementAfter, elementBefore),
        isTrue,
        reason: 'Brightness-only updates must not remount the video player; '
            'a new Element means playback would restart.',
      );
      expect(
        identical(elementAfter.widget, widgetBefore),
        isTrue,
        reason: 'The cached HyacinthVideoPlayer widget instance must be '
            'reused so the underlying VideoPlayerController is not '
            'disposed and re-initialised.',
      );
    });

    testWidgets('reload guard: contentRevision bump replaces the video widget',
        (tester) async {
      final tmp = File('${Directory.systemTemp.path}/m16-loop.mp4');
      await tester.pumpWidget(
        MaterialApp(
          home: DisplayPage(config: cfg, videoFile: tmp),
        ),
      );
      final widgetBefore =
          tester.widget(find.byType(HyacinthVideoPlayer));

      await tester.pumpWidget(
        MaterialApp(
          home: DisplayPage(
            config: cfg.copyWith(contentRevision: 'r2'),
            videoFile: tmp,
          ),
        ),
      );
      final widgetAfter =
          tester.widget(find.byType(HyacinthVideoPlayer));
      expect(
        identical(widgetAfter, widgetBefore),
        isFalse,
        reason: 'A revision bump MUST produce a new HyacinthVideoPlayer '
            'so the video file source is reloaded.',
      );
    });

    // M12 regression: the IgnorePointer wrap must apply to the video
    // renderer too, not just the WebView. The wrap lives at the renderer
    // slot in DisplayPage.build(), so this is mostly a structural check
    // that the refactor didn't break it for the video flavour.
    testWidgets('M12: IgnorePointer wraps the video renderer in the mp4 path',
        (tester) async {
      final tmp = File('${Directory.systemTemp.path}/m16-loop.mp4');
      await tester.pumpWidget(
        MaterialApp(
          home: DisplayPage(config: cfg, videoFile: tmp),
        ),
      );

      final ourIgnoreFinder = find.byWidgetPredicate(
        (w) => w is IgnorePointer && w.ignoring == true,
      );
      expect(ourIgnoreFinder, findsOneWidget);

      // The video player must be a descendant of our IgnorePointer.
      expect(
        find.descendant(
          of: ourIgnoreFinder,
          matching: find.byType(HyacinthVideoPlayer),
        ),
        findsOneWidget,
      );
    });
  });
}
