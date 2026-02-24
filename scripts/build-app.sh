#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Expander"
EXECUTABLE_NAME="TextExpander"
BUNDLE_ID="com.pablo.textexpander"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"

CONFIGURATION="release"
INSTALL_MODE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      CONFIGURATION="debug"
      shift
      ;;
    --release)
      CONFIGURATION="release"
      shift
      ;;
    --install)
      INSTALL_MODE="true"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--debug|--release] [--install]" >&2
      exit 1
      ;;
  esac
done

echo "Building $APP_NAME ($CONFIGURATION)..."
swift build --disable-sandbox --configuration "$CONFIGURATION"

BIN_DIR="$(swift build --disable-sandbox --configuration "$CONFIGURATION" --show-bin-path)"
EXECUTABLE_PATH="$BIN_DIR/$EXECUTABLE_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Executable not found at $EXECUTABLE_PATH" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" \
  "$APP_DIR" >/dev/null

if [[ "$INSTALL_MODE" == "true" ]]; then
  TARGET_DIR="$HOME/Applications"
  mkdir -p "$TARGET_DIR"
  rm -rf "$TARGET_DIR/$APP_NAME.app"
  cp -R "$APP_DIR" "$TARGET_DIR/$APP_NAME.app"
  /usr/bin/codesign --force --deep --sign - \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    "$TARGET_DIR/$APP_NAME.app" >/dev/null
  echo "Installed: $TARGET_DIR/$APP_NAME.app"
else
  echo "Created: $APP_DIR"
fi

echo "Done."
