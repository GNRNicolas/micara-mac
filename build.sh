#!/bin/bash
# Construit Micara.app ; --install la pose dans /Applications et la lance.
# Même forme que build.sh d'Eyesaver, plus deux choses que Micara ne peut pas
# éviter : le framework WebRTC (binaire, téléchargé une fois dans Vendor/) et le
# driver BlackHole (installeur système, mot de passe demandé une fois).
set -euo pipefail
cd "$(dirname "$0")"

NAME="Micara"
ID="com.getmicara.mac"
VERSION="0.1.0"
APP="build/$NAME.app"
WEBRTC_VERSION="150.7871.02"
WEBRTC_URL="https://github.com/livekit/webrtc-xcframework/releases/download/$WEBRTC_VERSION/LiveKitWebRTC.xcframework.zip"
WEBRTC_SHA="a523cd141d2aa6c3638d49fea1f72b0aafd28a8818c35fc240e08418da3d2fda"
BLACKHOLE_DRIVER="/Library/Audio/Plug-Ins/HAL/BlackHole16ch.driver"
BLACKHOLE_PKG="Resources/BlackHole16ch-0.7.1.pkg"

# --- WebRTC : téléchargé par curl, pas par SwiftPM ----------------------------
# SwiftPM sait télécharger un binaryTarget, mais échoue dès que le trousseau
# contient plusieurs identifiants pour github.com (cas de toute machine avec gh
# multi-comptes). curl + somme SHA-256 vérifiée, et Package.swift pointe sur le
# dossier local.
if [ ! -d Vendor/LiveKitWebRTC.xcframework ]; then
  echo "→ téléchargement de WebRTC $WEBRTC_VERSION (69 Mo, une seule fois)"
  mkdir -p Vendor
  curl -sSL -o Vendor/webrtc.zip "$WEBRTC_URL"
  echo "$WEBRTC_SHA  Vendor/webrtc.zip" | shasum -a 256 -c - >/dev/null
  unzip -q -o Vendor/webrtc.zip -d Vendor
  rm Vendor/webrtc.zip
fi

# --- BlackHole : le seul moment où un mot de passe est demandé ----------------
# Un micro virtuel est un driver dans /Library/Audio/Plug-Ins/HAL : impossible
# sans droits admin, quelle que soit l'app. On le fait ici, en clair, une fois.
if [ "${1:-}" = "--install" ] && [ ! -d "$BLACKHOLE_DRIVER" ]; then
  echo "→ BlackHole 16ch (micro virtuel, licence GPL-3.0) n'est pas installé."
  echo "  macOS demande votre mot de passe pour poser le driver audio."
  sudo installer -pkg "$BLACKHOLE_PKG" -target / >/dev/null
  echo "  installé."
fi

# --- Compilation ----------------------------------------------------------------
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# Le framework vit dans Contents/Frameworks : l'exécutable doit le chercher là,
# pas dans .build/ où SwiftPM l'a lié.
swift build -c release --arch arm64 \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks >/dev/null
cp ".build/arm64-apple-macosx/release/$NAME" "$APP/Contents/MacOS/$NAME"
cp -R "Vendor/LiveKitWebRTC.xcframework/macos-arm64_x86_64/LiveKitWebRTC.framework" "$APP/Contents/Frameworks/"

# --- Icône ------------------------------------------------------------------------
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
cp "Resources/$NAME.icns" \
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
  <!-- Agent : pas d'icône dans le Dock, pas de barre de menus d'application. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Sans cette clé, macOS tue l'app au premier accès au micro. -->
  <key>NSMicrophoneUsageDescription</key><string>Micara mixe le micro de ce Mac avec ceux des téléphones de la salle.</string>
</dict>
</plist>
PLIST

# Signature ad hoc, identifiant stable. Le framework d'abord : une signature de
# bundle ne couvre pas un framework non signé.
codesign --force --sign - "$APP/Contents/Frameworks/LiveKitWebRTC.framework"
codesign --force --sign - --identifier "$ID" "$APP"

# --- Installation -------------------------------------------------------------------
if [ "${1:-}" = "--install" ]; then
  if pkill -f "$NAME.app/Contents/MacOS/$NAME" 2>/dev/null; then
    sleep 2
  fi
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" "/Applications/"
  rm -rf "$APP"
  # « Mettre à jour » dans l'app relance ce script depuis ce dossier.
  defaults write "$ID" sourcePath -string "$(pwd)"
  open "/Applications/$NAME.app"
  echo "→ installé dans /Applications et lancé"
  echo "  Pas de fenêtre, pas d'icône dans le Dock : cherchez le micro dans la barre"
  echo "  de menus, en haut à droite, près de l'horloge."
else
  echo "→ $(pwd)/$APP"
fi
