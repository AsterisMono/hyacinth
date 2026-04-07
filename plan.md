# Hyacinth — Ita-Bag Display App

## Context
The user owns a tote bag with a transparent side window and wants to permanently mount an Android tablet inside it as an always-on "Ita-Bag" display. Hyacinth is a greenfield project: a Flutter Android app that acts as a home launcher and renders remote-driven content, paired with a tiny single-file Go server that publishes config and resource packs. The working directory `/home/nvirellia/Projects/hyacinth` is empty.

Goals:
- Tablet boots straight into Hyacinth (registered as launcher) and shows fullscreen, immersive content.
- Content + display settings (brightness, screen timeout) are pushed live from a self-hosted server.
- Content can be a remote URL or a locally-cached "resource pack" (zipped Vite build or single image), fetched only over Wi-Fi.
- Robust fallback UI (HealthCheck + Settings) when things aren't configured or working.

## Repo Layout
```
hyacinth/
├── client/                       # Flutter app
│   ├── android/app/src/main/AndroidManifest.xml
│   ├── android/app/src/main/res/xml/network_security_config.xml
│   ├── pubspec.yaml
│   └── lib/
│       ├── main.dart                    # Entry, routing on AppState
│       ├── app_state.dart               # State machine ChangeNotifier
│       ├── config/
│       │   ├── config_model.dart        # HyacinthConfig (with == for diffing)
│       │   └── config_store.dart        # SharedPreferences: server URL, last cfg
│       ├── net/
│       │   ├── config_client.dart       # GET /config
│       │   └── ws_client.dart           # /ws + reconnect/backoff/heartbeat
│       ├── display/
│       │   ├── display_page.dart        # Immersive WebView host
│       │   └── webview_controller.dart  # flutter_inappwebview wrapper, reload-guard
│       ├── fallback/
│       │   ├── main_activity_page.dart  # HealthCheck + Settings
│       │   ├── health_check.dart
│       │   └── settings_page.dart
│       ├── permissions/perm_manager.dart
│       ├── system/
│       │   ├── brightness.dart          # screen_brightness package
│       │   ├── keep_awake.dart          # wakelock_plus
│       │   ├── immersive.dart           # SystemChrome immersive sticky
│       │   ├── secure_settings.dart     # MethodChannel: Settings.Global/System via WRITE_SECURE_SETTINGS
│       │   ├── keyguard.dart            # DevicePolicyManager + KeyguardLock
│       │   └── cpu_governor.dart        # Root: write scaling_governor / scaling_max_freq
│       ├── resource_pack/
│       │   ├── pack_manager.dart        # ensure(), download, unzip, swap
│       │   ├── pack_cache.dart          # disk layout + GC
│       │   ├── wifi_guard.dart          # connectivity_plus
│       │   └── scheme_handler.dart      # app-scheme:// resolver
│       └── onboarding/onboarding_page.dart
└── server/
    ├── go.mod
    ├── server.go                 # Everything: handlers + inlined HTML/CSS/JS
    └── data/                     # config.json + packs/
```

## Android Manifest Essentials
- Permissions: `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `WAKE_LOCK`, `POST_NOTIFICATIONS` (API 33+), `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, `FOREGROUND_SERVICE`, **`WRITE_SECURE_SETTINGS`** (granted via `adb`/root `pm grant io.hyacinth android.permission.WRITE_SECURE_SETTINGS`), **`DISABLE_KEYGUARD`**.
- Main `<activity>` gets two intent filters: standard `MAIN/LAUNCHER` plus `CATEGORY_HOME + CATEGORY_DEFAULT` (home launcher). `showWhenLocked="true"` + `turnScreenOn="true"` so content reappears when waking.
- `android:launchMode="singleTask"`, `excludeFromRecents="true"`, `resizeableActivity="false"`.
- `network_security_config.xml` permitting cleartext only for private IP ranges.
- Custom `app-scheme://` is intercepted **inside** the WebView — does NOT need a manifest filter.
- **Device Admin receiver**: `<receiver android:name=".admin.HyacinthAdminReceiver" android:permission="android.permission.BIND_DEVICE_ADMIN">` with `DEVICE_ADMIN_ENABLED` intent filter and a `device_admin.xml` declaring `disable-keyguard-features` (and `force-lock` if we ever want `lockNow()`). User activates it via `DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN` in onboarding.

