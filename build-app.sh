#!/bin/zsh
# Builds "MG6250 Scanner.app" (and the mg6250scan command-line tool) into ./build
set -euo pipefail
cd "$(dirname "$0")"

# Universal binary: runs natively on both Intel and Apple Silicon Macs.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP="build/MG6250 Scanner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/MG6250Scanner" "$APP/Contents/MacOS/MG6250 Scanner"
cp "$BIN/mg6250scan" build/mg6250scan

# App icon: build AppIcon.icns from Resources/AppIcon.png
# (redraw the PNG with: swift Scripts/make-icon.swift Resources/AppIcon.png)
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET" "$APP/Contents/Resources"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MG6250 Scanner</string>
    <key>CFBundleDisplayName</key><string>MG6250 Scanner</string>
    <key>CFBundleIdentifier</key><string>local.mg6250.scanner</string>
    <key>CFBundleExecutable</key><string>MG6250 Scanner</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MG6250 Scanner talks to your Canon printer over the local network to scan.</string>
    <key>NSBonjourServices</key>
    <array><string>_scanner._tcp</string></array>
</dict>
</plist>
EOF

# Sign with your Apple Development certificate when there is one, so macOS
# keeps the app's Local Network permission across rebuilds; otherwise ad-hoc.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')"
if [[ -z "$IDENTITY" ]] || ! codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    codesign --force --sign - "$APP" >/dev/null 2>&1
    echo "Signed ad-hoc"
else
    echo "Signed with Apple Development certificate"
fi
echo "Built $APP"
echo "Built build/mg6250scan"
