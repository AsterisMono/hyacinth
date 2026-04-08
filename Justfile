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

# M15.1: live pack dev on the target device.
#
# When HYACINTH_SERVER is set and reachable, this recipe pushes the Vite
# `--host` dev URL onto the kiosk's /config so the tablet's WebView loads
# the dev server directly and Vite HMR patches modules in place on every
# source save — no upload round-trip per iteration. The original /config
# is restored on exit (Ctrl-C, normal exit, error) via a bash EXIT trap.
#
# When HYACINTH_SERVER is unset / unreachable / the LAN-IP detection
# fails, this recipe falls back to plain `pnpm exec vite` on localhost,
# preserving the desktop-browser preview path for "no tablet handy" days.
#
# Prerequisite for the on-device path: the tablet must be running a
# DEBUG-build APK (`just install`). The release NSC blocks cleartext
# HTTP to LAN IPs; the debug-build NSC overlay at
# client/android/app/src/debug/res/xml/network_security_config.xml
# permits it. A release-build tablet will silently refuse to load the
# Vite dev URL and the pack will appear blank.

# Live pack dev — push vite --host URL to the kiosk, restore on exit (M15.1)
pack-dev id:
    #!/usr/bin/env bash
    set -euo pipefail

    PACK_DIR="packs/{{id}}"
    if [ ! -d "$PACK_DIR" ]; then
        echo "pack-dev: $PACK_DIR does not exist — scaffold it first with the hyacinth-pack skill" >&2
        exit 1
    fi

    # Lazy pnpm install
    if [ ! -d "$PACK_DIR/node_modules" ]; then
        (cd "$PACK_DIR" && pnpm install --silent)
    fi

    SERVER="${HYACINTH_SERVER:-}"
    TOKEN="${HYACINTH_TOKEN:-}"

    # Graceful fallback: no server configured → plain local vite dev.
    if [ -z "$SERVER" ]; then
        echo "pack-dev: HYACINTH_SERVER not set — running local-only vite preview at http://localhost:5173/" >&2
        echo "pack-dev:   (set HYACINTH_SERVER + HYACINTH_TOKEN and re-run to push the dev URL to the tablet)" >&2
        cd "$PACK_DIR" && exec pnpm exec vite
    fi

    # jq is required for the JSON round-trip on /config.
    if ! command -v jq >/dev/null 2>&1; then
        echo "pack-dev: jq not found — install with:" >&2
        echo "pack-dev:   sudo dnf install jq     (Fedora)" >&2
        echo "pack-dev:   brew install jq         (macOS)" >&2
        echo "pack-dev:   sudo apt install jq     (Debian/Ubuntu)" >&2
        exit 1
    fi

    # Capture the current /config; any failure → graceful fallback to local preview.
    ORIGINAL_CONFIG=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$SERVER/config" 2>/dev/null || true)
    if [ -z "$ORIGINAL_CONFIG" ]; then
        echo "pack-dev: kiosk at $SERVER unreachable — continuing with local-only vite preview, tablet will not update live" >&2
        cd "$PACK_DIR" && exec pnpm exec vite
    fi

    # Extract the kiosk host (strip scheme + port) so `ip route get` can route to it.
    KIOSK_HOST=$(echo "$SERVER" | sed -E 's|^https?://||; s|/.*$||; s|:[0-9]+$||')

    # Detect the dev machine's LAN IP relative to the kiosk by asking the kernel
    # which interface it would use to reach KIOSK_HOST. Handles multi-homed
    # machines (wifi + docker0 + vpn) correctly because the answer is whichever
    # `src` the kernel picks for THIS specific destination.
    DEV_IP=$(ip route get "$KIOSK_HOST" 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    if [ -z "$DEV_IP" ]; then
        echo "pack-dev: could not detect LAN IP via 'ip route get $KIOSK_HOST' — continuing with local-only vite preview" >&2
        cd "$PACK_DIR" && exec pnpm exec vite
    fi

    DEV_URL="http://$DEV_IP:5173/"
    echo "pack-dev: pushing $DEV_URL to kiosk at $SERVER" >&2

    # Build the modified config JSON with content swapped.
    MODIFIED_CONFIG=$(echo "$ORIGINAL_CONFIG" | jq --arg url "$DEV_URL" '.content = $url')

    # PUT the modified config. Failure → fall back cleanly without setting the trap.
    if ! curl -fsS -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$MODIFIED_CONFIG" \
        "$SERVER/config" >/dev/null 2>&1; then
        echo "pack-dev: PUT /config failed — continuing with local-only vite preview" >&2
        cd "$PACK_DIR" && exec pnpm exec vite
    fi

    # EXIT trap restores the original config on Ctrl-C / normal exit / error.
    restore_config() {
        echo "" >&2
        echo "pack-dev: restoring original /config on kiosk" >&2
        curl -fsS -X PUT \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d "$ORIGINAL_CONFIG" \
            "$SERVER/config" >/dev/null 2>&1 || \
            echo "pack-dev: WARNING — failed to restore original config on kiosk, check manually" >&2
    }
    trap restore_config EXIT

    echo "pack-dev: vite --host starting; tablet should load $DEV_URL within ~1s" >&2
    echo "pack-dev: edit files under $PACK_DIR/ and the tablet will HMR live" >&2
    echo "pack-dev: Ctrl-C to stop and restore the original kiosk content" >&2

    cd "$PACK_DIR" && pnpm exec vite --host

# Build a pack: vite build → pack-lint (M15 offline-pure check)
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

# Lint a built pack — fail if dist/ contains any https:// reference (M15)
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
