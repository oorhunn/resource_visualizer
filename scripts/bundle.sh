#!/bin/sh
# Builds the SwiftUI app and wraps it in a signed (ad-hoc) .app bundle.
# Usage: scripts/bundle.sh [debug|release]   → build/ResourceVisualizer.app
set -eu

config=${1:-release}
root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/build/ResourceVisualizer.app"

swift build --package-path "$root" -c "$config"
binary="$(swift build --package-path "$root" -c "$config" --show-bin-path)/ResourceVisualizer"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/ResourceVisualizer"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Resource Visualizer</string>
    <key>CFBundleDisplayName</key><string>Resource Visualizer</string>
    <key>CFBundleIdentifier</key><string>com.anilorhundemiroglu.ResourceVisualizer</string>
    <key>CFBundleExecutable</key><string>ResourceVisualizer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Built $app"
