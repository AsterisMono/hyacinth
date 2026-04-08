import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/config_model.dart';
import '../resource_pack/pack_cache.dart';
import '../system/brightness.dart';
import '../system/config_policy.dart';
import '../system/cpu_governor.dart';
import '../system/secure_settings.dart';
import 'video_player.dart';
import 'webview_controller.dart';

/// Top-level fullscreen display surface.
///
/// Given a resolved [HyacinthConfig], renders the configured content in
/// either a [HyacinthWebView] (`https://` URLs and image / zip packs) or
/// a [HyacinthVideoPlayer] (M16 mp4 video packs). Immersive sticky mode
/// is applied at construction and re-applied when the app resumes. A
/// wakelock keeps the screen on while this widget is mounted.
///
/// **Renderer selection (M16)**: the inner renderer is chosen at
/// [State.initState] (and re-chosen on each reload-guard rebuild) by
/// inspecting [videoFile]. When [videoFile] is non-null, [HyacinthVideoPlayer]
/// is mounted; otherwise [HyacinthWebView] is mounted against
/// `config.content`. The choice is driven by [AppState], which resolves
/// the pack manifest before transitioning to `displaying` and exposes the
/// resolved local file when the manifest type is `mp4`.
///
/// **Reload guard (M3)**: the inner renderer widget is constructed once
/// in [State.initState] and only re-created in [didUpdateWidget] when
/// [shouldReloadWebView] returns true. Brightness/timeout-only config
/// updates therefore rebuild the [DisplayPage] but leave the renderer's
/// element/state untouched, so a playing video / WebView animation does
/// not flicker. The same predicate covers both renderer flavours because
/// the only thing that triggers a renderer swap is a `content` /
/// `contentRevision` change, and `videoFile` is derived from that same
/// pair upstream in [AppState].
///
/// **M7 brightness/timeout**: on mount we snapshot the current system
/// brightness mode + value + screen-off timeout (if `WRITE_SECURE_SETTINGS`
/// is granted), then apply the config-specified values. Window brightness
/// is always applied as a best-effort fallback for the no-permission case.
/// On unmount we reset the window override and (if we have a snapshot)
/// restore the system values.
class DisplayPage extends StatefulWidget {
  const DisplayPage({
    super.key,
    required this.config,
    this.packCache,
    this.videoFile,
    this.onBackRequested,
    this.screenPowerError,
    WindowBrightness? windowBrightness,
    SecureSettings? secureSettings,
    CpuGovernor? cpuGovernor,
  })  : _windowBrightness = windowBrightness,
        _secureSettings = secureSettings,
        _cpuGovernorInjected = cpuGovernor;

  final HyacinthConfig config;

  /// M16 — when non-null, mount [HyacinthVideoPlayer] over this resolved
  /// local file instead of the WebView. Set by [AppState] when the resolved
  /// pack manifest type is `mp4`. Null for `https://` content URLs and for
  /// image / zip packs (which still go through the WebView path).
  final File? videoFile;

  /// M9.1 — most recent screen-power error from [AppState]. When non-null
  /// a red banner is rendered over the WebView with this string. The
  /// banner is orthogonal to everything else — no reload guard interaction,
  /// no brightness/timeout coupling.
  final String? screenPowerError;

  /// Invoked when the user triggers the system Back gesture from the
  /// fullscreen display. The parent (`HyacinthApp`) wires this to
  /// `AppState.requestMainActivity` so control returns to the M3
  /// MainActivityPage. Left null in widget-only tests that don't care
  /// about the back path.
  final VoidCallback? onBackRequested;

  /// Pack cache used by the WebView's `app-scheme://` resolver. Optional
  /// — when null, only `https://` content URLs work.
  final PackCache? packCache;

  /// Test seam for the M7 window-brightness layer. Production code
  /// leaves this null and a default `WindowBrightness()` is built in
  /// [State.initState].
  final WindowBrightness? _windowBrightness;

  /// Test seam for the M7 secure-settings layer. Production code leaves
  /// this null and a default `SecureSettings()` is built in
  /// [State.initState].
  final SecureSettings? _secureSettings;

  /// Test seam for the M11 CPU-governor layer. Production code leaves
  /// this null and a default `CpuGovernor()` is built in
  /// [State.initState].
  final CpuGovernor? _cpuGovernorInjected;

  @override
  State<DisplayPage> createState() => _DisplayPageState();
}

