# Hyacinth — top-level task runner.
# See README.md for details. Requires `just` (https://just.systems).

# Default: list recipes
default:
    @just --list

# Run all tests (client + server)
testall:
    cd client && flutter test
    cd server && go test ./...

# Static analysis (client + server)
analyze:
    cd client && flutter analyze
    cd server && go vet ./...

# Format both sides
fmt:
    cd client && dart format .
    cd server && go fmt ./...

# Run the Go server (foreground)
server-run:
    cd server && go run .

# Build a release APK
apk:
    cd client && flutter build apk --release

# Build a debug APK
apk-debug:
    cd client && flutter build apk --debug

# Install the debug APK on a connected device
install: apk-debug
    cd client && flutter install

# Install the release APK on a connected device via adb
apk-install: apk
    adb install -r client/build/app/outputs/flutter-apk/app-release.apk

# ----- Hyacinth content packs (see .claude/skills/hyacinth-pack/SKILL.md)
# Requires pnpm — install via `npm install -g pnpm` or `corepack enable`
# (recommended: corepack, ships with Node 16.13+).
# Lazy install: node_modules is created on first dev/build, reused thereafter.
# Override server + auth via env: HYACINTH_SERVER, HYACINTH_TOKEN.

pack-dev id:
    @cd packs/{{id}} && [ -d node_modules ] || pnpm install --silent
    cd packs/{{id}} && pnpm exec vite

pack-build id: (_pack-vite-build id) (pack-lint id)

_pack-vite-build id:
    @cd packs/{{id}} && [ -d node_modules ] || pnpm install --silent
    cd packs/{{id}} && pnpm exec vite build

# M15 offline-pure invariant: built dist/ must contain zero https:// refs.
# `http://www.w3.org/...` is an XML/SVG namespace URI, never a network fetch,
# so it's whitelisted. Everything else (CDN scripts, Google Fonts links the
# vite-plugin-webfont-dl plugin missed, hotlinked images, fetch() calls) is
# a hard fail — operators run `just pack-build <id>` locally and the lint
# prevents a pack with a network dependency from being zipped.
pack-lint id:
    #!/usr/bin/env bash
    set -euo pipefail
    matches=$(grep -rEn "https?://[^\"' )]+" packs/{{id}}/dist 2>/dev/null | grep -v "www\.w3\.org" || true)
    if [ -n "$matches" ]; then
        echo "✗ pack {{id}} has network references in dist/:"
        echo "$matches"
        exit 1
    fi
    echo "✓ pack {{id}} is offline-pure (no https:// references in dist)"

pack-upload id: (pack-build id)
    cd packs/{{id}}/dist && zip -qr ../pack.zip .
    curl -fsS -X POST \
        -H "Authorization: Bearer ${HYACINTH_TOKEN:-}" \
        -F "id={{id}}" -F "type=zip" -F "file=@packs/{{id}}/pack.zip" \
        "${HYACINTH_SERVER:-http://localhost:8080}/packs"
    @echo ""
    @echo "✦ Uploaded {{id}} to ${HYACINTH_SERVER:-http://localhost:8080}"
    @echo "  Set the operator UI's content URL to: hyacinth://pack/{{id}}/index.html"

# Resume claude code session
claude:
    claude --resume Hyacinth-Main --dangerously-skip-permissions
