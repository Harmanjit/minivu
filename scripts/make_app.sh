#!/bin/bash
# Builds build/minivu.app from the SwiftPM release binary.
#
# SwiftPM produces a bare executable plus a resource bundle; macOS wants an
# .app folder with an Info.plist so the app has a Dock icon, can be the
# default viewer for image types, and can be signed with the sandbox:
#
#   build/minivu.app/Contents/Info.plist
#   build/minivu.app/Contents/MacOS/minivu
#   build/minivu.app/Contents/Resources/minivu_MinivuRender.bundle   (shaders)
#   build/minivu.app/Contents/Resources/minivu_Minivu.bundle         (help pages)
#   build/minivu.app/Contents/Resources/AppIcon.icns                 (from Assets, made by make_icon.swift)
#
# Usage: scripts/make_app.sh [version] [--dev]
#   --dev  skip the sandbox (lets `open build/minivu.app --args <path>` reach
#          any folder while testing).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.9.1"
DEV=0
for arg in "$@"; do
  case "$arg" in
    --dev) DEV=1 ;;
    *) VERSION="$arg" ;;
  esac
done

echo "Building release…"
swift build -c release --product minivu 2>&1 | tail -1

APP="build/minivu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/minivu "$APP/Contents/MacOS/minivu"
# Local symbols are for the debugger; without them the binary is half the
# size (11.7 MB to 5.9 MB). Crash reports still name the global symbols.
strip -x "$APP/Contents/MacOS/minivu"
# Both resource bundles, found in Contents/Resources by Bundle.minivuRender
# and Bundle.minivuHelp. Without the second, Help shows "Page Unavailable".
cp -R .build/release/minivu_MinivuRender.bundle "$APP/Contents/Resources/"
cp -R .build/release/minivu_Minivu.bundle "$APP/Contents/Resources/"
cp Assets/AppIcon.icns "$APP/Contents/Resources/"

# Precompile shaders when the Metal toolchain is installed; otherwise the
# app compiles the bundled sources at launch (a fraction of a second).
SHADERS="$APP/Contents/Resources/minivu_MinivuRender.bundle/Shaders"
if xcrun metal --version >/dev/null 2>&1; then
  TMP=$(mktemp -d)
  for f in "$SHADERS"/*.metal; do
    xcrun metal -c -std=metal3.0 -ffast-math -I "$SHADERS" "$f" -o "$TMP/$(basename "$f" .metal).air"
  done
  xcrun metallib "$TMP"/*.air -o "$SHADERS/default.metallib"
  rm -rf "$TMP"
  echo "Shaders precompiled"
else
  echo "Metal toolchain not installed: shaders compile at launch"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>minivu</string>
  <key>CFBundleDisplayName</key>        <string>minivu</string>
  <key>CFBundleIdentifier</key>         <string>com.minivu.app</string>
  <key>CFBundleVersion</key>            <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
  <key>CFBundleExecutable</key>         <string>minivu</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleIconFile</key>           <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>     <string>15.0</string>
  <key>LSApplicationCategoryType</key>  <string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key>    <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
  <key>NSHumanReadableCopyright</key>   <string>GPLv3</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key> <string>Image</string>
      <key>CFBundleTypeRole</key> <string>Editor</string>
      <key>LSHandlerRank</key>    <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.image</string>
        <string>public.camera-raw-image</string>
        <string>com.adobe.pdf</string>
        <string>public.svg-image</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key> <string>Folder</string>
      <key>CFBundleTypeRole</key> <string>Viewer</string>
      <key>LSHandlerRank</key>    <string>None</string>
      <key>LSItemContentTypes</key> <array><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature with the hardened runtime. No developer account is
# involved; the sandbox is enforced from the signature on this Mac. Other
# Macs need a right-click > Open the first time (no notarisation).
if [ "$DEV" = "1" ]; then
  codesign --force --options runtime --sign - "$APP" && echo "Signed (ad hoc, DEV: no sandbox)"
else
  codesign --force --options runtime --entitlements scripts/minivu.entitlements --sign - "$APP" \
    && echo "Signed (ad hoc, sandboxed, hardened runtime)"
fi
codesign --verify --strict "$APP" && echo "Signature verifies"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
