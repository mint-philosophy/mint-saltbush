#!/bin/zsh
# Build Saltbush.app into build/. With --install, also copy it to /Applications.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product Saltbush
BIN="$(swift build -c release --show-bin-path)/Saltbush"
APP=build/Saltbush.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Saltbush"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  # Swap the bundle in rather than overwriting it, so a running copy keeps working
  # and picks up the new version the next time it's opened.
  ditto "$APP" /Applications/Saltbush.app.new
  [[ -e /Applications/Saltbush.app ]] && trash /Applications/Saltbush.app
  mv /Applications/Saltbush.app.new /Applications/Saltbush.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Saltbush.app
  echo "Installed /Applications/Saltbush.app"
fi
