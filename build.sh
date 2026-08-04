#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR="$ROOT_DIR/build"
OUTPUT_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$OUTPUT_DIR/VideoWallpaper.app"
SAVER_BUNDLE="$BUILD_DIR/VideoWallpaperLockScreen.saver"

rm -rf "$BUILD_DIR" "$APP_BUNDLE"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

mkdir -p "$SAVER_BUNDLE/Contents/MacOS"
cp "$ROOT_DIR/Resources/SaverInfo.plist" "$SAVER_BUNDLE/Contents/Info.plist"

swiftc \
  -O \
  "$ROOT_DIR/Sources/LockScreenSaver/LockScreenSaver.swift" \
  "$ROOT_DIR/Sources/Shared/LocalWallpaperSchemeHandler.swift" \
  -emit-library \
  -module-name VideoWallpaperLockScreen \
  -framework AppKit \
  -framework AVFoundation \
  -framework QuartzCore \
  -framework ScreenSaver \
  -framework UniformTypeIdentifiers \
  -framework WebKit \
  -Xlinker -install_name \
  -Xlinker @rpath/VideoWallpaperLockScreen \
  -o "$SAVER_BUNDLE/Contents/MacOS/VideoWallpaperLockScreen"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ROOT_DIR/Resources/AppInfo.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/Resources/MenuBarTemplate.png" "$APP_BUNDLE/Contents/Resources/MenuBarTemplate.png"
cp "$ROOT_DIR/Resources/MemoryCachePolicy.json" "$APP_BUNDLE/Contents/Resources/MemoryCachePolicy.json"
cp "$ROOT_DIR/THIRD-PARTY-NOTICES.md" "$APP_BUNDLE/Contents/Resources/THIRD-PARTY-NOTICES.md"
cp -R "$SAVER_BUNDLE" "$APP_BUNDLE/Contents/Resources/VideoWallpaperLockScreen.saver"

swiftc \
  -O \
  "$ROOT_DIR/Sources/VideoWallpaperApp/main.swift" \
  "$ROOT_DIR/Sources/VideoWallpaperApp/RemoteWebWallpaperDownloader.swift" \
  "$ROOT_DIR/Sources/VideoWallpaperApp/WallpaperEngineScene.swift" \
  "$ROOT_DIR/Sources/VideoWallpaperApp/SystemAudioSpectrumCapture.swift" \
  "$ROOT_DIR/Sources/Shared/LocalWallpaperSchemeHandler.swift" \
  -framework AppKit \
  -framework Accelerate \
  -framework AVFoundation \
  -framework ImageIO \
  -lcompression \
  -framework QuartzCore \
  -framework ScreenCaptureKit \
  -framework UniformTypeIdentifiers \
  -framework WebKit \
  -o "$APP_BUNDLE/Contents/MacOS/VideoWallpaper"

chmod +x "$APP_BUNDLE/Contents/MacOS/VideoWallpaper"
chmod +x "$APP_BUNDLE/Contents/Resources/VideoWallpaperLockScreen.saver/Contents/MacOS/VideoWallpaperLockScreen"

if command -v codesign >/dev/null 2>&1; then
  SIGNING_IDENTITY=${VIDEO_WALLPAPER_SIGNING_IDENTITY:-}
  if [ -z "$SIGNING_IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -Fq '"VideoWallpaper Local Code Signing"'; then
    SIGNING_IDENTITY="VideoWallpaper Local Code Signing"
  fi
  if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=-
  fi
  codesign --force --sign "$SIGNING_IDENTITY" "$APP_BUNDLE/Contents/Resources/VideoWallpaperLockScreen.saver"
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
  echo "Signed with: $SIGNING_IDENTITY"
fi

echo "$APP_BUNDLE"
