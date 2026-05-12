#!/usr/bin/env bash
# Behavioral test for the apl-feed import wiring inside airplanes-first-run.
# Static grep in update-airplanes-rootfs-smoke.sh covers "the line is in the
# installed file"; this test covers "the script actually calls apl-feed
# import legacy-config --no-restart with the right path when it runs".
#
# The first-run script hardcodes absolute paths (/boot, /usr/local/bin),
# so we sed-rewrite a copy that uses a temporary fake root and stub every
# binary the script touches through PATH. apl-feed is the assertion
# target; systemctl / create-uuid.sh / fix-config.sh are silenced so the
# rest of the script runs to completion without side effects.

set -euo pipefail

UPDATE_DIR="${AIRPLANES_UPDATE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT_SRC="$UPDATE_DIR/skeleton/usr/bin/airplanes-first-run"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ROOT="$WORK/root"
STUB="$WORK/bin"
APL_FEED_LOG="$WORK/apl-feed.argv"
mkdir -p "$ROOT/boot" "$ROOT/usr/local/bin" "$STUB"

# Stub apl-feed: log one invocation per line as tab-joined argv tokens.
# Tab is safe — none of the script's call sites pass an argv token that
# contains a literal tab. The script's bash `if ! …; then warn` gate is
# exercised on the success path here; the failure-warning path is
# covered by the static smoke assertion in update-airplanes-rootfs-
# smoke.sh.
cat > "$STUB/apl-feed" <<APL_FEED
#!/usr/bin/env bash
printf '%s' "\$1" >> "$APL_FEED_LOG"
shift
for arg in "\$@"; do
    printf '\t%s' "\$arg" >> "$APL_FEED_LOG"
done
printf '\n' >> "$APL_FEED_LOG"
exit 0
APL_FEED
chmod +x "$STUB/apl-feed"

# Silence everything else. systemctl gets called with is-enabled / is-active
# / enable / disable / stop / start — all return success in this test.
cat > "$STUB/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
exit 0
SYSTEMCTL
chmod +x "$STUB/systemctl"

cat > "$ROOT/usr/local/bin/create-uuid.sh" <<'CREATE_UUID'
#!/usr/bin/env bash
exit 0
CREATE_UUID
chmod +x "$ROOT/usr/local/bin/create-uuid.sh"
cp "$ROOT/usr/local/bin/create-uuid.sh" "$ROOT/usr/local/bin/fix-config.sh"

# Seed a legacy-shaped boot config — the post-bridge migrate-config.sh form.
cat > "$ROOT/boot/airplanes-config.txt" <<'BOOT_CONFIG'
LATITUDE=52.5
LONGITUDE=13.4
ALTITUDE=120m
USER=alice
MLAT_USER="alice"
MLAT_ENABLED=true
MLAT_MARKER=yes
MLAT_PRIVATE=false
DUMP978=no
DUMP1090=yes
GRAPHS1090=yes
BOOT_CONFIG

# Sed-rewrite absolute paths in a copy of the script. The substitutions
# are narrow — only the paths this test cares about — so a future
# unrelated absolute path in the script won't be silently rerouted.
SCRIPT_COPY="$WORK/airplanes-first-run"
sed \
    -e "s|/boot/airplanes-config\.txt|$ROOT/boot/airplanes-config.txt|g" \
    -e "s|/run/airplanes-config\.txt|$ROOT/run-airplanes-config.txt|g" \
    -e "s|/usr/local/bin/create-uuid\.sh|$ROOT/usr/local/bin/create-uuid.sh|g" \
    -e "s|/usr/local/bin/fix-config\.sh|$ROOT/usr/local/bin/fix-config.sh|g" \
    -e "s|/boot/firstboot\.sh|$ROOT/boot/firstboot.sh|g" \
    "$SCRIPT_SRC" > "$SCRIPT_COPY"
chmod +x "$SCRIPT_COPY"

PATH="$STUB:$PATH" bash "$SCRIPT_COPY"

if [[ ! -s "$APL_FEED_LOG" ]]; then
    echo "FAIL: apl-feed was not invoked" >&2
    exit 1
fi

expected_line=$'import\tlegacy-config\t--no-restart\t'"$ROOT/boot/airplanes-config.txt"
if ! grep -Fxq -- "$expected_line" "$APL_FEED_LOG"; then
    echo "FAIL: apl-feed argv not as expected." >&2
    echo "  expected: $expected_line" >&2
    echo "  actual log:" >&2
    cat "$APL_FEED_LOG" >&2
    exit 1
fi

echo "first-run import call test passed"
