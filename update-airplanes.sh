#!/bin/bash
# Legacy 2025/bookworm feeders migrate to the unified updater on the default
# branch. This entry point redirects there; after the first upgrade the
# channel-aware updater takes over and this branch is no longer consulted.
set -euo pipefail

url="https://raw.githubusercontent.com/airplanes-live/airplanes-update/main/update-airplanes.sh"
tmpdir="$(mktemp -d /tmp/airplanes-update-entry.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT
entry="$tmpdir/update-airplanes.sh"

if ! wget -q --timeout=30 --tries=3 -O "$entry" "$url" || [[ ! -s "$entry" ]]; then
    echo "[ERROR] failed to fetch $url" >&2
    exit 1
fi

export AIRPLANES_UPDATE_BRANCH=main
cd /tmp
bash "$entry" "$@"
