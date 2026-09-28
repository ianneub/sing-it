#!/usr/bin/env bash
# Build and test the iOS app on the Mac over SSH (Tailscale), from this Linux machine.
# Syncs the repo, regenerates the Xcode project from project.yml, then runs xcodebuild.
#
#   ios/scripts/mac.sh build     # compile for the simulator (the quick check)
#   ios/scripts/mac.sh test      # SingItCore tests on macOS
#   ios/scripts/mac.sh device    # build, install and launch on the plugged-in iPhone
#   ios/scripts/mac.sh sync      # just copy the repo over
#   ios/scripts/mac.sh ssh CMD   # run CMD in the Mac's copy of ios/
#
# Settings come from ios/local.env (not committed), e.g.  SINGIT_MAC=my-mac  (an SSH host).
# Signing: put your team and bundle ID in ios/project.local.yml (see the README).
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
[ -f "$root/ios/local.env" ] && . "$root/ios/local.env"
mac=${SINGIT_MAC:?set SINGIT_MAC (an SSH host) in ios/local.env}
remote_dir=${SINGIT_REMOTE_DIR:-Code/sing-it}

sync() {
    rsync -az --delete \
        --exclude .venv --exclude /build --exclude .build --exclude .swiftpm --exclude __pycache__ \
        --exclude .pytest_cache --exclude ios/build --exclude ios/SingIt.xcodeproj --exclude ios/SingIt/Info.plist \
        --exclude hymns/audio --exclude recordings \
        "$root/" "$mac:$remote_dir/"
}

remote() {
    ssh -o BatchMode=yes "$mac" "export PATH=/opt/homebrew/bin:\$PATH; cd $remote_dir/ios && $*"
}

case "${1:-build}" in
    sync)
        sync ;;
    build)
        sync
        remote 'xcodegen generate --quiet --spec $(ls project.local.yml 2>/dev/null || echo project.yml) && xcodebuild -project SingIt.xcodeproj -scheme SingIt \
            -destination "generic/platform=iOS Simulator" -derivedDataPath build/DerivedData -quiet build \
            2>&1 | grep -vE "DVTPlugIn|CoreDevice|CoreSimulator|SimServiceContext|No locator class|Failure Reason|Recovery Suggestion|appintentsmetadataprocessor" \
            ; exit ${PIPESTATUS[0]}' ;;
    test)
        sync
        remote 'cd Packages/SingItCore && swift test 2>&1 | grep -E "error|failed|Executed [0-9]+ tests" | tail -20' ;;
    device)
        # Build, install and launch on the connected iPhone, via Terminal in the Mac's desktop
        # session (signing can't use the login keychain from SSH).
        sync
        remote 'rm -f build/device.status build/device.log && open -g -a Terminal scripts/device-build.command \
            && for i in $(seq 1 180); do [ -f build/device.status ] && break; sleep 2; done; \
            cat build/device.log; exit $(cat build/device.status 2>/dev/null || echo 1)' ;;
    ssh)
        shift
        sync
        remote "$@" ;;
    *)
        sed -n '2,12p' "$0"; exit 2 ;;
esac
