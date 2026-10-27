#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
app_target="$HOME/Applications/记事喵.app"
if [[ -d "/Applications/记事喵.app" ]]; then app_target="/Applications/记事喵.app"; fi
legacy_target="$HOME/Applications/TaskSecretary.app"
app_stage="$(dirname "$app_target")/.TaskCat-stage-$(uuidgen).app"
mkdir -p "$HOME/Applications"
ditto dist/TaskCat.app "$app_stage"
codesign --verify --strict "$app_stage"
if [[ -d "$app_target" ]]; then
  app_backup="$HOME/Library/Application Support/TaskSecretary/previous-build-$(uuidgen).app"
  mv "$app_target" "$app_backup"
fi
if [[ -d "$legacy_target" ]]; then
  legacy_backup="$HOME/Library/Application Support/TaskSecretary/previous-build-$(uuidgen).app"
  mv "$legacy_target" "$legacy_backup"
fi
if [[ "$app_target" != "$HOME/Applications/记事喵.app" && -d "$HOME/Applications/记事喵.app" ]]; then
  duplicate_backup="$HOME/Library/Application Support/TaskSecretary/previous-build-$(uuidgen).app"
  mv "$HOME/Applications/记事喵.app" "$duplicate_backup"
fi
mv "$app_stage" "$app_target"
codesign --verify --strict "$app_target"
printf 'Installed: %s\n' "$app_target"
open "$app_target"
