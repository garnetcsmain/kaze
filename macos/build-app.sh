#!/bin/bash
# Builds Kaze.app from the SPM package. No Xcode required (Command Line Tools only).
# Usage: ./build-app.sh [--debug]
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT="$(cd .. && pwd)"

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
    CONFIG="debug"
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --arch arm64

BUILD_BIN=".build/arm64-apple-macosx/$CONFIG/Kaze"
APP="dist/Kaze.app"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"

cp "$BUILD_BIN" "$APP/Contents/MacOS/Kaze"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Bundle whisper.cpp + model (reused from the Electron app's checked-in binaries)
if [[ -d "$REPO_ROOT/bin/darwin-arm64" ]]; then
    cp "$REPO_ROOT/bin/darwin-arm64/whisper" "$APP/Contents/Resources/bin/"
    mkdir -p "$APP/Contents/Resources/bin/models"
    cp "$REPO_ROOT/bin/darwin-arm64/models/ggml-base-q5_0.bin" "$APP/Contents/Resources/bin/models/"
    cp -R "$REPO_ROOT/bin/darwin-arm64/models/ggml-base-encoder.mlmodelc" "$APP/Contents/Resources/bin/models/"
else
    echo "WARNING: $REPO_ROOT/bin/darwin-arm64 not found — transcription will be disabled."
fi

# App icon from the Electron assets
ICON_SRC="$REPO_ROOT/src/electron/assets/icon.png"
if [[ -f "$ICON_SRC" ]]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 64 128 256 512 1024; do
        sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    done
    mv "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
    cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png" 2>/dev/null || true
    cp "$ICONSET/icon_64x64.png" "$ICONSET/icon_32x32@2x.png" 2>/dev/null || true
    rm -f "$ICONSET/icon_64x64.png"
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Prefer a stable self-signed identity so the Screen Recording / Microphone TCC grants
# survive rebuilds (ad-hoc signing changes the code hash every build and resets them).
# Create it once with macos/setup-signing.sh; falls back to ad-hoc if absent.
SIGN_IDENTITY="Kaze Local Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/kaze-signing.keychain-db"
if [[ -f "$SIGN_KEYCHAIN" ]] && security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "==> Codesigning with '$SIGN_IDENTITY' (stable identity)"
    security unlock-keychain -p kazelocal "$SIGN_KEYCHAIN" 2>/dev/null || true
    SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN")
else
    echo "==> Codesigning (ad-hoc — run setup-signing.sh for a stable identity)"
    SIGN_ARGS=(--force --sign -)
fi
codesign "${SIGN_ARGS[@]}" --entitlements Support/Kaze.entitlements \
    "$APP/Contents/Resources/bin/whisper" 2>/dev/null || true
codesign "${SIGN_ARGS[@]}" --entitlements Support/Kaze.entitlements "$APP"

echo "==> Done: macos/$APP"
echo "    Run with: open macos/$APP"
