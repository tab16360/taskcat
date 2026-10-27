#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bundle="${1:-dist/TaskCat.app}"
codesign --verify --strict "$bundle"
details=$(codesign -dv --verbose=2 "$bundle" 2>&1)
if ! [[ "$details" == *"Authority=Developer ID Application:"* ]]; then
  printf 'BLOCKED: Developer ID signature missing; local test build only.\n'
  exit 1
fi
xcrun stapler validate "$bundle"
spctl --assess --type execute --verbose "$bundle"
printf 'Signing/notarization gate passed; clean-machine acceptance is still required.\n'
