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
#   build/minivu.app/Contents/Resources/Metadata.appintents          (Shortcuts actions)
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
# On success only the last line is wanted, which is SwiftPM's own summary.
# On failure everything is: piping straight into `tail -1` threw the error
# away and left one line of whatever came last, which for a compiler crash
# is the bottom of a stack trace and tells nobody anything.
build_log=$(mktemp -t minivu-release-build)
# Swift Build (SwiftPM's default engine since Swift 6.2) is named rather than
# assumed: it is the engine that records the App Intents types for
# Metadata.appintents below.
if swift build -c release --product minivu --build-system swiftbuild >"$build_log" 2>&1; then
    tail -1 "$build_log"
    rm -f "$build_log"
else
    cat "$build_log"
    rm -f "$build_log"
    exit 1
fi

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

# Shortcuts actions (App Intents). Shortcuts learns what an app offers from
# Contents/Resources/Metadata.appintents, without launching it. Xcode makes
# that folder with appintentsmetadataprocessor from the ".swiftconstvalues"
# files the compiler writes about App Intents types; Swift Build asks the
# compiler for those files in a SwiftPM build too, so all that is missing
# is running the processor, which is part of the Xcode toolchain. Without
# the folder minivu still runs, but Shortcuts shows none of its actions, so
# a failure here stops the build rather than ship that quietly.
# The architecture is the binary's own and the deployment target is
# Package.swift's, so neither drifts from what was built.
ARCH=$(lipo -archs .build/release/minivu | awk '{print $1}')
DEPLOYMENT=$(sed -n 's/.*\.macOS(\.v\([0-9][0-9]*\)).*/\1.0/p' Package.swift | head -1)
if [ -z "$ARCH" ] || [ -z "$DEPLOYMENT" ]; then
  echo "Can't tell the binary's architecture or Package.swift's macOS version" >&2
  exit 1
fi
OBJECTS=.build/out/Intermediates.noindex/minivu.build/Release/minivu-p.build/Objects-normal/$ARCH
if [ ! -f "$OBJECTS/minivu.SwiftFileList" ] || ! ls "$OBJECTS"/*.swiftconstvalues >/dev/null 2>&1; then
  echo "No App Intents records from the compiler (.swiftconstvalues) in .build/out: is SwiftPM still using Swift Build?" >&2
  exit 1
fi
INTENTS_TMP=$(mktemp -d)
# Only this build's records: a release build compiles the whole module and
# writes one (minivu-primary); a build file by file writes one a source
# file. The folder can still hold records from the other kind of build, or
# from a source file since deleted or renamed, which would bring back
# actions minivu no longer has. So: the whole module's record when nothing
# newer lies beside it, otherwise one record for each file the compiler was
# given this time (minivu.SwiftFileList).
PRIMARY="$OBJECTS/minivu-primary.swiftconstvalues"
if [ -f "$PRIMARY" ] && [ -z "$(find "$OBJECTS" -name '*.swiftconstvalues' -newer "$PRIMARY")" ]; then
  echo "$PRIMARY" > "$INTENTS_TMP/constvalues.list"
else
  : > "$INTENTS_TMP/constvalues.list"
  while IFS= read -r source; do
    record="$OBJECTS/$(basename "$source" .swift).swiftconstvalues"
    if [ -f "$record" ]; then echo "$record" >> "$INTENTS_TMP/constvalues.list"; fi
  done < "$OBJECTS/minivu.SwiftFileList"
fi
if [ ! -s "$INTENTS_TMP/constvalues.list" ]; then
  echo "No App Intents records for this build's source files" >&2
  exit 1
fi
TOOLCHAIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
XCODE_BUILD=$(/usr/libexec/PlistBuddy -c "Print :ProductBuildVersion" "$(xcode-select -p)/../version.plist")
if ! xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" --toolchain-dir "$TOOLCHAIN" \
    --module-name Minivu --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" --xcode-version "$XCODE_BUILD" \
    --platform-family macOS --deployment-target "$DEPLOYMENT" --target-triple "$ARCH-apple-macos$DEPLOYMENT" \
    --source-file-list "$OBJECTS/minivu.SwiftFileList" --swift-const-vals-list "$INTENTS_TMP/constvalues.list" \
    --no-app-shortcuts-localization >"$INTENTS_TMP/log" 2>&1; then
  cat "$INTENTS_TMP/log" >&2
  exit 1
fi
rm -rf "$INTENTS_TMP"
# `raw` prints a dictionary's keys, one action identifier a line.
ACTIONS=$(plutil -extract actions raw -o - "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" \
  2>/dev/null | tr '\n' ' ' || true)
if [ -z "${ACTIONS// /}" ]; then
  echo "Metadata.appintents lists no actions" >&2
  exit 1
fi
echo "Shortcuts actions: $ACTIONS"

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
