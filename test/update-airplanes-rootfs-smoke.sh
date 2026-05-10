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

CASE_DIR=""
UPDATE_SOURCE=""
UPDATE_BARE=""
READSB_SOURCE=""
READSB_BARE=""
FEED_SOURCE=""
FEED_BARE=""
ROOT_DIR=""
STUB_DIR=""
COMMAND_LOG=""
FEED_UPDATE_LOG=""
TAR1090_LOG=""

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

setup_case() {
    local name="$1"

    UPDATE_BRANCH="rootfs-smoke"
    READSB_BRANCH="rootfs-smoke"
    FEED_BRANCH="rootfs-smoke"
    CASE_DIR="$WORK_DIR/$name"
    UPDATE_SOURCE="$CASE_DIR/airplanes-update-source"
    UPDATE_BARE="$CASE_DIR/airplanes-update.git"
    READSB_SOURCE="$CASE_DIR/readsb-source"
    READSB_BARE="$CASE_DIR/readsb.git"
    FEED_SOURCE="$CASE_DIR/feed-source"
    FEED_BARE="$CASE_DIR/feed.git"
    ROOT_DIR="$CASE_DIR/rootfs"
    STUB_DIR="$CASE_DIR/bin"
    COMMAND_LOG="$CASE_DIR/commands.log"
    FEED_UPDATE_LOG="$CASE_DIR/feed-update.log"
    TAR1090_LOG="$CASE_DIR/tar1090.log"

    mkdir -p "$CASE_DIR"
}

make_repo() {
    local source="$1"
    local branch="$2"
    local bare="$3"
    shift 3
    # Remaining args are tags to attach to the single commit. Used by the
    # feed-repo fixture to exercise the bridge's tag resolver.
    local tag

    git -C "$source" init -q -b "$branch"
    git -C "$source" config user.email "rootfs-smoke@example.invalid"
    git -C "$source" config user.name "Rootfs Smoke"
    git -C "$source" add .
    git -C "$source" commit -q -m "rootfs smoke fixture"
    for tag in "$@"; do
        git -C "$source" tag "$tag"
    done
    git clone --quiet --bare "$source" "$bare"
}

make_update_repo() {
    mkdir -p "$UPDATE_SOURCE"
    cp -a "$UPDATE_DIR/." "$UPDATE_SOURCE/"
    rm -rf "$UPDATE_SOURCE/.git"
    make_repo "$UPDATE_SOURCE" "$UPDATE_BRANCH" "$UPDATE_BARE"
}

make_installed_update_checkout() {
    local target="$1"
    local branch="$2"

    mkdir -p "$target"
    cp -a "$UPDATE_DIR/." "$target/"
    rm -rf "$target/.git"
    git -C "$target" init -q -b "$branch"
    git -C "$target" config user.email "rootfs-smoke@example.invalid"
    git -C "$target" config user.name "Rootfs Smoke"
    git -C "$target" add .
    git -C "$target" commit -q -m "installed updater fixture"
}

make_raw_update_script() {
    local target="$1"

    mkdir -p "$target"
    cp "$UPDATE_DIR/update-airplanes.sh" "$target/update-airplanes.sh"
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
    # Optional tag list: caller can pass tags after FEED_BRANCH. Default is
    # no tags, which forces the bridge's stable-tag resolver to fail closed
    # — matches what most callers want (they explicitly set
    # AIRPLANES_FEED_BRANCH to bypass resolution).
    local -a feed_tags=("$@")
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
    printf 'mode=%s\n' "${AIRPLANES_TEST_FEED_UPDATE_MODE:-success}"
} >> "$FEED_UPDATE_LOG"

if [[ "${AIRPLANES_TEST_FEED_UPDATE_MODE:-success}" == "fail" ]]; then
    printf 'intentional feed/update.sh failure\n' >&2
    exit 1
fi

mkdir -p "$AIRPLANES_ROOT/boot" "$AIRPLANES_ROOT/usr/local/share/airplanes"
printf '%s\n' '11111111-2222-3333-4444-555555555555' > "$AIRPLANES_ROOT/boot/airplanes-uuid"
printf '%s\n' 'feed update ran' > "$AIRPLANES_ROOT/usr/local/share/airplanes/feed-update-marker"
SH
    chmod +x "$FEED_SOURCE/update.sh"
    make_repo "$FEED_SOURCE" "$FEED_BRANCH" "$FEED_BARE" "${feed_tags[@]}"
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
if [[ "${AIRPLANES_TEST_IS_CHROOT:-0}" == "1" ]]; then
    exit 0
fi
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

