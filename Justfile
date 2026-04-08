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

pack-build id:
    @cd packs/{{id}} && [ -d node_modules ] || pnpm install --silent
    cd packs/{{id}} && pnpm exec vite build

pack-upload id: (pack-build id)
    cd packs/{{id}}/dist && zip -qr ../pack.zip .
    curl -fsS -X POST \
        -H "Authorization: Bearer ${HYACINTH_TOKEN:-}" \
        -F "id={{id}}" -F "type=zip" -F "file=@packs/{{id}}/pack.zip" \
        "${HYACINTH_SERVER:-http://localhost:8080}/packs"
    @echo ""
    @echo "✦ Uploaded {{id}} to ${HYACINTH_SERVER:-http://localhost:8080}"
    @echo "  Set the operator UI's content URL to: hyacinth://pack/{{id}}/index.html"
