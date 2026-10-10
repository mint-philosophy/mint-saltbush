#!/bin/zsh
# Build a universal (Apple Silicon + Intel) Folio.app and zip it for a GitHub release.
# Output: build/Folio.zip
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product Folio
swift build -c release --product Folio --triple x86_64-apple-macosx14.0 --scratch-path .build/x86
APP=build/release/Folio.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/release/Folio .build/x86/release/Folio -output "$APP/Contents/MacOS/Folio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" build/Folio.zip
lipo -info "$APP/Contents/MacOS/Folio"
echo "Packaged build/Folio.zip"