run_update() {
    local feed_repo="${1:-file://$FEED_BARE}"
    local feed_mode="${2:-success}"
    local package_manager="${3:-}"
    local is_chroot="${4:-0}"
    local pass_branch_env="${5:-1}"
    local script_path="${6:-$UPDATE_DIR/update-airplanes.sh}"
    local -a env_args
    local status

    env_args=(
        "PATH=$STUB_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "COMMAND_LOG=$COMMAND_LOG"
        "FEED_UPDATE_LOG=$FEED_UPDATE_LOG"
        "TAR1090_LOG=$TAR1090_LOG"
        "AIRPLANES_ROOT=$ROOT_DIR"
        "AIRPLANES_UPDATE_REPO=file://$UPDATE_BARE"
        "AIRPLANES_READSB_REPO=file://$READSB_BARE"
        "AIRPLANES_READSB_BRANCH=$READSB_BRANCH"
        "AIRPLANES_FEED_REPO=$feed_repo"
        "AIRPLANES_TEST_FEED_UPDATE_MODE=$feed_mode"
        "AIRPLANES_TEST_IS_CHROOT=$is_chroot"
        "AIRPLANES_PACKAGE_MANAGER=$package_manager"
    )
    if [[ "$pass_branch_env" == "1" ]]; then
        env_args+=(
            "AIRPLANES_UPDATE_BRANCH=$UPDATE_BRANCH"
            "AIRPLANES_FEED_BRANCH=$FEED_BRANCH"
        )
    fi

    set +e
    env -u AIRPLANES_UPDATE_BRANCH -u AIRPLANES_FEED_BRANCH "${env_args[@]}" bash "$script_path"
    status=$?
    set -e

    return "$status"
}

prepare_common_fixture() {
    make_update_repo
    make_readsb_repo
    make_feed_repo "$@"
    prepare_rootfs
    write_stubs
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    grep -q -- "$pattern" "$file" || fail "$file does not contain $pattern"
}

assert_not_contains() {
    local file="$1"
    local pattern="$2"
    if [[ -f "$file" ]] && grep -q -- "$pattern" "$file"; then
        fail "$file unexpectedly contains $pattern"
    fi
}

assert_initial_restart_order() {
    local actual="$CASE_DIR/restarts.actual"
    local expected="$CASE_DIR/restarts.expected"

    grep '^systemctl restart ' "$COMMAND_LOG" | head -n 3 > "$actual"
    cat > "$expected" <<'EOF'
systemctl restart readsb
systemctl restart airplanes-feed
systemctl restart airplanes-978
EOF

    if ! diff -u "$expected" "$actual"; then
        fail "unexpected initial systemctl restart order"
    fi
}

assert_success_state() {
    local expected_package_manager="$1"

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
    assert_contains "$FEED_UPDATE_LOG" "^package_manager=$expected_package_manager$"
    assert_contains "$FEED_UPDATE_LOG" '^mode=success$'
    assert_contains "$TAR1090_LOG" '^tar1090 install$'
    assert_contains "$COMMAND_LOG" '^apt-get install '
    assert_contains "$COMMAND_LOG" '^systemctl daemon-reload$'
    assert_contains "$COMMAND_LOG" '^systemctl enable airplanes-first-run.service readsb.service airplanes-mlat.service airplanes-feed.service pingfail.service$'
    assert_contains "$COMMAND_LOG" '^systemctl mask autogain1090.timer$'
    assert_initial_restart_order
    assert_contains "$COMMAND_LOG" '^adduser --system --home '
    assert_contains "$COMMAND_LOG" '^adduser readsb plugdev$'
    assert_contains "$COMMAND_LOG" '^adduser readsb dialout$'
    assert_contains "$COMMAND_LOG" '^chown readsb '
}

test_success_path() {
    setup_case success
    prepare_common_fixture
    run_update || fail "success path failed"
    assert_success_state apt
    echo "success path passed"
}

test_package_manager_override() {
    setup_case package-manager-none
    prepare_common_fixture
    run_update "file://$FEED_BARE" success none || fail "package-manager override path failed"
    assert_success_state none
    echo "package-manager override path passed"
}

test_dev_checkout_pulls_update_dev_resolves_feed_tag() {
    # airplanes-update/dev checkout: UPDATE_BRANCH defaults to "dev" (the
    # script's own branch). FEED_BRANCH is no longer branch-derived — the
    # bridge always resolves the latest stable feed tag via git ls-remote,
    # regardless of the script's checkout branch.
    setup_case dev-checkout-resolves-feed-tag
    UPDATE_BRANCH="dev"
    FEED_BRANCH="v0.1.0"
    prepare_common_fixture v0.1.0
    make_installed_update_checkout "$CASE_DIR/installed-update" dev

    run_update "file://$FEED_BARE" success "" 0 0 "$CASE_DIR/installed-update/update-airplanes.sh" \
        || fail "dev checkout resolver path failed"
    assert_success_state apt
    echo "dev checkout pulls update/dev, resolves feed at latest stable tag — passed"
}

test_raw_script_pulls_update_main_resolves_feed_tag() {
    # No-checkout (curl-piped) airplanes-update: DEFAULT_BRANCH falls back
    # to "main". Same as above, FEED_BRANCH is resolver-driven not
    # branch-derived.
    setup_case raw-script-resolves-feed-tag
    UPDATE_BRANCH="main"
    FEED_BRANCH="v0.1.0"
    prepare_common_fixture v0.1.0
    make_raw_update_script "$CASE_DIR/raw-update"

    run_update "file://$FEED_BARE" success "" 0 0 "$CASE_DIR/raw-update/update-airplanes.sh" \
        || fail "raw script resolver path failed"
    assert_success_state apt
    echo "raw script pulls update/main, resolves feed at latest stable tag — passed"
}

