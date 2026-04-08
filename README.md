# Hyacinth — Ita-Bag Display

I have a tote bag with a transparent side window. The kind meant for pinning enamel badges and holding up a single beloved plush. I wanted to put a screen in it instead — a small living window my bag carries around, showing whatever I tell it to. A rotating photo of the cat. A tiny dashboard. A lovingly hand-built HTML page that only lives for one afternoon and then gets replaced. A different mood every day I leave the house.

Hyacinth is the kiosk stack that makes the bag work. A Flutter/Android client runs on an old tablet wedged into the bag's display pocket and renders a fullscreen WebView of whatever the server tells it to. A small Go server holds the current display config, serves an operator frontend at `/`, and pushes live updates over WebSocket. The operator UI runs on any phone on the same Wi-Fi, so I can re-skin the bag mid-walk without ever touching the tablet itself.

The bag-mounted shape drives almost every design decision. The tablet is always in motion, always at the mercy of strap rubs and dust and pocket lint, and it must never draw attention to itself with a stray tap registering from a bag bump — M12 unconditionally blocks touches on the display, M11 auto-tunes the CPU governor to `powersave` while content is showing to stretch battery, M8's foreground service keeps the WebSocket alive through Doze, M9's operator UI lets me flip the screen off for a meeting with one tap. See `plan.md` for the full milestone trail and the design rationale behind every major decision.

The client is a normal Android app launched from the app drawer (M4.7 tried wiring it as the system launcher and that proved fragile; M4.8 stripped launcher integration entirely). The system Back gesture from the fullscreen display drops me into the MainActivity / settings page; a "Return to content" button takes me back.

## Layout

- `client/` — Flutter app (Android target). WebView display, onboarding, fallback/settings/health screens.
- `server/` — Go HTTP + WebSocket server. Holds `HyacinthConfig`, embeds the operator UI from `operator.html` via `//go:embed`.
- `packs/` — Vite-built content packs (one subdirectory per pack id). Built with `just pack-build <id>` and uploaded with `just pack-upload <id>`. Scaffold new ones via the `hyacinth-pack` skill.
- `Justfile` — task runner (see below).
- `plan.md` — milestone plan and context.
- `CLAUDE.md` — guidance for future Claude Code sessions on this repo.

## Common commands

Recipes in the top-level `Justfile`. Run from the repo root.

- `just` — list all recipes.
- `just testall` — `flutter test` + `go test ./...`.
- `just analyze` — `flutter analyze` + `go vet ./...`.
- `just fmt` — `dart format .` + `go fmt ./...`.
- `just server-run` — run the Go server in the foreground.
- `just apk` — build a release APK (`client/build/app/outputs/flutter-apk/app-release.apk`).
- `just apk-debug` — build a debug APK.
- `just apk-install` — build the release APK and `adb install -r` it on a connected device.
- `just install` — build the debug APK and `flutter install` it on a connected device.

Content pack recipes (require `pnpm` — install via `corepack enable`, ships with Node 16.13+):

- `just pack-dev <id>` — live pack dev on the target tablet (M15.1). With `HYACINTH_SERVER` + `HYACINTH_TOKEN` set, pushes the `vite --host` dev URL onto the kiosk's `/config` and Vite HMR patches the running pack on every save; restores the original config on exit. Without env vars (or if the kiosk is unreachable) it falls back to a plain local `vite` preview at `http://localhost:5173/`. Requires `jq` for the `/config` round-trip.
- `just pack-build <id>` — `vite build` then `pack-lint` (the M15 offline-pure invariant: zero `https://` references in `dist/`, namespace URIs whitelisted).
- `just pack-upload <id>` — build, zip `dist/`, `POST /packs` to the kiosk (uses `HYACINTH_SERVER` and `HYACINTH_TOKEN`).

## Granting `WRITE_SECURE_SETTINGS`

Brightness and screen-timeout enforcement (M7) use `WRITE_SECURE_SETTINGS`,
which Android does not let normal apps request via a system dialog.

