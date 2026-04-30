#!/usr/bin/env bash
set -euo pipefail

UPDATE_DIR="${AIRPLANES_UPDATE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK_DIR="${AIRPLANES_UPDATE_ROOTFS_WORK_DIR:-}"
KEEP_WORK_DIR="${AIRPLANES_UPDATE_ROOTFS_KEEP_WORK_DIR:-0}"

if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="$(mktemp -d)"
else
    mkdir -p "$WORK_DIR"
    WORK_DIR="$(cd "$WORK_DIR" && pwd)"
fi

UPDATE_BRANCH="rootfs-smoke"
READSB_BRANCH="rootfs-smoke"
FEED_BRANCH="rootfs-smoke"
UPDATE_SOURCE="$WORK_DIR/airplanes-update-source"
UPDATE_BARE="$WORK_DIR/airplanes-update.git"
READSB_SOURCE="$WORK_DIR/readsb-source"
READSB_BARE="$WORK_DIR/readsb.git"
FEED_SOURCE="$WORK_DIR/feed-source"
FEED_BARE="$WORK_DIR/feed.git"
ROOT_DIR="$WORK_DIR/rootfs"
STUB_DIR="$WORK_DIR/bin"
COMMAND_LOG="$WORK_DIR/commands.log"
FEED_UPDATE_LOG="$WORK_DIR/feed-update.log"
TAR1090_LOG="$WORK_DIR/tar1090.log"

cleanup() {
    if [[ "$KEEP_WORK_DIR" != "1" ]]; then
        rm -rf "$WORK_DIR"
    else
        echo "Keeping rootfs smoke work dir: $WORK_DIR"
    fi
}
trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    if [[ -f "$COMMAND_LOG" ]]; then
        echo "--- command log ---" >&2
        cat "$COMMAND_LOG" >&2
    fi
    if [[ -f "$FEED_UPDATE_LOG" ]]; then
        echo "--- feed update log ---" >&2
        cat "$FEED_UPDATE_LOG" >&2
    fi
    exit 1
}

make_repo() {
    local source="$1"
    local branch="$2"
    local bare="$3"

    git -C "$source" init -q -b "$branch"
    git -C "$source" config user.email "rootfs-smoke@example.invalid"
    git -C "$source" config user.name "Rootfs Smoke"
    git -C "$source" add .
    git -C "$source" commit -q -m "rootfs smoke fixture"
    git clone --quiet --bare "$source" "$bare"
}

make_update_repo() {
    mkdir -p "$UPDATE_SOURCE"
    cp -a "$UPDATE_DIR/." "$UPDATE_SOURCE/"
    rm -rf "$UPDATE_SOURCE/.git"
    make_repo "$UPDATE_SOURCE" "$UPDATE_BRANCH" "$UPDATE_BARE"
}

make_readsb_repo() {
    mkdir -p "$READSB_SOURCE"
    cat > "$READSB_SOURCE/Makefile" <<'MAKE'
.RECIPEPREFIX := >
all:
>printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > readsb
>printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > viewadsb
>chmod +x readsb viewadsb
MAKE
    make_repo "$READSB_SOURCE" "$READSB_BRANCH" "$READSB_BARE"
}

make_feed_repo() {
    mkdir -p "$FEED_SOURCE"
    cat > "$FEED_SOURCE/update.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

: "${AIRPLANES_ROOT:?}"
: "${FEED_UPDATE_LOG:?}"

{
    printf 'root=%s\n' "$AIRPLANES_ROOT"
    printf 'repo=%s\n' "${AIRPLANES_FEED_REPO:-}"
    printf 'branch=%s\n' "${AIRPLANES_FEED_BRANCH:-}"
    printf 'package_manager=%s\n' "${AIRPLANES_PACKAGE_MANAGER:-}"
} >> "$FEED_UPDATE_LOG"

mkdir -p "$AIRPLANES_ROOT/boot" "$AIRPLANES_ROOT/usr/local/share/airplanes"
printf '%s\n' '11111111-2222-3333-4444-555555555555' > "$AIRPLANES_ROOT/boot/airplanes-uuid"
printf '%s\n' 'feed update ran' > "$AIRPLANES_ROOT/usr/local/share/airplanes/feed-update-marker"
SH
    chmod +x "$FEED_SOURCE/update.sh"
    make_repo "$FEED_SOURCE" "$FEED_BRANCH" "$FEED_BARE"
}

prepare_rootfs() {
    mkdir -p \
        "$ROOT_DIR/boot" \
        "$ROOT_DIR/etc/systemd/system/dhcpcd.service.d" \
        "$ROOT_DIR/tmp" \
        "$ROOT_DIR/usr/bin" \
        "$ROOT_DIR/var/log"

    cat > "$ROOT_DIR/boot/airplanes-config.txt" <<'EOF'
USER=preserved-user
DUMP1090=no
EOF
    printf '%s\n' 'remove me' > "$ROOT_DIR/etc/systemd/system/dhcpcd.service.d/wait.conf"
}

