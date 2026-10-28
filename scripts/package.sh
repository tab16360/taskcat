#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
bash scripts/build-app.sh
package_stage=$(mktemp -d)
trap 'rm -rf "$package_stage"' EXIT
ditto dist/TaskCat.app "$package_stage/记事喵.app"
codesign --verify --strict "$package_stage/记事喵.app"
package_arch=$(uname -m)
ditto -c -k --sequesterRsrc --keepParent "$package_stage/记事喵.app" "dist/TaskCat-$package_arch.zip"
(
  cd dist
  shasum -a 256 "TaskCat-$package_arch.zip" > "TaskCat-$package_arch.zip.sha256"
)
printf 'Packaged app only; local data and WeChat login excluded.\n'
