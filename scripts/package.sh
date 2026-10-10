#!/bin/zsh
# Build a universal (Apple Silicon + Intel) Saltbush.app and zip it for a GitHub release.
# With a "Developer ID Application" certificate in the keychain and a notarytool profile
# named "folio-notary" (named before the app became Saltbush), the app is signed, notarized by Apple and stapled, so it opens
# without warnings. Otherwise it falls back to an ad hoc signature.
# --no-notarize signs with the Developer ID but skips Apple's check (for a quick interim release).
# Output: build/Saltbush.zip
set -euo pipefail
NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0
cd "${0:A:h}/.."

swift build -c release --product Saltbush
swift build -c release --product Saltbush --triple x86_64-apple-macosx14.0 --scratch-path .build/x86
APP=build/release/Saltbush.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/release/Saltbush .build/x86/release/Saltbush -output "$APP/Contents/MacOS/Saltbush"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  echo "Signing with $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  if (( NOTARIZE )); then
    ditto -c -k --keepParent "$APP" build/Saltbush-notarize.zip
    xcrun notarytool submit build/Saltbush-notarize.zip --keychain-profile folio-notary --wait
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP"
  fi
else
  echo "No Developer ID certificate found; signing ad hoc (users will see a Gatekeeper warning)."
  codesign --force --sign - "$APP"
fi

ditto -c -k --keepParent "$APP" build/Saltbush.zip
lipo -info "$APP/Contents/MacOS/Saltbush"
echo "Packaged build/Saltbush.zip"
