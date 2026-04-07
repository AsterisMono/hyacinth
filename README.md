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

## Status

- [x] M0 — Project skeletons
- [x] M1 — Minimum viable display
- [x] M2 — Fallback, health, onboarding, home role
- [x] M2.5 — Material You + test backfill
- [x] M3 — WebSocket live updates
- [x] M4 — Operator frontend (Material 3 via `@material/web`)
- [x] M4.5 — Justfile + first real APK build
- [ ] M5 — Resource packs (image)
- [ ] M6 — Resource packs (zip)
- [ ] M7 — Brightness + timeout polish
- [ ] M8+ — see `plan.md`
