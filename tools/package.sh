#!/bin/zsh
# Makes a release build (Apple silicon and Intel) and a zip in dist/, like ForgeDeck's package.sh.
#   tools/package.sh
# Signing: SIGN_IDENTITY, else the first "Developer ID Application" identity, else the first
# "Apple Development" identity, else ad hoc. The hardened runtime is on for every real identity.
# Notarization: only with a Developer ID identity AND a notarytool keychain profile in
# NOTARY_PROFILE (xcrun notarytool store-credentials <name>). Otherwise it is skipped and the
# script says so. It never claims a notarization it did not do.
set -euo pipefail
root=${0:A:h:h}
mac="$root/apps/mac"
name=SocialForge
scratch="$HOME/Library/Developer/$name/universal"
version=$(sed -n 's/.*<key>CFBundleShortVersionString<\/key><string>\(.*\)<\/string>.*/\1/p' "$mac/Info.plist.in")
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

identity="${SIGN_IDENTITY:-}"
find_identity() { security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o "\"$1: [^\"]*\"" | tr -d '"' || true; }
[[ -n "$identity" ]] || identity=$(find_identity "Developer ID Application")
[[ -n "$identity" ]] || identity=$(find_identity "Apple Development")
[[ -n "$identity" ]] || identity=-

swift build -c release --arch arm64 --arch x86_64 --package-path "$mac" --scratch-path "$scratch"
bin="$scratch/apple/Products/Release/$name"
[[ -x "$bin" ]] || bin="$scratch/out/Products/Release/$name"
[[ -x "$bin" ]] || { echo "build failed"; exit 1; }

app="$stage/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Fonts" "$app/Contents/Library/LaunchAgents"
cp "$bin" "$app/Contents/MacOS/$name"
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$mac/Info.plist.in" > "$app/Contents/Info.plist"
if [[ ! -f "$mac/Resources/Assets.car" || ( -d "$mac/Icon/AppIcon.icon" && -n "$(find "$mac/Icon/AppIcon.icon" -newer "$mac/Resources/Assets.car" | head -1)" ) ]]; then
  "$mac/tools/make_icon.sh"
fi
cp -X "$mac/Resources/Assets.car" "$mac/Resources/AppIcon.icns" "$app/Contents/Resources/"
cp "$mac/Fonts/"*.ttf "$mac/Fonts/OFL.txt" "$app/Contents/Resources/Fonts/"
mkdir -p "$app/Contents/Resources/Workflows"
cp "$root/comfyui/workflows/api/"*.json "$app/Contents/Resources/Workflows/"
cp "$mac/LaunchAgents/"*.plist "$app/Contents/Library/LaunchAgents/"
xattr -cr "$app"
if [[ "$identity" == "-" ]]; then
  codesign --force --sign - "$app"
else
  codesign --force --options runtime --timestamp --sign "$identity" "$app" 2>/dev/null \
    || codesign --force --options runtime --sign "$identity" "$app"
fi
codesign --verify --deep --strict "$app"
lipo -archs "$app/Contents/MacOS/$name"

mkdir -p "$root/dist"
zip="$root/dist/$name-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "signed:    $identity"
echo "packaged:  $zip"

if [[ "$identity" == Developer\ ID\ Application* && -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  spctl --assess --type execute --verbose "$app"
  echo "notarized: yes (stapled)"
else
  echo "notarized: no (needs a Developer ID Application identity and NOTARY_PROFILE). Other Macs will block this build."
fi
