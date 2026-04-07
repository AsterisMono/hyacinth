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
