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
SYSTEMCTL_LOG="$WORK/systemctl.argv"
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

# Log systemctl invocations as tab-joined argv so the assertion below can
# verify --no-block reaches start calls (After=airplanes-first-run.service
# units would deadlock on a synchronous start while this Type=oneshot is
# still running). is-enabled / is-active probes return non-zero so the
# script exercises the enable + start arms rather than the early-skip
# arms; everything else returns 0.
cat > "$STUB/systemctl" <<SYSTEMCTL
#!/usr/bin/env bash
printf '%s' "\$1" >> "$SYSTEMCTL_LOG"
shift
for arg in "\$@"; do
    printf '\t%s' "\$arg" >> "$SYSTEMCTL_LOG"
done
printf '\n' >> "$SYSTEMCTL_LOG"
sub="\$(awk -F'\t' '{print \$1; exit}' "$SYSTEMCTL_LOG" | tail -n 1)"
# The first column of the last logged line is the subcommand.
last="\$(tail -n 1 "$SYSTEMCTL_LOG" | cut -f1)"
case "\$last" in
    is-enabled|is-active) exit 1 ;;
    *) exit 0 ;;
esac
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

# Every `start` call (the enable arm of services-handle) must carry
# --no-block. A bare `systemctl start <unit>` from inside this Type=
# oneshot script deadlocks against any unit that declares After=
# airplanes-first-run.service.
if [[ ! -s "$SYSTEMCTL_LOG" ]]; then
    echo "FAIL: systemctl was not invoked" >&2
    exit 1
fi
bare_starts="$(awk -F'\t' '$1 == "start" { for (i=2; i<=NF; i++) if ($i == "--no-block") next; print }' "$SYSTEMCTL_LOG")"
if [[ -n "$bare_starts" ]]; then
    echo "FAIL: systemctl start without --no-block:" >&2
    printf '  %s\n' "$bare_starts" >&2
    exit 1
fi
# Sanity: at least one start fired in the enable arm. fixture has DUMP1090=yes
# and GRAPHS1090=yes so airplanes-mlat / graphs1090 / autogain1090.timer
# should all have been issued.
start_count="$(awk -F'\t' '$1 == "start" { n++ } END { print n+0 }' "$SYSTEMCTL_LOG")"
if (( start_count == 0 )); then
    echo "FAIL: no systemctl start calls observed (stub or fixture broken)" >&2
    cat "$SYSTEMCTL_LOG" >&2
    exit 1
fi

echo "first-run import call test passed"