## State Machine
States: `Booting → Onboarding? → Connecting → Displaying ⇄ Reconnecting → Fallback`.

1. `main.dart` reads `ConfigStore`. If no server URL or onboarding incomplete → **Onboarding** (explain → request notifications → battery-opt exemption → home-role via `RoleManager` / `Settings.ACTION_HOME_SETTINGS` → enter server URL → save).
2. **Connecting**: run `HealthCheck`; basic fail → Fallback. Otherwise GET `/config`.
3. On success: apply brightness + screenTimeout, enable immersive, mount `DisplayPage` with initial `contentUrl`. Open WS in parallel.
4. **Displaying**: `WsClient` events call `applyConfig(new)`:
   - Brightness changed → update brightness only.
   - Timeout changed → update wakelock only.
   - `contentUrl + contentRevision` unchanged → **do nothing to WebView** (avoids flicker).
   - Otherwise → `webview.loadUrl(new.contentUrl)`.
   The ONLY path that calls `loadUrl` is `_maybeReloadContent(old, new)` guarded by URL+revision equality.
5. Errors (HTTP fail, WS drop past N retries, perm revoked) → Fallback, which keeps retrying in the background and auto-recovers to Displaying.
6. Re-apply immersive on `didChangeAppLifecycleState` (dialogs can break sticky immersive).

Fallback `MainActivity` page:
- HealthCheck rows with green/red + "Fix" buttons that fire the right intent.
- Settings: server URL field with "Test connection", "Re-request permissions", "Clear pack cache", "Reload now".

## Resource Packs
**Format**: single image (`png/jpg/webp/gif`) OR `.zip` containing a Vite `dist/` with `index.html` at archive root. Each pack has a server-side manifest: `{id, version, type, filename, sha256, size, createdAt}`.

**Device storage** (under `getApplicationSupportDirectory()`):
```
packs/<pack_id>/
  current  -> pointer file naming active version
  <version>/
    manifest.json
    content/         # unzipped files OR image.ext
```

**Resolution in WebView**: config `content` is either `https://…` or `app-scheme://pack/<id>/<path>`. Use `flutter_inappwebview`'s custom scheme handler (`resourceCustomSchemes` + `CustomSchemeResponse`) to map requests to files under `packs/<id>/current/content/`. Fallback option if scheme handler is fragile: tiny in-process loopback `HttpServer` on `127.0.0.1`. **Decide custom-scheme first; loopback only if it breaks.**

**Fetch strategy**:
- `WifiGuard` (connectivity_plus) gates downloads to `ConnectivityResult.wifi`. On mobile, defer + surface as a non-fatal health warning.
- `PackManager.ensure(packId)`: GET manifest → compare to local `current` → if version differs, GET download → stream to temp → verify sha256 → unzip into `<version>/content/` → atomically swap `current` pointer → keep last 1 version for rollback.
- Pre-warm before `loadUrl`. Manual "Clear pack cache" in fallback.

## Server (`server.go`)
Stdlib `net/http` + `nhooyr.io/websocket` (or `gorilla/websocket`). Single file. `data/config.json` and `data/packs/index.json` written via tmp + rename for atomicity. Mutex around mutations. WS broadcast via `map[*Conn]bool` + write mutex.

**Endpoints**
- `GET  /config` → JSON:
  ```json
  {
    "content": "app-scheme://pack/neko/index.html",
    "contentRevision": "2026-04-07T10:15:00Z",
    "brightness": "auto",
    "screenTimeout": "always-on"
  }
  ```
  (`brightness`: `"auto"` or 0–100; `screenTimeout`: `"always-on"` or duration like `"30s"`/`"5m"`.)

  Additional optional fields:
  - `disableKeyguard`: bool — if true, dismiss keyguard via DevicePolicyManager so the tablet wakes directly into the WebView (no swipe-to-unlock).
  - `powerProfile`: `"normal" | "ultra-low"` — when `"ultra-low"` and root is available, set CPU governor to `powersave` and clamp `scaling_max_freq` to the lowest available frequency while content is displayed; restore on Fallback / config change.
  - `touchInput`: `"enabled" | "disabled"` (default `"disabled"`) — when disabled, the Displaying state swallows all touch events so accidental bag bumps can't interact with the WebView. A long-press hot-corner (e.g. 5s in top-left) escapes to Fallback for maintenance.
