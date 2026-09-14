#!/bin/bash
# Builds Micara.app; --install puts it in /Applications and starts it.
# Same shape as Eyesaver's build.sh, plus two things Micara cannot avoid: the
# WebRTC framework (a binary, downloaded once into Vendor/) and the BlackHole
# driver (a system installer, password asked once).
set -euo pipefail
cd "$(dirname "$0")"

NAME="Micara"
ID="com.getmicara.mac"
VERSION="0.1.1"
APP="build/$NAME.app"
WEBRTC_VERSION="150.7871.02"
WEBRTC_URL="https://github.com/livekit/webrtc-xcframework/releases/download/$WEBRTC_VERSION/LiveKitWebRTC.xcframework.zip"
WEBRTC_SHA="a523cd141d2aa6c3638d49fea1f72b0aafd28a8818c35fc240e08418da3d2fda"
BLACKHOLE_DRIVER="/Library/Audio/Plug-Ins/HAL/BlackHole16ch.driver"
BLACKHOLE_PKG="Resources/BlackHole16ch-0.7.1.pkg"

# --- WebRTC: downloaded by curl, not by SwiftPM --------------------------------
# SwiftPM can download a binaryTarget, but fails as soon as the keychain holds
# several identities for github.com (the case on any machine with a multi-account
# gh). curl plus a checked SHA-256, and Package.swift points at the local folder.
if [ ! -d Vendor/LiveKitWebRTC.xcframework ]; then
  echo "→ downloading WebRTC $WEBRTC_VERSION (69 MB, once)"
  mkdir -p Vendor
  curl -sSL -o Vendor/webrtc.zip "$WEBRTC_URL"
  echo "$WEBRTC_SHA  Vendor/webrtc.zip" | shasum -a 256 -c - >/dev/null
  unzip -q -o Vendor/webrtc.zip -d Vendor
  rm Vendor/webrtc.zip
fi

# --- BlackHole: the only moment a password is asked ----------------------------
# A virtual microphone is a driver in /Library/Audio/Plug-Ins/HAL: impossible
# without admin rights, whatever the app. Do it here, in the open, once.
if [ "${1:-}" = "--install" ] && [ ! -d "$BLACKHOLE_DRIVER" ]; then
  echo "→ BlackHole 16ch (virtual microphone, GPL-3.0) is not installed."
  echo "  macOS asks for your password to put the audio driver in place."
  sudo installer -pkg "$BLACKHOLE_PKG" -target / >/dev/null
  echo "  installed."
fi

# --- Build ----------------------------------------------------------------------
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# The framework lives in Contents/Frameworks: the executable has to look for it
# there, not in .build/ where SwiftPM linked it.
swift build -c release --arch arm64 \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks >/dev/null
cp ".build/arm64-apple-macosx/release/$NAME" "$APP/Contents/MacOS/$NAME"
cp -R "Vendor/LiveKitWebRTC.xcframework/macos-arm64_x86_64/LiveKitWebRTC.framework" "$APP/Contents/Frameworks/"

# --- Icon -------------------------------------------------------------------------
if [ ! -f "Resources/$NAME.icns" ]; then
  mkdir -p "build/$NAME.iconset"
  for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" \
              "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
    pixels="${pair% *}"
    label="${pair#* }"
    sips -z "$pixels" "$pixels" Resources/icon.png --out "build/$NAME.iconset/icon_$label.png" >/dev/null
  done
  iconutil -c icns -o "Resources/$NAME.icns" "build/$NAME.iconset"
fi
cp "Resources/$NAME.icns" Resources/qr-card.png \
   "$BLACKHOLE_PKG" Resources/GPL-3.0.txt "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleIconFile</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Agent: no Dock icon, no application menu bar. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Without this key, macOS kills the app on its first microphone access. -->
  <key>NSMicrophoneUsageDescription</key><string>Micara mixes this Mac's microphone with the phones in the room.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature, stable identifier. The framework first: a bundle signature
# does not cover an unsigned framework.
codesign --force --sign - "$APP/Contents/Frameworks/LiveKitWebRTC.framework"
codesign --force --sign - --identifier "$ID" "$APP"

# --- Install -------------------------------------------------------------------------
if [ "${1:-}" = "--install" ]; then
  if pkill -f "$NAME.app/Contents/MacOS/$NAME" 2>/dev/null; then
    sleep 2
  fi
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" "/Applications/"
  rm -rf "$APP"
  # "Update" in the app re-runs this script from this folder.
  defaults write "$ID" sourcePath -string "$(pwd)"
  open "/Applications/$NAME.app"
  echo "→ installed in /Applications and started"
  echo "  No window, no Dock icon: look for the Micara logo in the menu bar, top"
  echo "  right, near the clock."
else
  echo "→ $(pwd)/$APP"
fi