**On rooted tablets (Magisk / KernelSU):** the onboarding wizard offers a
"Check for root and grant" step (M8.1). Tap it once, accept the Magisk
consent prompt, and Hyacinth will `pm grant` itself `WRITE_SECURE_SETTINGS`,
`POST_NOTIFICATIONS`, and the battery-optimization whitelist in one go.
The fallback HealthCheck screen also exposes a Fix button on the
"System brightness/timeout permission" row that re-runs the root grant
if it ever gets dropped (the row is a soft `warn` rather than a hard
fail, so missing the grant doesn't push the app into permanent
fallback — the wakelock and window-brightness fallback keep things
working).

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

## Screen on/off

Hyacinth's operator UI has "Screen off" and "Screen on" buttons in
the Display section's actions row (next to Save) that fire imperative
commands over the WebSocket via a `POST /screen` endpoint. They are
**not** persisted — the next config push will not re-flip the screen.

The tablet acts on these commands using one of two paths:

1. **Root** (preferred): `su -c "input keyevent 223"` for off, `224`
   for on. Reliable. Works even after Doze kicks in.
2. **Device Admin** (fallback): `DevicePolicyManager.lockNow()` for
   off, a brief `FULL_WAKE_LOCK | ACQUIRE_CAUSES_WAKEUP` for on. The
   wake path is best-effort: it works as long as the WS connection
   survives. After ~10–30 minutes of sleep the system Doze policy
   kills the TCP socket and "Screen on" can no longer reach the
   device — only root's KEYCODE_WAKEUP wakes it from that state.

If neither tier is available, the operator's screen-off command
fails fast: the tablet shows an error banner reading "Screen-off
requested but no capability — grant Device Admin or root in
Settings", and the HealthCheck "Screen-off capability" row reports
the failure with a Fix button that fires the system Add-device-admin
dialog.

If you need reliable wake from deep sleep on a non-rooted tablet,
the realistic answer is to root it.

## Status

Major milestones (the small `MX.y` follow-ups are documented in `plan.md`):

- [x] M0 — Project skeletons
- [x] M1 — Minimum viable display
- [x] M2 — Fallback, health, onboarding (`+M2.5` Material You + test backfill)
- [x] M3 — WebSocket live updates
- [x] M4 — Operator frontend (Material 3 via `@material/web`) (`+M4.5–M4.10` Justfile, APK install recipe, launcher experiment + strip, tablet landscape layout, gorilla/websocket swap)
- [x] M5 — Resource packs (image)
- [x] M6 — Resource packs (zip)
- [x] M7 — Brightness + timeout polish
- [x] M8 — Hardening: server error paths, auth, NSC, foreground service, pack GC (`+M8.1` root self-grant, `+M8.2` back gesture → MainActivity, `+M8.3` pack cache sync + wipe, `+M8.4` cached packs display)
- [x] M9 — Remote screen on/off (root + Device Admin) (`+M9.1–M9.8` operator UI redesign and iteration)
- [x] M10 — GitHub Actions CI + tag-driven releases (analyze / test / apk on every push and PR; `release` job publishes `hyacinth-<version>.apk` to GitHub Releases on `v*` tags)
- [x] M11 — Auto powersave CPU governor on display (root-gated, tied to the `displaying` phase lifecycle — no operator UI, no config field; finishes the M7.5 power-profile half)
- [x] M12 — Touch blocking on display (unconditional `IgnorePointer` over the WebView while `displaying`; back gesture still escapes via M8.2's route-level `PopScope`)
- [x] M13 — Auto screen on/off on charging state changes (charger connected → screen off, disconnected → screen on; reuses M9.1's `ScreenPower` codepath via a programmatic `BroadcastReceiver` and a `BatteryWatcher` stream — no operator override, no second copy of the tier orchestration)
- [x] M14 — Operator UI: vellum herbarium redesign (M9.2's bold purple Material You interface re-skinned to match the herbarium content aesthetic; operator HTML extracted into `server/operator.html` and `//go:embed`-ed) (`+M14.1` readable-ink contrast pass, deeper ink on cream paper to clear WCAG AA)
- [x] M15 — Offline-pure content packs (build-time font bundling via `vite-plugin-webfont-dl`, enforced by `pack-lint`'s zero-`https://` invariant) (`+M15.1` `pack-dev` live-on-tablet HMR loop, `+M15.2` standard-Web-API device telemetry for packs (`navigator.getBattery()` + clock readout), `+M15.3` dropped the release-build network security config so debug and release builds are now in lockstep over cleartext LAN)
