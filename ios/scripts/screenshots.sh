#!/usr/bin/env bash
# Capture the README's screenshots in the simulator (run on a Mac, in ios/). Uses the
# debug-only screenshot mode: the made-up test hymn and a simulated singer.
#   scripts/screenshots.sh [device name]      -> build/screenshots/*.png
set -euo pipefail
cd "$(dirname "$0")/.."
device=${1:-iPhone 17 Pro}
out=build/screenshots
mkdir -p "$out"

xcodegen generate --quiet --spec "$(ls project.local.yml 2>/dev/null || echo project.yml)"
xcodebuild -project SingIt.xcodeproj -scheme SingIt -configuration Debug \
    -destination "platform=iOS Simulator,name=$device" -derivedDataPath build/DerivedData -quiet build
app=build/DerivedData/Build/Products/Debug-iphonesimulator/SingIt.app
bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")

xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl ui "$device" appearance light
xcrun simctl status_bar "$device" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 --dataNetwork wifi
xcrun simctl install "$device" "$app"

for screen in setup singing summary range; do
    xcrun simctl terminate "$device" "$bundle" 2>/dev/null || true
    xcrun simctl launch "$device" "$bundle" -screenshot "$screen" >/dev/null
    sleep 4
    xcrun simctl io "$device" screenshot "$out/$screen.png" >/dev/null 2>&1
    echo "captured $out/$screen.png"
done
xcrun simctl status_bar "$device" clear