- `PUT  /config` (operator) → replace; bump `contentRevision` if `content` changed; broadcast to WS.
- `GET  /ws` → WebSocket. Envelopes: `{"type":"config_update","config":{...}}`, `{"type":"ping"}`/`pong`. Client ignores unknown types (forward compat).
- `GET  /packs`, `GET /packs/{id}/manifest`, `GET /packs/{id}/download`.
- `POST /packs` (multipart: `id`, `type`, `file`) → validate (zip must contain `index.html`, or allowed image), sha256, write to `data/packs/<id>/<version>/`, update index.
- `DELETE /packs/{id}`.
- `GET  /` → inlined operator HTML (single Go `const indexHTML` with `<style>` + `<script>` blocks; mobile-first viewport, single column; sections for current config form (content URL select populated from `/packs` + free-form, brightness slider + auto toggle, timeout select) and pack list with upload + delete). Plain `fetch()`, no framework, no build step.
- All operator endpoints (`PUT /config`, `POST /packs`, `DELETE`) gated by a shared-secret token (header), even on LAN.

## Key Decisions Already Made
- **WebView**: `flutter_inappwebview` (custom scheme handlers + request interception). `webview_flutter` is insufficient.
- **Brightness**: prefer `screen_brightness` package (window brightness — no permission). For *system* brightness (so the value persists across wake), use `WRITE_SECURE_SETTINGS` granted via root `pm grant` to write `Settings.System.SCREEN_BRIGHTNESS` / `SCREEN_BRIGHTNESS_MODE`.
- **Screen timeout**: use `WRITE_SECURE_SETTINGS` to set `Settings.System.SCREEN_OFF_TIMEOUT` directly (cleaner than wakelock hacks). `"always-on"` → `Integer.MAX_VALUE`. Wakelock remains as a belt-and-suspenders.
- **Keyguard**: Device Admin receiver + `DevicePolicyManager.setKeyguardDisabledFeatures(KEYGUARD_DISABLE_FEATURES_ALL)`, plus `KeyguardManager.requestDismissKeyguard()` from the activity. Activated through onboarding (system dialog).
- **Touch blocking**: in `DisplayPage`, wrap the WebView in an `AbsorbPointer(absorbing: true)` (or `IgnorePointer`) above it, plus a transparent `Listener` overlay that *only* watches for the maintenance gesture (5-second press in a designated corner) to flip back to Fallback. The WebView itself never receives touches in this mode. Also call `getWindow().addFlags(FLAG_NOT_TOUCHABLE)` via MethodChannel as a second layer if needed (note: this would block our overlay too, so prefer the Flutter-side approach). For root devices, optionally `chmod 000` / `setenforce`-style tricks are NOT used — Flutter-side blocking is sufficient.
- **Root + CPU governor** (`powerProfile: "ultra-low"`): via a `Runtime.exec("su")` MethodChannel helper, write `powersave` to `/sys/devices/system/cpu/cpufreq/policy*/scaling_governor` and the lowest value from `scaling_available_frequencies` to `scaling_max_freq`. Restore previous values on teardown / when leaving Displaying. Treat root as optional — gracefully no-op (with health warning) if `su` fails.
- **Keep awake**: `wakelock_plus` + `FLAG_KEEP_SCREEN_ON`. Battery-opt exemption is required.
- **WS liveness**: app-side ping ~20s, exponential backoff with jitter. Add a foreground service later (M8) to hold the WS during Doze.
- **Cleartext**: scoped via `network_security_config.xml`, not global.
- **WebView security**: disable `file://`, allow only `https:` and the custom scheme.
- **Pack atomicity**: never unzip into `current/`; always to a version dir, then swap pointer.

## UI Style
All Flutter UI uses **Material You (Material Design 3)**: `useMaterial3: true` on `ThemeData`, `ColorScheme.fromSeed` (with a Hyacinth-purple seed), dynamic color where the device supports it (`dynamic_color` package), and Material 3 components throughout (`FilledButton`, `NavigationBar`, `Card`, `ListTile`, etc. — no Material 2 / Cupertino mixing). The Display page itself is bare WebView and exempt; all chrome (Onboarding, Fallback, Settings, future Operator-side mobile views) follows M3.