/// Pure predicate that decides whether the WebView must be remounted.
///
/// Per plan.md L73: `contentUrl + contentRevision unchanged → do nothing
/// to WebView`. We treat ANY change in either field as a reload trigger,
/// and brightness/timeout changes alone as no-ops.
bool shouldReloadWebView(HyacinthConfig oldCfg, HyacinthConfig newCfg) {
  return oldCfg.content != newCfg.content ||
      oldCfg.contentRevision != newCfg.contentRevision;
}

/// Snapshot of system-side display settings captured on entering the
/// displaying phase. Restored on leave. All fields nullable because the
/// underlying getter may return null when permission is missing or the
/// setting has never been written.
class _SystemDisplaySnapshot {
  const _SystemDisplaySnapshot({
    this.brightness,
    this.brightnessMode,
    this.screenOffTimeoutMs,
  });

  final int? brightness;
  final int? brightnessMode;
  final int? screenOffTimeoutMs;
}

class _DisplayPageState extends State<DisplayPage>
    with WidgetsBindingObserver {
  /// The active inner renderer — either a [HyacinthWebView] or a
  /// [HyacinthVideoPlayer]. Reassigned only when the M3 reload guard
  /// fires; brightness/timeout-only updates leave it untouched so the
  /// underlying playback/scroll state survives.
  late Widget _renderer;
  late final WindowBrightness _windowBrightness;
  late final SecureSettings _secureSettings;
  late final CpuGovernor _cpuGovernor;
  _SystemDisplaySnapshot? _snapshot;
  bool _hasSecurePermission = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enterImmersive();
    WakelockPlus.enable();
    _windowBrightness = widget._windowBrightness ?? WindowBrightness();
    _secureSettings = widget._secureSettings ?? SecureSettings();
    _cpuGovernor = widget._cpuGovernorInjected ?? CpuGovernor();
    _renderer = _buildRenderer();
    // Fire-and-forget. We deliberately don't await this in initState — the
    // renderer mounts immediately and brightness/timeout are best-effort.
    // ignore: discard_returned_future
    _snapshotAndApply();
  }

  /// Build the inner renderer for the current widget config. Called from
  /// [initState] and from the [didUpdateWidget] reload-guard branch.
  /// Centralised so the renderer-selection logic lives in one place.
  Widget _buildRenderer({Key? key}) {
    final videoFile = widget.videoFile;
    if (videoFile != null) {
      return HyacinthVideoPlayer(key: key, file: videoFile);
    }
    return HyacinthWebView(
      key: key,
      url: widget.config.content,
      packCache: widget.packCache,
    );
  }

  Future<void> _snapshotAndApply() async {
    try {
      _hasSecurePermission = await _secureSettings.hasPermission();
    } catch (e) {
      debugPrint('SecureSettings.hasPermission failed: $e');
      _hasSecurePermission = false;
    }
    if (_hasSecurePermission) {
      _snapshot = _SystemDisplaySnapshot(
        brightness: await _secureSettings.currentBrightness(),
        brightnessMode: await _secureSettings.currentBrightnessMode(),
        screenOffTimeoutMs: await _secureSettings.currentScreenOffTimeout(),
      );
    }
    if (!mounted) return;
    await _applyPolicy(widget.config);
    // M11 — fire-and-forget powersave entry. Must happen strictly after
    // brightness apply so a failure here (no root, no cpufreq, etc.)
    // never blocks the display from rendering. The CpuGovernor wrapper
    // already swallows all errors but we wrap again defensively.
    try {
      // ignore: discard_returned_future
      _cpuGovernor.enterPowersave();
    } catch (e) {
      debugPrint('CpuGovernor.enterPowersave threw: $e');
    }
  }

  Future<void> _applyPolicy(HyacinthConfig cfg) async {
    final brightness = parseBrightness(cfg.brightness);
    final timeout = parseScreenTimeout(cfg.screenTimeout);

    // Window brightness — always-on layer, no permission required.
    try {
      switch (brightness) {
        case BrightnessAuto():
          await _windowBrightness.reset();
        case BrightnessManual(level: final l):
          await _windowBrightness.setOverride(l / 100.0);
      }
    } catch (e) {
      debugPrint('window brightness apply failed: $e');
    }

    if (!_hasSecurePermission) return;

    // System brightness — persists across wake. Only when granted.
    try {
      switch (brightness) {
        case BrightnessAuto():
          await _secureSettings.setBrightnessMode(1);
        case BrightnessManual(level: final l):
          await _secureSettings.setBrightnessMode(0);
          await _secureSettings.setBrightness((l / 100.0 * 255).round());
      }
    } on SecureSettingsDenied catch (e) {
      debugPrint('system brightness denied: $e');
      _hasSecurePermission = false;
    } catch (e) {
      debugPrint('system brightness apply failed: $e');
    }

    // Screen-off timeout.
    try {
      switch (timeout) {
        case TimeoutAlwaysOn():
          await _secureSettings
              .setScreenOffTimeout(SecureSettings.alwaysOnTimeoutMs);
        case TimeoutDuration(value: final d):
          await _secureSettings.setScreenOffTimeout(d.inMilliseconds);
      }
    } on SecureSettingsDenied catch (e) {
      debugPrint('screen timeout denied: $e');
      _hasSecurePermission = false;
    } catch (e) {
      debugPrint('screen timeout apply failed: $e');
    }
  }

  @override
  void didUpdateWidget(covariant DisplayPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The reload guard. We only rebuild the inner renderer when content or
    // revision actually changed. Brightness/timeout-only updates hit this
    // branch with `shouldReloadWebView == false`, so the cached _renderer
    // is reused — Flutter sees the same widget instance, the element tree
    // is preserved, and the underlying native WebView / VideoPlayer never
    // sees a reload. The same predicate covers both renderer flavours
    // because `videoFile` is derived from `content` upstream in
    // [AppState], so the only way `videoFile` changes is via a
    // content/revision change that is already caught here.
    if (shouldReloadWebView(oldWidget.config, widget.config)) {
      _renderer = _buildRenderer(
        // Bump the key so Flutter throws the old element away and the
        // new renderer mounts with the new URL / file. Without a fresh
        // key identical-type widgets get reused and the change is silently
        // dropped.
        key: ValueKey<String>(
          '${widget.config.content}#${widget.config.contentRevision}',
        ),
      );
    }
    // Reapply policy (brightness / timeout) if any of the relevant fields
    // actually changed. Screen power is driven imperatively via
    // `screen_command` envelopes on the WS channel (M9.1), not via config.
    final brightnessChanged =
        oldWidget.config.brightness != widget.config.brightness;
    final timeoutChanged =
        oldWidget.config.screenTimeout != widget.config.screenTimeout;
    if (brightnessChanged || timeoutChanged) {
      // ignore: discard_returned_future
      _applyPolicy(widget.config);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Best-effort restoration. We deliberately don't await — dispose
    // must return synchronously and the platform calls are fire-and-forget.
    // ignore: discard_returned_future
    _restore();
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      await _windowBrightness.reset();
    } catch (e) {
      debugPrint('window brightness reset failed: $e');
    }
    // M11 — restore CPU governor snapshot. Fire-and-forget, never throws.
    try {
      // ignore: discard_returned_future
      _cpuGovernor.restore();
    } catch (e) {
      debugPrint('CpuGovernor.restore threw: $e');
    }
    final snap = _snapshot;
    if (snap == null || !_hasSecurePermission) return;
    try {
      if (snap.brightnessMode != null) {
        await _secureSettings.setBrightnessMode(snap.brightnessMode!);
      }
      if (snap.brightness != null) {
        await _secureSettings.setBrightness(snap.brightness!);
      }
      if (snap.screenOffTimeoutMs != null) {
        await _secureSettings.setScreenOffTimeout(snap.screenOffTimeoutMs!);
      }
    } catch (e) {
      debugPrint('system display restore failed: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _enterImmersive();
    }
  }

  void _enterImmersive() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // canPop: false — intercept the Back gesture so Flutter does NOT
      // pop the route out from under us. We hand the event up to AppState
      // via the injected callback, which transitions to fallback and
      // re-mounts MainActivityPage through the normal phase-router path.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        widget.onBackRequested?.call();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // M12 — touch blocking. The kiosk runs bag-mounted, so accidental
            // bumps / strap rubs / dust should never interact with whatever
            // the renderer is showing. Unconditional: the renderer is only
            // ever mounted in the `displaying` phase, so tying the
            // IgnorePointer to mount lifetime is equivalent to tying it to
            // the phase. The back gesture is unaffected — Android delivers
            // it as a route pop event via PopScope, not as a touch through
            // the widget tree, so IgnorePointer is irrelevant to that path.
            // The IgnorePointer wraps ONLY the renderer, not the screen-power
            // error banner below, so the banner (and any future tap target
            // on it) stays interactive. M16: this also wraps the
            // [HyacinthVideoPlayer] when a video pack is showing, with no
            // change required — touch-blocking is renderer-agnostic.
            SizedBox.expand(
              child: IgnorePointer(ignoring: true, child: _renderer),
            ),
            if (widget.screenPowerError != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        widget.screenPowerError ?? '',
                        style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