test_bridge_fails_closed_when_no_feed_tags() {
    # Fixture feed has no v* tags. The resolver returns 1 (no matching
    # tags) and the bridge aborts before touching the legacy stack.
    setup_case no-feed-tags-fails-closed
    UPDATE_BRANCH="dev"
    FEED_BRANCH="dev"
    prepare_common_fixture   # no tag args → no tags on fixture
    make_installed_update_checkout "$CASE_DIR/installed-update" dev

    if run_update "file://$FEED_BARE" success "" 0 0 "$CASE_DIR/installed-update/update-airplanes.sh"; then
        fail "bridge unexpectedly succeeded with no feed tags"
    fi

    [[ ! -f "$ROOT_DIR/usr/local/share/airplanes/feed-update-marker" ]] \
        || fail "feed update marker exists after fail-closed abort"
    [[ ! -e "$TAR1090_LOG" ]] || fail "tar1090 ran after bridge fail-closed abort"
    echo "bridge fail-closed on missing feed tags — passed"
}

test_bridge_resolves_highest_semver_tag() {
    # Fixture feed has multiple v* tags. Resolver picks the highest semver.
    # Mixed bag includes prerelease and leading-zero tags that must be
    # ignored (mirror feed-side regex).
    setup_case bridge-picks-highest-semver
    UPDATE_BRANCH="dev"
    FEED_BRANCH="v1.0.0"
    prepare_common_fixture v0.1.0 v0.2.0 v0.2.0-rc.1 v01.02.03 v1.0.0
    make_installed_update_checkout "$CASE_DIR/installed-update" dev

    run_update "file://$FEED_BARE" success "" 0 0 "$CASE_DIR/installed-update/update-airplanes.sh" \
        || fail "highest-semver resolver path failed"
    assert_success_state apt
    echo "bridge picks highest semver tag — passed"
}

test_bad_feed_repo_fails_before_tar1090() {
    setup_case bad-feed-repo
    prepare_common_fixture
    if run_update "file://$CASE_DIR/missing-feed.git"; then
        fail "bad feed repo unexpectedly succeeded"
    fi

    [[ ! -e "$TAR1090_LOG" ]] || fail "tar1090 ran after feed repo clone failure"
    [[ ! -e "$ROOT_DIR/tmp/update-airplanes" ]] || fail "temporary updater directory was not cleaned after feed repo clone failure"
    assert_not_contains "$COMMAND_LOG" '^systemctl restart airplanes-mlat$'
    echo "bad feed repo failure path passed"
}

test_feed_update_failure_propagates() {
    setup_case feed-update-fails
    prepare_common_fixture
    if run_update "file://$FEED_BARE" fail; then
        fail "failing feed/update.sh unexpectedly succeeded"
    fi

    assert_contains "$FEED_UPDATE_LOG" '^mode=fail$'
    [[ ! -e "$TAR1090_LOG" ]] || fail "tar1090 ran after feed/update.sh failure"
    [[ ! -f "$ROOT_DIR/usr/local/share/airplanes/feed-update-marker" ]] || fail "feed update marker exists after failing feed/update.sh"
    [[ ! -e "$ROOT_DIR/tmp/update-airplanes" ]] || fail "temporary updater directory was not cleaned after feed/update.sh failure"
    echo "feed/update.sh failure path passed"
}

test_chroot_skips_feed_update() {
    setup_case chroot
    prepare_common_fixture
    run_update "file://$CASE_DIR/missing-feed.git" success "" 1 || fail "chroot path failed"

    [[ ! -e "$FEED_UPDATE_LOG" ]] || fail "feed/update.sh ran in chroot"
    [[ ! -f "$ROOT_DIR/usr/local/share/airplanes/feed-update-marker" ]] || fail "feed update marker exists in chroot"
    [[ ! -f "$ROOT_DIR/boot/airplanes-version-decoder" ]] || fail "decoder version was written in chroot"
    [[ ! -e "$ROOT_DIR/tmp/update-airplanes" ]] || fail "temporary updater directory was not cleaned after chroot exit"
    assert_contains "$ROOT_DIR/boot/airplanes-config.txt" '^LATITUDE=0.00000$'
    assert_contains "$ROOT_DIR/boot/airplanes-config.txt" '^GRAPHS1090=yes$'
    assert_contains "$TAR1090_LOG" '^tar1090 install$'
    assert_initial_restart_order
    echo "chroot skip path passed"
}

main() {
    [[ -d "$UPDATE_DIR" ]] || fail "update dir not found: $UPDATE_DIR"
    mkdir -p "$WORK_DIR"

    test_success_path
    test_package_manager_override
    test_dev_checkout_pulls_update_dev_resolves_feed_tag
    test_raw_script_pulls_update_main_resolves_feed_tag
    test_bridge_fails_closed_when_no_feed_tags
    test_bridge_resolves_highest_semver_tag
    test_bad_feed_repo_fails_before_tar1090
    test_feed_update_failure_propagates
    test_chroot_skips_feed_update

    echo "update-airplanes rootfs smoke passed"
}

main "$@"