## Per-Milestone Testing Requirement
Every milestone MUST include real automated tests for the code it adds, and `flutter test` (client) + `go test ./...` (server) must be green before the milestone is marked complete. Tests should exercise behavior, not just construct widgets. Specifically:
- New units (state machines, parsers, clients, packers) get unit tests with hand-rolled fakes — no mockito.
- New widgets get at least one widget test that asserts a real invariant (rendered text, button presence, state-after-tap), not "it doesn't crash."
- Server endpoints get `httptest`-based tests covering happy path + one failure mode.
- A milestone with the excuse "tests need a real device" must still ship hermetic unit tests for whatever can be tested off-device.

## Build Order (Milestones)
- **M0 — Skeletons**: `flutter create client`, `go mod init`, empty `server.go` returning hardcoded `/config` JSON. Client GETs and prints. Prove end-to-end connectivity.
- **M1 — Minimum viable display**: `flutter_inappwebview` rendering an `https://` URL fullscreen + immersive + wakelock. Persist server URL.
- **M2 — Fallback + health + onboarding**: `AppState` machine, MainActivity fallback, HealthCheck, onboarding wizard, permission prompts, `CATEGORY_HOME` filter + home-role flow.
- **M2.5 — Material You audit + test backfill**: Convert all existing client UI (Onboarding, Fallback/MainActivity, Settings, loading/error screens) to Material You / Material Design 3 (`useMaterial3: true`, `ColorScheme.fromSeed`, `dynamic_color` where supported, M3 components). Backfill the per-milestone testing requirement for M0/M1/M2 wherever it's missing: hermetic unit tests for `HyacinthConfig`, `ConfigStore`, `ConfigClient` (with `package:http/testing` MockClient), `AppState` (transitions, fallback retry timer cancel-on-dispose, recheckPermissions flips out of `displaying` when a check goes red), and `HealthCheck`; widget tests for `OnboardingPage` covering all five steps via injected fakes; server-side `httptest` for `/config` and `/health`. Also wire the lifecycle-resume → `recheckPermissions()` hook that M2 deferred.
- **M3 — WebSocket live updates**: `/ws` broadcast on `PUT /config`. Client `WsClient` with reconnect. Implement and verify "don't reload if unchanged" guard (toggle brightness/timeout without WebView flicker).
- **M4 — Operator frontend inlined** in `server.go`.
- **M5 — Resource packs (image)**: upload/list/download, `PackManager` for images, `app-scheme://` handler, Wi-Fi guard, cache layout.
- **M6 — Resource packs (zip)**: zip validation, `archive` package unzip, atomic version swap, mime mapping, sha256 verify.
- **M7 — Brightness + timeout polish**: full `auto`/numeric brightness and `always-on`/duration timeout via `WRITE_SECURE_SETTINGS`. Document the one-time `pm grant` step in the README/onboarding.
- **M7.5 — Keyguard + power profile**: Device Admin receiver + onboarding step to enable it; keyguard-disable wired up. Root-gated CPU governor controller with restore-on-exit; surface root status in HealthCheck.
- **M8 — Hardening**: foreground service for WS, network security config, operator auth token, error telemetry in fallback, pack GC, tablet-specific tweaks.

After M3 you have a usable always-on display driven by the server. M5–M6 add offline-capable rich content without further client work.

## Critical Files
- `server/server.go`
- `client/android/app/src/main/AndroidManifest.xml`
- `client/android/app/src/main/res/xml/network_security_config.xml`
- `client/lib/main.dart`
- `client/lib/app_state.dart`
- `client/lib/display/webview_controller.dart` (the reload-guard lives here)
- `client/lib/resource_pack/pack_manager.dart`
- `client/lib/resource_pack/scheme_handler.dart`

## Verification (per milestone)
- **M0**: `go run server.go` → `curl localhost:PORT/config` returns JSON; Flutter app prints same JSON.
- **M1**: Install on tablet, launch shows fullscreen immersive WebView of a known site; screen does not sleep.
- **M2**: Press Home → Hyacinth is offered as launcher; revoking a permission flips UI to Fallback; "Test connection" works.
- **M3**: With WebView showing content, `PUT /config` changing only brightness updates brightness with **zero WebView reload** (verify by playing a video and confirming no interruption); changing `content` reloads.
- **M5/M6**: Upload an image pack via operator UI on phone; set config `content` to `app-scheme://pack/<id>/...`; tablet (on Wi-Fi) downloads, caches, displays. Toggle to mobile data → no re-download. Republish new version → tablet swaps on next `config_update`.
- **M8**: Leave tablet on for 24h with screen off cycles; WS reconnects survive Doze; immersive returns after dialogs.
