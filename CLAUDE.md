# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Hyacinth is a kiosk stack for a wall-mounted Android tablet: a Flutter client that renders a fullscreen WebView of whatever a small Go server tells it to, with live config push over WebSocket and a self-hosted operator UI. See `README.md` for installation, the `WRITE_SECURE_SETTINGS` grant flow, the operator auth token, the network security config story, and the end-to-end smoke checklist. See `plan.md` for milestone definitions and the design rationale behind every major decision (read it before proposing architectural changes — most "obvious" alternatives have already been considered and rejected with a written reason).

## Common commands

All recipes live in the top-level `Justfile` and must be run from the repo root. The README lists every recipe; the ones you'll use most:

- `just testall` — `flutter test` (runs from `client/`) + `go test ./...` (runs from `server/`). Both must be green before a milestone is considered complete (project rule).
- `just analyze` — `flutter analyze` + `go vet ./...`. Run after every non-trivial change.
- `just apk` — release APK at `client/build/app/outputs/flutter-apk/app-release.apk`. Slow first time, fast subsequently.
- `just apk-install` — `apk` + `adb install -r` to a connected device. Don't use this autonomously without explicit user consent.

Single-test commands (the Justfile has no recipes for these — invoke `flutter` / `go` directly from the right subdir):

- One Dart test file: `cd client && flutter test test/path/to/file_test.dart`
- One Dart test by name: `cd client && flutter test --plain-name "the test description"`
- One Go test: `cd server && go test ./... -run TestName -v`

Server toolchain: Go 1.25+, `github.com/gorilla/websocket`. Client toolchain: Flutter 3.41+, `flutter_inappwebview` 6.x.

## Architecture

Two halves connected by a JSON config and a WebSocket envelope contract.

### Server (`server/`, single Go module, two files)

`server.go` defines `hyacinthServer` (mutable `Config` behind `cfgMu`, WS connection set behind `connsMu`, exposed via `newServer(dataDir)` and `newMuxFor(srv)`). `packs.go` adds the resource pack endpoints. Both are wired through `recoverMiddleware` and `authMiddleware` (M8 hardening) so every request goes through panic recovery and bearer-token auth on mutating verbs.

Endpoints:

- `GET/PUT /config` — JSON config; `PUT` bumps `ContentRevision` only when `Content` changes (server-side half of the M3 reload guard).
- `GET /ws` — WebSocket. Sends an initial `{"type":"config_update","config":{...}}` envelope on connect, then broadcasts the same envelope on every successful `PUT /config`. Handles `{"type":"ping"}` → `{"type":"pong"}` at the application layer (not gorilla protocol-level pings). All writes are serialized via `connsMu` because gorilla's `*websocket.Conn` is not safe for concurrent writes.
- `GET /health` — `{"ok":true}`.
- `GET/POST /packs`, `GET/DELETE /packs/{id}`, `GET /packs/{id}/manifest`, `GET /packs/{id}/download` — pack CRUD. POST validates image type or zip-with-`index.html`-at-root, sha256s the body, atomically tmp+renames into `data/packs/<id>/<version>/`. Zip extraction goes into a `<version>.staging/` directory then atomically `os.Rename`s the whole tree to `<version>/`.
- `GET /` — inlined operator HTML (`const indexHTML` in `server.go`). Single-file SPA that imports `@material/web` from `https://esm.run/`, no build step. Has a dirty-flag so an in-flight edit is not clobbered by an incoming WS broadcast.

Server invariants: never panic (recover middleware), every error path returns a structured `ErrorBody{error, message}` via `writeError`, every `WriteMessage` is preceded by `SetWriteDeadline`, the read loop refreshes its deadline on every successful read, max 64 concurrent WS connections (503 before upgrade), explicit `http.Server` timeouts in `main()`, graceful SIGINT/SIGTERM shutdown.

### Client (`client/lib/`)

The client is built around a `ChangeNotifier` state machine (`AppState`) with these phases:

```
booting → (onboarding | connecting) → displaying ⇄ fallback
```

`main.dart` constructs the `AppState`, kicks `start()`, and routes the current phase to one of: a loading splash, `OnboardingPage`, `MainActivityPage` (the fallback page — confusingly the "main activity" UX-wise but `AppPhase.fallback` internally), or `DisplayPage` (the fullscreen WebView).

Key flow files and what they own:

