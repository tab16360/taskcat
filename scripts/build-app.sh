#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
app_bundle="$PWD/dist/TaskCat.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp apps/macos/Resources/Info.plist "$app_bundle/Contents/Info.plist"
cp apps/macos/Resources/instructions.txt apps/macos/Resources/command.schema.json apps/macos/Resources/update-install.sh "$app_bundle/Contents/Resources/"
chmod 755 "$app_bundle/Contents/Resources/update-install.sh"
icon_dir=$(mktemp -d)/TaskCat.iconset
mkdir -p "$icon_dir"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/branding/taskcat/taskcat-mark-v1.png --out "$icon_dir/icon_${size}x${size}.png" >/dev/null
  twice=$((size * 2))
  sips -z "$twice" "$twice" assets/branding/taskcat/taskcat-mark-v1.png --out "$icon_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_dir" -o "$app_bundle/Contents/Resources/TaskCat.icns"
cp assets/branding/taskcat/taskcat-mark-v1.png "$app_bundle/Contents/Resources/TaskCatMark.png"
rm -rf "$(dirname "$icon_dir")"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  poc/metadata-journal/OperationJournal.swift apps/macos/Sources/*.swift \
  -o "$app_bundle/Contents/MacOS/TaskCat"
rm -f "$app_bundle/Contents/Resources/development-project-path.txt"
# A stable certificate keeps the designated requirement identical across builds, so macOS
# keeps Reminders access after updates. Ad-hoc signatures change with every build.
local_keychain="$HOME/Library/Keychains/taskcat-signing.keychain-db"
local_password="$HOME/Library/Application Support/TaskCatSigning/keychain-password"
if [[ -n "${TASKCAT_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$TASKCAT_SIGNING_IDENTITY" "$app_bundle"
elif [[ -f "$local_keychain" && -f "$local_password" ]]; then
  security unlock-keychain -p "$(cat "$local_password")" "$local_keychain"
  codesign --force --keychain "$local_keychain" --sign "TaskCat Local Code Signing" "$app_bundle"
else
  printf 'warning: no signing certificate; ad-hoc build will lose Reminders access after updates\n' >&2
  codesign --force --sign - "$app_bundle"
fi
codesign --verify --strict "$app_bundle"
plutil -lint "$app_bundle/Contents/Info.plist"
if [[ "${1:-}" == "--open" ]]; then open "$app_bundle"; fi