write_stubs() {
    mkdir -p "$STUB_DIR"

    cat > "$STUB_DIR/apt-get" <<'SH'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${COMMAND_LOG:?}"
exit 0
SH
    cat > "$STUB_DIR/id" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" && -z "${2:-}" ]]; then
    printf '0\n'
    exit 0
fi
if [[ "${1:-}" == "-u" ]]; then
    exit 1
fi
/usr/bin/id "$@"
SH
    cat > "$STUB_DIR/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${COMMAND_LOG:?}"
if [[ "${1:-}" == "is-enabled" ]]; then
    exit 0
fi
exit 0
SH
    cat > "$STUB_DIR/adduser" <<'SH'
#!/usr/bin/env bash
printf 'adduser %s\n' "$*" >> "${COMMAND_LOG:?}"
exit 0
SH
    cat > "$STUB_DIR/chown" <<'SH'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >> "${COMMAND_LOG:?}"
exit 0
SH
    cat > "$STUB_DIR/ischroot" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    cat > "$STUB_DIR/wget" <<'SH'
#!/usr/bin/env bash
cat <<'TAR1090'
printf 'tar1090 install\n' >> "${TAR1090_LOG:?}"
TAR1090
SH
    chmod +x "$STUB_DIR"/*
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    grep -q -- "$pattern" "$file" || fail "$file does not contain $pattern"
}

main() {
    [[ -d "$UPDATE_DIR" ]] || fail "update dir not found: $UPDATE_DIR"
    mkdir -p "$WORK_DIR"

    make_update_repo
    make_readsb_repo
    make_feed_repo
    prepare_rootfs
    write_stubs

    PATH="$STUB_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    COMMAND_LOG="$COMMAND_LOG" \
    FEED_UPDATE_LOG="$FEED_UPDATE_LOG" \
    TAR1090_LOG="$TAR1090_LOG" \
    AIRPLANES_ROOT="$ROOT_DIR" \
    AIRPLANES_UPDATE_REPO="file://$UPDATE_BARE" \
    AIRPLANES_UPDATE_BRANCH="$UPDATE_BRANCH" \
    AIRPLANES_READSB_REPO="file://$READSB_BARE" \
    AIRPLANES_READSB_BRANCH="$READSB_BRANCH" \
    AIRPLANES_FEED_REPO="file://$FEED_BARE" \
    AIRPLANES_FEED_BRANCH="$FEED_BRANCH" \
        bash "$UPDATE_DIR/update-airplanes.sh"

    [[ -f "$ROOT_DIR/etc/systemd/system/airplanes-first-run.service" ]] || fail "missing first-run service"
    [[ -f "$ROOT_DIR/usr/local/bin/create-uuid.sh" ]] || fail "missing create-uuid.sh"
    [[ -x "$ROOT_DIR/usr/bin/airplanes-feeder" ]] || fail "missing airplanes-feeder"
    [[ -x "$ROOT_DIR/usr/bin/airplanes-978" ]] || fail "missing airplanes-978"
    [[ -x "$ROOT_DIR/usr/bin/readsb" ]] || fail "missing readsb"
    [[ -x "$ROOT_DIR/usr/bin/viewadsb" ]] || fail "missing viewadsb"
    [[ -d "$ROOT_DIR/var/globe_history" ]] || fail "missing globe history directory"
    [[ ! -e "$ROOT_DIR/etc/systemd/system/dhcpcd.service.d/wait.conf" ]] || fail "wait.conf was not removed"
    [[ ! -e "$ROOT_DIR/tmp/update-airplanes" ]] || fail "temporary updater directory was not removed"

    assert_contains "$ROOT_DIR/boot/airplanes-config.txt" '^USER=preserved-user$'
    assert_contains "$ROOT_DIR/boot/airplanes-config.txt" '^DUMP1090=no$'
    assert_contains "$ROOT_DIR/boot/airplanes-config.txt" '^LATITUDE=0.00000$'
    assert_contains "$ROOT_DIR/boot/airplanes-config.txt" '^GRAPHS1090=yes$'
    [[ "$(grep -c '^DUMP1090=' "$ROOT_DIR/boot/airplanes-config.txt")" == "1" ]] \
        || fail "DUMP1090 was duplicated"
    [[ "$(cat "$ROOT_DIR/boot/airplanes-uuid")" == "11111111-2222-3333-4444-555555555555" ]] \
        || fail "feed update did not create boot UUID"
    [[ -f "$ROOT_DIR/boot/airplanes-version-decoder" ]] || fail "missing decoder version"
    [[ -f "$ROOT_DIR/usr/local/share/airplanes/feed-update-marker" ]] || fail "feed update marker missing"

    assert_contains "$FEED_UPDATE_LOG" "root=$ROOT_DIR"
    assert_contains "$FEED_UPDATE_LOG" "repo=file://$FEED_BARE"
    assert_contains "$FEED_UPDATE_LOG" "branch=$FEED_BRANCH"
    assert_contains "$FEED_UPDATE_LOG" '^package_manager=apt$'
    assert_contains "$TAR1090_LOG" '^tar1090 install$'
    assert_contains "$COMMAND_LOG" '^apt-get install '
    assert_contains "$COMMAND_LOG" '^systemctl daemon-reload$'
    assert_contains "$COMMAND_LOG" '^systemctl enable airplanes-first-run.service readsb.service airplanes-mlat.service airplanes-feed.service pingfail.service$'
    assert_contains "$COMMAND_LOG" '^systemctl mask autogain1090.timer$'
    assert_contains "$COMMAND_LOG" '^systemctl restart readsb$'
    assert_contains "$COMMAND_LOG" '^systemctl restart airplanes-978$'
    assert_contains "$COMMAND_LOG" '^adduser --system --home '
    assert_contains "$COMMAND_LOG" '^adduser readsb plugdev$'
    assert_contains "$COMMAND_LOG" '^adduser readsb dialout$'
    assert_contains "$COMMAND_LOG" '^chown readsb '

    echo "update-airplanes rootfs smoke passed"
}

main "$@"