- `app_state.dart` — the state machine. `_connect()` runs HealthCheck → fetches `/config` → ensures the resource pack if `content` is `hyacinth://pack/...` → opens the WebSocket → transitions to `displaying`. After `_ensurePackForConfig`, also fires `PackManager.syncToServer(preserveId: ...)` as fire-and-forget to garbage-collect packs that were deleted server-side. The 10s `Timer.periodic` retry timer in `fallback` keeps trying to climb back to `displaying`. `requestMainActivity()` and `returnToDisplaying()` (M8.2) implement the back-gesture round-trip while preserving `_config`.
- `display/display_page.dart` — the **reload guard** (plan.md L73, M3) lives here. `shouldReloadWebView(old, new)` returns true iff `content` or `contentRevision` changed; brightness/timeout-only updates leave the cached `HyacinthWebView` instance untouched, so a playing video does not flicker. Also owns immersive sticky, wakelock, brightness/timeout snapshot+apply+restore (M7), and the `PopScope(canPop: false)` that intercepts the back gesture.
- `display/webview_controller.dart` — `HyacinthWebView` wraps `InAppWebView`. Declares `resourceCustomSchemes: ['hyacinth']` and routes requests through `resolveHyacinthScheme`. Has a `debugSetWebViewBuilder` test seam because `InAppWebView` cannot mount in `flutter test` headless mode.
- `net/ws_client.dart` — owns reconnect with exponential backoff + jitter (1s start, 30s cap, ±20%), 20s application-layer ping, 45s idle timeout that force-reconnects. The `WsConnection` abstraction lets tests inject a fake transport without dialing a real socket.
- `resource_pack/` — `PackCache` (disk layout under `getApplicationSupportDirectory()/packs/<id>/<version>/{manifest.json,content/...}` with an atomic `current` pointer), `PackManager` (orchestrates manifest fetch → streaming sha256 verify → download to `<version>.staging/` → atomic rename → `swapCurrent` → gc old versions), `WifiGuard` (downloads gated to wifi/ethernet via `connectivity_plus`), `scheme_handler.dart` (`resolveHyacinthScheme` translates `hyacinth://pack/<id>/<rel/path>` into a local `File` via `PackCache.currentContentFileByPath`).
- `system/secure_settings.dart` — `MethodChannel('io.hyacinth/secure_settings')`, used by M7 for system brightness / `SCREEN_OFF_TIMEOUT`.
- `system/root_helper.dart` — `MethodChannel('io.hyacinth/root')` with **named** grant methods (`grantWriteSecureSettings`, `grantPostNotifications`, `whitelistBatteryOpt`, `hasRoot`). Never expose a generic `runAsRoot(cmd)` from Dart — the Kotlin side hardcodes the four command strings.
- `fallback/health_check.dart` — runs the M2 + M5 + M8.1 checks (server URL, server reachable, notifications, battery opt, wifi soft-warn, secure-settings warn, root info row). Each row carries an optional `fix` callback which the page renders as a "Fix" button.

### Custom URL scheme: `hyacinth://`

`config.content` is either `https://...` or `hyacinth://pack/<id>/<rel/path>`. The `hyacinth` scheme is **not** registered with Android — it lives entirely inside the WebView via `flutter_inappwebview`'s `resourceCustomSchemes` + `onLoadResourceWithCustomScheme` callback. `resolveHyacinthScheme` rejects unsafe rel paths (no `..`, no leading `/`) and returns `null` for non-`hyacinth` URLs so `https://` falls through to the WebView's normal loading path. (Named `hyacinth://` after a M8.2 rename from the original `app-scheme://`.)

### What the README says about being `HOME`

The README still says "launches as `HOME`". It's stale — **M4.8 stripped the launcher integration entirely**. Hyacinth is a normal Android app launchable from the drawer; users navigate to it like any other app. The user explicitly asked for this after M4.7's launcher-Home-gesture interception proved fragile. M8.2 restored "press Back from the WebView to access settings, press a button to return" via Activity-level `PopScope` instead. Don't try to re-add `CATEGORY_HOME` — it's been deliberately removed twice.

## Test conventions

- **Run from `client/`** for Dart, **from `server/`** for Go.
- **No mockito.** Hand-rolled fakes (subclass + override) or `package:http/testing` `MockClient`. Existing tests have established fake patterns (`_FakeWifi`, `_FakePackManager`, `_GrantedSecureSettings`, `_RecordingAppState`, etc.) — reuse and extend rather than inventing parallel ones.
- **Test seams come in two flavors:** (a) optional constructor parameters with sensible defaults (e.g. `DisplayPage({WindowBrightness? windowBrightness, SecureSettings? secureSettings, ...})`), or (b) global `debugSet*` functions for things that can't be plumbed through constructors (e.g. `debugSetWebViewBuilder` in `webview_controller.dart` because `InAppWebView` cannot render in test mode).
- **Real invariants only.** Widget tests should assert "this text appears" or "this Y coordinate is below that one", never just "the widget didn't crash". M5+ tests for the pack pipeline assert filesystem state (file exists / `currentVersion == n`).
- **Tests must touch real platform plugins as little as possible.** A `HealthCheck` constructed with no `wifiGuard`/`secureSettings` injection will hang the test isolate via `connectivity_plus`'s real method channel. Always inject. (See the M8.2 `_CachedConfigAppState` postmortem in commit `9e89a3b` for an example of this exact mistake.)
- **The current test count is around 199 client + 11 server.** A milestone that drops the count without explanation is suspicious.

## Conventions and gotchas

