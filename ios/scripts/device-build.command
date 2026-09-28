#!/bin/bash
# Build, install and launch Sing It on the iPhone. Runs in the Mac's desktop session
# (started with `open`), because code signing can't reach the login keychain over SSH.
# Output goes to ios/build/device.log; the exit status to ios/build/device.status.
cd "$(dirname "$0")/.." || exit 1
export PATH=/opt/homebrew/bin:$PATH
mkdir -p build
device=${SINGIT_DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /connected/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')}
{
    echo "device: ${device:-none found}"
    set -o pipefail
    xcodegen generate --quiet --spec "$(ls project.local.yml 2>/dev/null || echo project.yml)" &&
    xcodebuild -project SingIt.xcodeproj -scheme SingIt -destination "generic/platform=iOS" \
        -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
        -quiet build 2>&1 | grep -vE "DVTPlugIn|appintentsmetadataprocessor" &&
    xcrun devicectl device install app --device "$device" build/DerivedData/Build/Products/Debug-iphoneos/SingIt.app &&
    xcrun devicectl device process launch --device "$device" \
        "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' build/DerivedData/Build/Products/Debug-iphoneos/SingIt.app/Info.plist)"
    echo $? > build/device.status
} > build/device.log 2>&1
cat build/device.log
echo "Done (status $(cat build/device.status)). You can close this window."
