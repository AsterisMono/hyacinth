# Hyacinth

A dedicated-tablet kiosk stack: a Flutter/Android client that launches as `HOME` and renders a full-screen WebView of whatever the server tells it to, plus a small Go server that holds the current display config, serves an operator frontend at `/`, and pushes live updates over WebSocket. Designed for a single old Android tablet on the wall showing dashboards / photo frames / ambient displays, reconfigured on demand from any browser on the LAN.

## Layout

- `client/` — Flutter app (Android target). Home-role launcher, WebView display, onboarding, fallback/health screens.
- `server/` — Go HTTP + WebSocket server. Holds `HyacinthConfig`, serves operator UI.
- `Justfile` — task runner (see below).
- `plan.md` — milestone plan and context.

## Common commands

Recipes in the top-level `Justfile`. Run from the repo root.

- `just` — list all recipes.
- `just testall` — `flutter test` + `go test ./...`.
- `just analyze` — `flutter analyze` + `go vet ./...`.
- `just fmt` — `dart format .` + `go fmt ./...`.
- `just server-run` — run the Go server in the foreground.
- `just apk` — build a release APK (`client/build/app/outputs/flutter-apk/app-release.apk`).
- `just apk-debug` — build a debug APK.
- `just install` — build debug APK and `flutter install` it on a connected device.

### Installing `just`

On Fedora 43: `sudo dnf install just`. Via Cargo: `cargo install just`. See https://just.systems for other platforms.

## Granting `WRITE_SECURE_SETTINGS`

Brightness and screen-timeout enforcement (M7) use `WRITE_SECURE_SETTINGS`,
which Android does not let normal apps request via a system dialog.

**On rooted tablets (Magisk / KernelSU):** the onboarding wizard offers a
"Check for root and grant" step (M8.1). Tap it once, accept the Magisk
consent prompt, and Hyacinth will `pm grant` itself `WRITE_SECURE_SETTINGS`,
`POST_NOTIFICATIONS`, and the battery-optimization whitelist in one go.
The fallback HealthCheck screen also exposes a "Try grant via root" Fix
button on the brightness/timeout row if the grant ever gets dropped.

**Without root**, grant it once via `adb` after installing:

    adb shell pm grant io.hyacinth.hyacinth android.permission.WRITE_SECURE_SETTINGS

The grant survives reboot. Without it, Hyacinth falls back to window-only
brightness control and the configured screen timeout is ignored — the
wakelock keeps the display on while Hyacinth is in the foreground, but the
system `Settings.System.SCREEN_OFF_TIMEOUT` value itself is unchanged.

## Operator auth token (M8)

By default the Hyacinth server leaves its mutating endpoints (`PUT /config`,
`POST /packs`, `DELETE /packs/{id}`) open on the LAN. That's fine while you're
prototyping; for a real wall deployment, set a token:

    HYACINTH_TOKEN=$(openssl rand -hex 24) ./server-binary
    # or
    ./server-binary -token your-token-here

When the token is set, every mutating request must carry an
`Authorization: Bearer <token>` header. Read endpoints (`GET /config`,
`GET /health`, `GET /packs`, `GET /packs/{id}/manifest`,
`GET /packs/{id}/download`, the WS upgrade, the operator UI HTML) stay
open so the tablet can subscribe and render without baking secrets into
the APK. The operator UI has a "Token" button in the top-right that
saves the token to `localStorage` and attaches it to mutating fetches
automatically.

If no token is set at startup, the server logs a `WARNING` line on the
first line of output. That's intentional — it's a reminder that the LAN
is the only thing standing between strangers and your config.

## Network security config (M8)

Android 9+ blocks plain-HTTP traffic by default. Hyacinth ships with a
`network_security_config.xml` permitting cleartext for `localhost` and
`10.0.2.2` (the Android emulator's loopback). For a production tablet
on your home Wi-Fi, you have two options:

1. **Add your server's IP/hostname** to
   `client/android/app/src/main/res/xml/network_security_config.xml` as
   another `<domain>` entry inside the cleartext `<domain-config>` block,
   then rebuild the APK. Android's NSC schema does not accept CIDR
   ranges, so you have to enumerate hosts explicitly.
2. **Run the server over HTTPS** (e.g. behind a self-signed cert
   distributed via the system trust store). Then delete the cleartext
   `<domain-config>` block entirely. This is the right answer for any
   tablet that ever leaves the house.

## Screen on/off

Hyacinth's operator UI has "Screen off" and "Screen on" buttons that
fire imperative commands over the WebSocket. They are not persisted —
the next config push will not re-flip the screen.

The tablet acts on these commands using one of two paths:

1. **Root** (preferred): `su -c "input keyevent 223"` for off, `224`
   for on. Reliable. Works even after Doze kicks in.
2. **Device Admin** (fallback): `DevicePolicyManager.lockNow()` for
   off, a brief `FULL_WAKE_LOCK | ACQUIRE_CAUSES_WAKEUP` for on. The
   wake path is best-effort: it works as long as the WS connection
   survives. After ~10–30 minutes of sleep the system Doze policy
   kills the TCP socket and "Screen on" can no longer reach the
   device — only root's KEYCODE_WAKEUP wakes it from that state.

If you need reliable wake from deep sleep on a non-rooted tablet,
the realistic answer is to root it.

## End-to-end smoke checklist

Run this after every fresh deploy. The tablet is referred to as `T`,
the host running the server as `H`, and the operator browser as `B`.

1. On `H`: `cd server && HYACINTH_TOKEN=mytoken go run .`
2. On `T`: `flutter install` (or `adb install -r app-release.apk`).
3. On `T`: `adb shell pm grant io.hyacinth.hyacinth android.permission.WRITE_SECURE_SETTINGS`
4. On `T`: launch Hyacinth from the home screen. The onboarding page
   should accept `http://<H-ip>:8080` and proceed to the WebView.
5. On `B`: open `http://<H-ip>:8080/` in any browser, click "Token",
   paste `mytoken`. Verify the connection pill goes green.
6. On `B`: upload an image pack (any PNG), click "Use as content", click
   "Save". The tablet's display should update within ~1s.
7. On `T`: power-cycle the tablet. Hyacinth must launch automatically
   as `HOME` and reconnect to the WS without manual input.

## Status

- [x] M0 — Project skeletons
- [x] M1 — Minimum viable display
- [x] M2 — Fallback, health, onboarding, home role
- [x] M2.5 — Material You + test backfill
- [x] M3 — WebSocket live updates
- [x] M4 — Operator frontend (Material 3 via `@material/web`)
- [x] M4.5 — Justfile + first real APK build
- [x] M5 — Resource packs (image)
- [x] M6 — Resource packs (zip)
- [x] M7 — Brightness + timeout polish
- [x] M8 — Hardening (server error paths, auth, NSC, FGS, GC, docs)