- **Per-milestone testing requirement** (project rule, codified in `plan.md`): every milestone ships hermetic unit tests for whatever can be tested off-device, and `just testall` must be green before reporting a milestone complete. "Needs a real device" is not an excuse for skipping logic tests.
- **Material You / Material 3 throughout** (project rule): all client UI uses `useMaterial3: true`, `ColorScheme.fromSeed(0xFF7E57C2)`, `dynamic_color` where supported, and Material 3 components (`FilledButton`, `Card`, `ListTile`, `NavigationBar`, etc.). The fullscreen `DisplayPage` is exempt; everything else is M3. The operator UI in `server.go` uses `@material/web` ESM.
- **R8 minification is disabled** in `client/android/app/build.gradle.kts` because `path_provider_android` (and probably other plugins) loads `io.flutter.util.PathUtils` reflectively. R8 strips it and you get a runtime `ClassNotFoundException`. A `proguard-rules.pro` with the canonical Flutter keep list is shipped so you can re-enable shrinking later if needed.
- **`AppPhase.fallback` is overloaded.** It's both the recovery state after a real error AND the rest state after the user pressed Back from `displaying`. Distinguish them by `_error == null`. The status footer in `MainActivityPage` reads this — it shows "Main activity" with a neutral icon when error is null, "Recovering" with a warning icon when an error is set. The word "Fallback" is internal jargon and should never appear in user-facing strings.
- **Don't re-add CATEGORY_HOME.** See the architecture note above.
- **The `_NeverChannel` test helper** (a single-subscription `StreamController` wrapped as a `WsConnection`) appears in two test files. If you need it in a third place, copy it again — it's tiny and the tests are deliberately self-contained.
- **The fallback retry timer in `AppState`** uses `Duration(seconds: 10)` in production. Tests that go through `AppState.start()` MUST pass `fallbackRetryInterval: const Duration(hours: 1)` to avoid pumping a real 10-second timer.
- **Pack cache lifecycle**: server delete does NOT propagate to the client by itself — `PackManager.syncToServer(preserveId)` runs as fire-and-forget after every `_connect()` and is the only path that GCs whole packs (M8.3). The currently-displayed pack is preserved even if the server says it's gone, so a transient operator delete doesn't yank the screen. `PackCache.gc(packId)` only trims old *versions* within a single pack.
- **Onboarding root step persistence**: `OnboardingPage._runRootProbe` writes through `widget.store ?? ConfigStore()` — earlier code only wrote when `widget.store != null`, which silently dropped the writes in production. If you touch this code path, keep the fallback construction.

## Milestone discipline

Every new feature or behavior change ships as a numbered milestone, written into `plan.md` *before* implementation, and committed with a `MX[.y]: <subject>` message. The plan is the single source of truth for "why does this exist and what's it supposed to do" — keep it fresh, don't let the code drift ahead of it.

When you take on a new feature:

1. Decide the milestone size yourself. **Large milestone `MX`** (e.g. `M9`) for substantial new surface area: a new subsystem, multi-file refactors, new permissions, new endpoints, new architectural concepts. **Small milestone `MX.y`** (e.g. `M9.1`, `M9.2`) for scoped work that builds on a recent large milestone: bug fixes flagged after a `MX` ships, polish/UX iteration, focused additions like one new endpoint or one new HealthCheck row, or anything the user describes as "also do X" while reviewing a recent milestone. The numbering is documentary, not regulatory — pick whichever scale matches what you're actually doing.
2. Pick the next free number. Read `plan.md` to find the current head; if the most recent committed milestone is `M9.2`, the next focused fix is `M9.3` and the next big thing is `M10`.
3. **Add a paragraph to `plan.md`** describing the milestone *before* dispatching the implementation. **Insert it in the canonically sorted position** — milestones in the "Build Order" list are sorted strictly by `(major, minor)` numerically, e.g. `M4`, `M4.5`, `M4.6`, …, `M4.10`, `M5`, …, `M8`, `M8.1`, `M8.2`. Don't append to the bottom; find the right slot. Keep the same shape as existing entries: lead with the goal, list the concrete deliverables, call out anything explicitly out of scope, and explain *why* if the rationale isn't obvious from the deliverables. This paragraph is what future readers (including future-you) will use to understand the change months later — write it for them.
4. **Dispatch the implementation via a sub-agent** (Agent tool, `general-purpose` type). Don't hand-write the code yourself in the main session unless the change is genuinely a one-line tweak. The sub-agent gets a focused, written brief with all the context it needs (file paths, current state, deliverables, out-of-scope, verification, self-review checklist), keeps the main session's context window small, and runs through `just testall` + `just apk` before reporting back. The sub-agent prompt is the second piece of durable documentation for the milestone — write it like a spec, not a TODO.
5. After the sub-agent reports back, verify its claims (don't just trust the report — read the diff, re-run `just testall` if anything looks off), then commit. The commit message subject is `MX[.y]: <short subject>`; the body explains the *why* and any non-obvious decisions.
6. If user feedback during the milestone reveals a related issue, you have two options: (a) bundle it into the same milestone if it's a tight fit and add a sentence to the plan paragraph, or (b) spin it off as a follow-up `MX.y+1`. Don't silently expand scope without a paper trail.

The history of the project is captured by reading the milestones in `plan.md` in order. If you're unsure why some piece exists or why it's structured the way it is, the answer is probably in there.
