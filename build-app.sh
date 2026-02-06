#!/bin/bash
set -e

EXEC_NAME="CDPlayer"
APP_NAME="CD Player"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

echo "Building $APP_NAME..."
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp "$BUILD_DIR/$EXEC_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Copy Info.plist
cp "Sources/Info.plist" "$APP_BUNDLE/Contents/"

# Copy icon if it exists
if [ -f "Sources/AppIcon.icns" ]; then
    cp "Sources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

echo "App bundle created at $APP_BUNDLE"
echo ""
echo "To install, run:"
echo "  cp -r \"$APP_BUNDLE\" /Applications/"
echo ""
echo "To run directly:"
echo "  open \"$APP_BUNDLE\""
