#!/bin/bash
# Build a separate native dashboard without modifying Mole's CLI collectors.
set -euo pipefail

DESKTOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/.." && pwd)"
BUILD_DIR="$DESKTOP_DIR/build"
APP_DIR="$BUILD_DIR/Mole Dashboard.app"
"$DESKTOP_DIR/check-upstream.sh"
mkdir -p "$BUILD_DIR/cache/go" "$BUILD_DIR/cache/swift" \
    "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Helpers" "$APP_DIR/Contents/Resources"

echo 'Preparing the upstream Mole artwork...'
xcrun swiftc -O -module-cache-path "$BUILD_DIR/cache/swift" \
    "$DESKTOP_DIR/Tools/BuildIcons.swift" -o "$BUILD_DIR/build-icons"
"$BUILD_DIR/build-icons" "$REPO_DIR/docs/img/mole-banner.png" "$BUILD_DIR/branding"
/usr/bin/iconutil -c icns "$BUILD_DIR/branding/MoleDashboard.iconset" \
    -o "$APP_DIR/Contents/Resources/MoleDashboard.icns"
cp "$BUILD_DIR/branding/MoleLogo.png" "$BUILD_DIR/branding/MoleMenuTemplate.png" "$APP_DIR/Contents/Resources/"

python3 - "$REPO_DIR" "$BUILD_DIR/overlay.json" << 'PY'
import json
import pathlib
import sys
repo = pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"Replace": {
    str(repo / "cmd/status/main.go"): str(repo / "desktop/collector/main.go.in")
}}))
PY

cd "$REPO_DIR"
echo 'Building the read-only Mole collector...'
CGO_ENABLED=0 GOWORK=off GOCACHE="$BUILD_DIR/cache/go" go build -overlay "$BUILD_DIR/overlay.json" \
    -trimpath -ldflags='-s -w' -o "$APP_DIR/Contents/Helpers/mole-dashboard-collector" ./cmd/status

echo 'Building the native macOS window...'
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$BUILD_DIR/cache/swift" \
    -framework SwiftUI -framework AppKit \
    "$DESKTOP_DIR"/Sources/*.swift -o "$APP_DIR/Contents/MacOS/MoleDashboard"

cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.hui.mole-dashboard</string>
<key>CFBundleName</key><string>Mole Dashboard</string>
<key>CFBundleDisplayName</key><string>Mole Dashboard</string>
<key>CFBundleExecutable</key><string>MoleDashboard</string>
<key>CFBundleIconFile</key><string>MoleDashboard</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Based on Mole by Tw93 and contributors. GPL-3.0. Independent local dashboard.</string>
</dict></plist>
PLIST

cp "$REPO_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
cp "$DESKTOP_DIR/UPSTREAM_COMMIT" "$APP_DIR/Contents/Resources/MoleSourceCommit.txt"
git rev-parse HEAD > "$APP_DIR/Contents/Resources/DashboardSourceCommit.txt"
codesign --force --sign - "$APP_DIR/Contents/Helpers/mole-dashboard-collector"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "Built: $APP_DIR"
