import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// M16 — native video pack renderer.
///
/// `HyacinthVideoPlayer` is the second renderer slot inside `DisplayPage`,
/// chosen instead of `HyacinthWebView` whenever the resolved pack manifest
/// type is `mp4`. It wraps `chewie` over a `VideoPlayerController.file(...)`
/// configured for kiosk playback: autoplay, looping, no controls, no
/// fullscreen toggle, audio explicitly muted (the kiosk has no speaker
/// surface). The video is rendered at its native aspect ratio inside a
/// black letterbox so portrait clips don't stretch on the landscape tablet.
///
/// The renderer takes a resolved local [File] rather than a `hyacinth://`
/// URL — `video_player`'s file source goes straight to ExoPlayer/Media3
/// without an HTTP loop, so we sidestep the WebView's custom-scheme handler
/// entirely. `AppState._ensurePackForConfig` resolves the file path via
/// [PackCache.currentContentFileByPath] before transitioning to
/// `displaying`, so by the time this widget mounts the underlying bytes
/// are guaranteed to exist on disk.
///
/// All the system hooks Hyacinth has accumulated since M5 — M7 brightness
/// / timeout, M8.2 back gesture, M9.1 screen power, M11 CPU powersave,
/// M12 IgnorePointer touch block, M13 charging-state gating — live in
/// `DisplayPage`'s lifecycle and wrap whichever renderer is mounted, so
/// this widget itself owns nothing beyond playback.
typedef VideoPlayerBuilder = Widget Function(BuildContext context, File file);

/// Process-wide override. Tests inject a stub builder via
/// [debugSetVideoPlayerBuilder] so the chewie/`video_player` platform
/// channel chain (which doesn't work in `flutter test` headless mode) is
/// never reached. Mirrors the `debugSetWebViewBuilder` seam in
/// `webview_controller.dart`.
VideoPlayerBuilder? _debugVideoPlayerBuilder;

/// Test-only seam. Pass `null` to restore the real chewie path.
@visibleForTesting
void debugSetVideoPlayerBuilder(VideoPlayerBuilder? builder) {
  _debugVideoPlayerBuilder = builder;
}

class HyacinthVideoPlayer extends StatefulWidget {
  const HyacinthVideoPlayer({super.key, required this.file});

  final File file;

  @override
  State<HyacinthVideoPlayer> createState() => _HyacinthVideoPlayerState();
}

class _HyacinthVideoPlayerState extends State<HyacinthVideoPlayer> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  Object? _initError;

  @override
  void initState() {
    super.initState();
    // If a test has injected a builder, skip the entire chewie/video_player
    // initialization path — the stub renderer in tests doesn't need a
    // controller.
    if (_debugVideoPlayerBuilder != null) {
      return;
    }
    _initController();
  }

  Future<void> _initController() async {
    final controller = VideoPlayerController.file(widget.file);
    try {
      await controller.initialize();
      await controller.setVolume(0);
      await controller.setLooping(true);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      final chewie = ChewieController(
        videoPlayerController: controller,
        autoPlay: true,
        looping: true,
        showControls: false,
        allowFullScreen: false,
        allowMuting: false,
        aspectRatio: controller.value.aspectRatio == 0
            ? 16 / 9
            : controller.value.aspectRatio,
        placeholder: const SizedBox.expand(
          child: ColoredBox(color: Colors.black),
        ),
      );
      setState(() {
        _videoController = controller;
        _chewieController = chewie;
      });
    } catch (e) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _initError = e;
      });
    }
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final override = _debugVideoPlayerBuilder;
    if (override != null) {
      return override(context, widget.file);
    }
    if (_initError != null) {
      return const ColoredBox(
        color: Colors.black,
        child: SizedBox.expand(),
      );
    }
    final chewie = _chewieController;
    if (chewie == null) {
      return const ColoredBox(
        color: Colors.black,
        child: SizedBox.expand(),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: chewie.aspectRatio ?? 16 / 9,
          child: Chewie(controller: chewie),
        ),
      ),
    );
  }
}
