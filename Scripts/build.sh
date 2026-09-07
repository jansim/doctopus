#!/bin/bash
# Builds Doctopus.app. Usage: Scripts/build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Doctopus.app"
RES="$APP/Contents/Resources"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Doctopus"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"
cp "$BIN" "$APP/Contents/MacOS/Doctopus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Icon Composer bundle → Assets.car (layered icon on macOS 26) plus a legacy
# .icns, which is what actually gets used on the macOS 15 deployment target.
# Cached in build/icon, since actool is slow and the source rarely changes.
if [ ! -d build/icon ] || [ Resources/doctopus.icon -nt build/icon ]; then
    rm -rf build/icon && mkdir -p build/icon
    xcrun actool Resources/doctopus.icon \
        --compile build/icon \
        --app-icon doctopus \
        --output-partial-info-plist build/icon/partial.plist \
        --platform macosx --target-device mac \
        --minimum-deployment-target 15.0 >/dev/null 2>&1
fi
cp build/icon/Assets.car build/icon/doctopus.icns "$RES/"

# Ad-hoc signature: enough for local use, and required for Continuity Camera
# and FSEvents to behave. Replace with a real identity to distribute.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null

# Nudge Launch Services so a rebuilt icon actually shows up in the Dock.
touch "$APP"

echo "Built $APP"
