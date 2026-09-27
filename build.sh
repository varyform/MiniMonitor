#!/bin/sh
# Usage: ./build.sh            build build/MiniMonitor.app
#        ./build.sh install    also copy to /Applications and launch
set -e
cd "$(dirname "$0")"

swift build -c release

APP=build/MiniMonitor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
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
