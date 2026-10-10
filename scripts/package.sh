#!/bin/zsh
# Build a universal (Apple Silicon + Intel) Folio.app and zip it for a GitHub release.
# With a "Developer ID Application" certificate in the keychain and a notarytool profile
# named "folio-notary", the app is signed, notarized by Apple and stapled, so it opens
# without warnings. Otherwise it falls back to an ad hoc signature.
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

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  echo "Signing with $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  ditto -c -k --keepParent "$APP" build/Folio-notarize.zip
  xcrun notarytool submit build/Folio-notarize.zip --keychain-profile folio-notary --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
else
  echo "No Developer ID certificate found; signing ad hoc (users will see a Gatekeeper warning)."
  codesign --force --sign - "$APP"
fi

ditto -c -k --keepParent "$APP" build/Folio.zip
lipo -info "$APP/Contents/MacOS/Folio"
echo "Packaged build/Folio.zip"
