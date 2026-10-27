#!/bin/bash
# Swaps in a verified, already-staged build once the running app has exited.
# Usage: update-install.sh <pid> <target.app> <staged.app> <backup.app>
# The previous build is kept as <backup.app>; a failed swap restores it.
set -uo pipefail
pid="$1"; target="$2"; staged="$3"; backup="$4"
reopen() { [[ -n "${TASKCAT_UPDATE_NO_OPEN:-}" ]] || open "$1"; }
for _ in $(seq 1 600); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$pid" 2>/dev/null; then
  echo "$(date '+%F %T') app still running; update skipped"; rm -rf "$staged"; exit 1
fi
mkdir -p "$(dirname "$backup")"
if ! mv "$target" "$backup"; then
  echo "$(date '+%F %T') could not move current build aside; update skipped"; rm -rf "$staged"; reopen "$target"; exit 1
fi
if ! mv "$staged" "$target"; then
  echo "$(date '+%F %T') swap failed; restoring previous build"; mv "$backup" "$target"; reopen "$target"; exit 1
fi
echo "$(date '+%F %T') updated $target (previous build: $backup)"
reopen "$target"
