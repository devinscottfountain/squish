#!/bin/zsh
# Builds a Squish DMG ready to put on the internet.
#
#   SQUISH_SOURCE_URL=https://github.com/you/Squish Tools/release.sh --adhoc
#       Free public release: ad-hoc signed, not notarized. People approve it once on first launch
#       (README › Install). This is how Squish is released today.
#   SQUISH_SOURCE_URL=https://github.com/you/Squish Tools/release.sh
#       Developer ID signed and notarized (needs the paid Apple Developer Program).
#   Tools/release.sh --local
#       Same as --adhoc but without a source link, for testing the packaging only.
#
# Before the first real release (see README › Releasing):
#   1. Tools/build-ffmpeg.sh                    builds the bundled ffmpeg
#   2. A "Developer ID Application" certificate in your keychain (Apple Developer Program)
#   3. xcrun notarytool store-credentials squish-notary
#
# Environment:
#   SIGN_IDENTITY       codesigning identity (default: "Developer ID Application")
#   NOTARY_PROFILE      notarytool keychain profile (default: squish-notary)
#   SQUISH_SOURCE_URL   where people can get Squish's source; required for real releases (GPL)
set -euo pipefail

ROOT="${0:A:h:h}"
LOCAL=false   # ad-hoc signature, no notarization
PUBLIC=true   # needs a source URL in the notices (GPL)
case "${1:-}" in
  --local) LOCAL=true; PUBLIC=false ;;
  --adhoc) LOCAL=true ;;
esac
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-squish-notary}"
SOURCE_URL="${SQUISH_SOURCE_URL:-}"
FFMPEG="$ROOT/Tools/ffmpeg-build/out"
DIST="$ROOT/dist"

step() { print -P "%F{yellow}==>%f %B$1%b"; }
fail() { print -P "%F{red}error:%f $1"; exit 1; }

# --- Preflight ------------------------------------------------------------------------------------
[[ -x "$FFMPEG/ffmpeg" && -x "$FFMPEG/ffprobe" ]] || fail "No bundled ffmpeg yet. Run Tools/build-ffmpeg.sh first."
[[ -f "$ROOT/LICENSE" ]] || fail "LICENSE is missing from the repo root."
command -v xcodegen >/dev/null || fail "xcodegen not found (brew install xcodegen)."
if ! $LOCAL; then
  security find-identity -v -p codesigning | grep -q "$IDENTITY" \
    || fail "No \"$IDENTITY\" certificate in your keychain. Create one in Xcode › Settings › Accounts › Manage Certificates."
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || fail "No notarytool profile \"$PROFILE\". Run: xcrun notarytool store-credentials $PROFILE"
fi
if $PUBLIC; then
  [[ -n "$SOURCE_URL" ]] || fail "Set SQUISH_SOURCE_URL to where Squish's source is published. The GPL requires offering it."
fi
[[ -n "$SOURCE_URL" ]] || SOURCE_URL="(local test build: no public source URL set)"

if $LOCAL; then
  SIGN=(codesign --force --options runtime --sign -)
else
  SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
fi

# --- Build ----------------------------------------------------------------------------------------
step "Building Squish (Release, arm64)"
cd "$ROOT"
xcodegen generate --quiet
xcodebuild -project Squish.xcodeproj -scheme Squish -configuration Release \
  -derivedDataPath build/release -destination 'platform=macOS' ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO build -quiet
BUILT="$ROOT/build/release/Build/Products/Release/Squish.app"
[[ -d "$BUILT" ]] || fail "Release build not found at $BUILT"

rm -rf "$DIST"
mkdir -p "$DIST"
APP="$DIST/Squish.app"
ditto "$BUILT" "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")

# --- Bundle ffmpeg and licenses -------------------------------------------------------------------
step "Bundling ffmpeg and license notices"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/Licenses"
cp "$FFMPEG/ffmpeg" "$FFMPEG/ffprobe" "$APP/Contents/Helpers/"
cp -R "$FFMPEG/licenses/" "$APP/Contents/Resources/Licenses/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/Squish-LICENSE.txt"
{
  echo "Squish $VERSION ($BUILD_NUMBER)"
  echo "Copyright © 2026 Devin Fountain. Licensed under the GNU General Public License v3 (Squish-LICENSE.txt)."
  echo
  echo "Source code for Squish, including the script that builds the bundled ffmpeg"
  echo "(Tools/build-ffmpeg.sh): $SOURCE_URL"
  echo
  echo "Squish includes ffmpeg and ffprobe (Contents/Helpers), built with --enable-gpl --enable-version3"
  echo "and distributed under the GNU GPL v3 (ffmpeg/COPYING.GPLv3). The exact sources used, with their"
  echo "SHA-256 checksums, are listed below; each library's license is in its own folder here."
  echo
  cat "$FFMPEG/VERSIONS.txt"
} > "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.txt"

# --- Sign: helpers first, then the app ------------------------------------------------------------
step "Signing ($([[ $LOCAL == true ]] && echo "ad-hoc" || echo "$IDENTITY"))"
"${SIGN[@]}" "$APP/Contents/Helpers/ffmpeg"
"${SIGN[@]}" "$APP/Contents/Helpers/ffprobe"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
"$APP/Contents/Helpers/ffmpeg" -hide_banner -version | head -1

# --- DMG ------------------------------------------------------------------------------------------
step "Making the disk image"
STAGE="$DIST/dmg-stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Squish.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Squish-$VERSION.dmg"
hdiutil create -quiet -volname "Squish" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if $LOCAL; then
  step "Ad-hoc build done: not notarized, so each Mac approves it once on first launch (README › Install)"
else
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"

  step "Notarizing (this usually takes a few minutes)"
  result=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)
  grep -q "status: Accepted" <<<"$result" || fail "Notarization was not accepted. See: xcrun notarytool log <submission id> --keychain-profile $PROFILE"

  step "Stapling the ticket"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

echo
echo "  $DMG"
echo "  sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "  $(du -h "$DMG" | cut -f1)"
