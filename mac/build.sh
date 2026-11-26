#!/bin/sh
# Builds build/Vino.app. The app binary is also the `vino` command line: Vino.app/Contents/MacOS/Vino doctor
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Vino.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Vino "$APP/Contents/MacOS/Vino"
cp -R ../recipes "$APP/Contents/Resources/recipes"  # the Get Apps catalog
cp vendor/innoextract "$APP/Contents/Resources/innoextract"  # unpacks Inno Setup installers that fail in Wine
cp vendor/winetricks vendor/cabextract "$APP/Contents/Resources/"  # Windows components
ln -s ../MacOS/Vino "$APP/Contents/Resources/vino"  # for: ln -s /Applications/Vino.app/Contents/Resources/vino /usr/local/bin/vino
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Vino</string>
  <key>CFBundleDisplayName</key><string>Vino</string>
  <key>CFBundleExecutable</key><string>Vino</string>
  <key>CFBundleIdentifier</key><string>app.vino.mac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Windows program</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>CFBundleTypeExtensions</key><array><string>exe</string><string>msi</string><string>bat</string></array>
  </dict></array>
</dict></plist>
EOF
codesign --force --sign - "$APP"  # ad-hoc signature so it runs on this Mac
echo "Built $(pwd)/$APP"
