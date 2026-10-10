#!/bin/zsh
# Build Folio.app into build/. With --install, also copy it to /Applications.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product Folio
BIN="$(swift build -c release --show-bin-path)/Folio"
APP=build/Folio.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Folio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  # Swap the bundle in rather than overwriting it, so a running copy keeps working
  # and picks up the new version the next time it's opened.
  ditto "$APP" /Applications/Folio.app.new
  [[ -e /Applications/Folio.app ]] && trash /Applications/Folio.app
  mv /Applications/Folio.app.new /Applications/Folio.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Folio.app
  echo "Installed /Applications/Folio.app"
fi
