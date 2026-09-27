#!/bin/sh
# Usage: ./build.sh            build build/MiniMonitor.app
#        ./build.sh install    also copy to /Applications and launch
set -e
cd "$(dirname "$0")"

APP=build/MiniMonitor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos13.0" \
  -import-objc-header Sources/SMC.h \
  -framework IOKit \
  Sources/*.swift -o "$APP/Contents/MacOS/MiniMonitor"

codesign --force --sign - "$APP"
echo "Built $APP"

if [ "$1" = "install" ]; then
  pkill -x MiniMonitor 2>/dev/null || true
  rm -rf /Applications/MiniMonitor.app
  cp -R "$APP" /Applications/
  open /Applications/MiniMonitor.app
  echo "Installed /Applications/MiniMonitor.app"
fi
