#!/bin/sh
# Usage: ./build.sh            build build/MiniMonitor.app
#        ./build.sh install    also copy to /Applications and launch
set -e
cd "$(dirname "$0")"

swift build -c release

APP=build/MiniMonitor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"

# Compiles the Icon Composer icon into Assets.car (plus AppIcon.icns for older macOS).
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist build/icon-info.plist >/dev/null
cp "$(swift build -c release --show-bin-path)/MiniMonitor" "$APP/Contents/MacOS/"

codesign --force --sign - "$APP"
echo "Built $APP"

if [ "$1" = "install" ]; then
  pkill -x MiniMonitor 2>/dev/null || true
  rm -rf /Applications/MiniMonitor.app
  cp -R "$APP" /Applications/
  open /Applications/MiniMonitor.app
  echo "Installed /Applications/MiniMonitor.app"
fi
