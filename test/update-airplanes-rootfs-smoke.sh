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
    # pass_feed_branch_env controls the AIRPLANES_FEED_BRANCH env var that
    # the bridge uses to decide whether to defer to feed's release-channel
    # resolution. AIRPLANES_UPDATE_BRANCH is always passed because the
    # bridge's auto-detection of its own update branch is orthogonal —
    # without it the bridge defaults to "main" and the rootfs-smoke
    # fixture's bare repo (only carrying the rootfs-smoke ref) makes the
    # initial clone fail regardless of feed-branch semantics.
    local pass_feed_branch_env="${5:-1}"
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
        "AIRPLANES_UPDATE_BRANCH=$UPDATE_BRANCH"
        "AIRPLANES_READSB_REPO=file://$READSB_BARE"
        "AIRPLANES_READSB_BRANCH=$READSB_BRANCH"
        "AIRPLANES_FEED_REPO=$feed_repo"
        "AIRPLANES_TEST_FEED_UPDATE_MODE=$feed_mode"
        "AIRPLANES_TEST_IS_CHROOT=$is_chroot"
        "AIRPLANES_PACKAGE_MANAGER=$package_manager"
    )
    if [[ "$pass_feed_branch_env" == "1" ]]; then
        env_args+=("AIRPLANES_FEED_BRANCH=$FEED_BRANCH")
    fi

    set +e
    env -u AIRPLANES_FEED_BRANCH "${env_args[@]}" bash "$script_path"
    status=$?
    set -e

    return "$status"
}

prepare_common_fixture() {
    make_update_repo
    make_readsb_repo
    make_feed_repo
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
    # The branch the bridge passes through to feed/update.sh. Empty means
    # the bridge did NOT pass AIRPLANES_FEED_BRANCH — the expected default
    # when the operator hasn't pinned a branch via env, so feed's update.sh
    # falls back to /etc/airplanes/release-channel resolution.
    local expected_feed_branch_in_log="${2-$FEED_BRANCH}"

    [[ -f "$ROOT_DIR/etc/systemd/system/airplanes-first-run.service" ]] || fail "missing first-run service"
    # The first-run script must translate /boot/airplanes-config.txt into
    # feed.env via apl-feed import legacy-config so legacy webconfig saves
    # propagate to the new feed daemons on next service restart.
    # --no-restart is required because this service is Type=oneshot and
    # the legacy units After= it.
    assert_contains "$ROOT_DIR/usr/bin/airplanes-first-run" 'apl-feed import legacy-config --no-restart /boot/airplanes-config.txt'
    [[ -f "$ROOT_DIR/usr/local/bin/create-uuid.sh" ]] || fail "missing create-uuid.sh"
    [[ -x "$ROOT_DIR/usr/bin/airplanes-feeder" ]] || fail "missing airplanes-feeder"
    [[ -x "$ROOT_DIR/usr/bin/airplanes-978" ]] || fail "missing airplanes-978"
    [[ -x "$ROOT_DIR/usr/bin/readsb" ]] || fail "missing readsb"
    [[ -x "$ROOT_DIR/usr/bin/viewadsb" ]] || fail "missing viewadsb"
    [[ -d "$ROOT_DIR/var/globe_history" ]] || fail "missing globe history directory"
    [[ ! -e "$ROOT_DIR/etc/systemd/system/dhcpcd.service.d/wait.conf" ]] || fail "wait.conf was not removed"
    [[ ! -e "$ROOT_DIR/tmp/update-airplanes" ]] || fail "temporary updater directory was not removed"

    assert_contains "$ROOT_DIR/boot/airplanes-config.txt" '^USER="preserved-user"$'
    assert_contains "$ROOT_DIR/boot/airplanes-config.txt" '^MLAT_USER="preserved-user"$'
    assert_contains "$ROOT_DIR/boot/airplanes-config.txt" '^MLAT_ENABLED=true$'
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
    assert_contains "$FEED_UPDATE_LOG" "^branch=$expected_feed_branch_in_log$"
    assert_contains "$FEED_UPDATE_LOG" "^package_manager=$expected_package_manager$"
    assert_contains "$FEED_UPDATE_LOG" '^mode=success$'

    # release-channel — default expectation is "stable" (bridge seeds on
    # a box that didn't already have one). Tests that pre-seed a specific
    # value override via the 3rd arg.
    local expected_release_channel="${3:-stable}"
    [[ -f "$ROOT_DIR/etc/airplanes/release-channel" ]] \
        || fail "missing /etc/airplanes/release-channel"
    [[ "$(cat "$ROOT_DIR/etc/airplanes/release-channel")" == "$expected_release_channel" ]] \
        || fail "release-channel = $(cat "$ROOT_DIR/etc/airplanes/release-channel"), want $expected_release_channel"
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

test_dev_checkout_defaults_to_dev_branches() {
    setup_case dev-branch-defaults
    UPDATE_BRANCH="dev"
    FEED_BRANCH="dev"
    prepare_common_fixture
    make_installed_update_checkout "$CASE_DIR/installed-update" dev
    # Pre-seed release-channel=dev so the tightened fallback maps the
    # channel to feed branch dev. Without this, the bridge would
    # self-heal the missing file to stable, and the channel→branch map
    # would then pin feed to main — decoupled from the bridge's own
    # checkout branch (see round-3 self-heal tightening).
    mkdir -p "$ROOT_DIR/etc/airplanes"
    printf 'dev\n' > "$ROOT_DIR/etc/airplanes/release-channel"

    run_update "file://$FEED_BARE" success "" 0 0 "$CASE_DIR/installed-update/update-airplanes.sh" \
        || fail "dev checkout default path failed"
    # Operator did not pin AIRPLANES_FEED_BRANCH. The feed bare repo
    # has no vX.Y.Z tags yet, so the bridge's preflight detects that
    # and falls back to the channel→branch map: release-channel=dev
    # maps to feed branch dev. The stub feed/update.sh logs the pinned
    # branch verbatim. Once v0.1.0 is cut on the real feed remote, this
    # same harness shape would flip to the empty-branch deferred path
    # (see test_tag_present_uses_deferred_resolution below for that
    # scenario explicitly).
    assert_success_state apt "$FEED_BRANCH" dev
    echo "dev checkout branch defaults path passed"
}

test_raw_script_defaults_to_main_branches() {
    setup_case raw-main-defaults
    UPDATE_BRANCH="main"
    FEED_BRANCH="main"
    prepare_common_fixture
    make_raw_update_script "$CASE_DIR/raw-update"

    run_update "file://$FEED_BARE" success "" 0 0 "$CASE_DIR/raw-update/update-airplanes.sh" \
        || fail "raw script default path failed"
    # Same as the dev-checkout case but auto-detects main. No tags on
    # the feed bare repo so the bridge's preflight fallback fires.
    assert_success_state apt "$FEED_BRANCH"
    echo "raw script branch defaults path passed"
}

# Helper: tests that exercise the deferred-feed-branch path
# (pass_feed_branch_env=0) need the bridge's auto-detected branch to
# match the feed bare repo's branch. airplanes_default_branch() only
# ever returns "main" or "dev", never the harness default
# "rootfs-smoke", so we run the bridge from an installed-update copy
# pinned to "dev" + matching feed bare on dev.
prepare_deferred_path_fixture() {
    UPDATE_BRANCH="dev"
    FEED_BRANCH="dev"
    prepare_common_fixture
    make_installed_update_checkout "$CASE_DIR/installed-update" dev
}

test_release_channel_already_present_is_preserved() {
    setup_case release-channel-preserved
    UPDATE_BRANCH="main"
    FEED_BRANCH="main"
    prepare_common_fixture
    make_installed_update_checkout "$CASE_DIR/installed-update" main
    git -C "$FEED_BARE" branch dev main
    mkdir -p "$ROOT_DIR/etc/airplanes"
    echo "dev" > "$ROOT_DIR/etc/airplanes/release-channel"

    # pass_feed_branch_env=0 so the bridge actually exercises the
    # deferred path. With the env var set, feed/update.sh ignores
    # release-channel entirely and the test wouldn't observe whether
    # the bridge is clobbering the file.
    run_update "file://$FEED_BARE" success "" 0 0 \
        "$CASE_DIR/installed-update/update-airplanes.sh" \
        || fail "release-channel-preserved path failed"

    # Operator pinned dev before running the bridge; the bridge must
    # NOT clobber that with stable.
    [[ "$(cat "$ROOT_DIR/etc/airplanes/release-channel")" == "dev" ]] \
        || fail "release-channel was clobbered: $(cat "$ROOT_DIR/etc/airplanes/release-channel")"
    echo "release-channel preserved path passed"
}

test_release_channel_empty_file_is_self_healed() {
    setup_case release-channel-empty
    prepare_deferred_path_fixture
    mkdir -p "$ROOT_DIR/etc/airplanes"
    # Simulate a previous interrupted write — empty file present but
    # contentless. Bridge should rewrite to "stable" so feed's strict
    # allowlist doesn't reject it.
    : > "$ROOT_DIR/etc/airplanes/release-channel"

    run_update "file://$FEED_BARE" success "" 0 0 \
        "$CASE_DIR/installed-update/update-airplanes.sh" \
        || fail "release-channel-empty self-heal path failed"

    [[ "$(cat "$ROOT_DIR/etc/airplanes/release-channel")" == "stable" ]] \
        || fail "release-channel = $(cat "$ROOT_DIR/etc/airplanes/release-channel"), want stable (empty file should be self-healed)"
    echo "release-channel empty file self-heal passed"
}

test_release_channel_invalid_content_is_preserved() {
    setup_case release-channel-invalid
    prepare_deferred_path_fixture
    mkdir -p "$ROOT_DIR/etc/airplanes"
    # Hand-typed value outside feed's strict allowlist (e.g. `sta`,
    # `deev`). Bridge MUST leave it alone — feed/update.sh's allowlist
    # check will reject it loudly on the next run. Silently rewriting to
    # stable would mask the operator's typo.
    printf 'sta' > "$ROOT_DIR/etc/airplanes/release-channel"

    local stderr_log="$CASE_DIR/stderr.log"
    run_update "file://$FEED_BARE" success "" 0 0 \
        "$CASE_DIR/installed-update/update-airplanes.sh" 2> "$stderr_log" \
        || { cat "$stderr_log" >&2; fail "release-channel-invalid path failed"; }

    [[ "$(cat "$ROOT_DIR/etc/airplanes/release-channel")" == "sta" ]] \
        || fail "release-channel = $(cat "$ROOT_DIR/etc/airplanes/release-channel"), want sta (must not rewrite invalid content)"
    grep -q "release-channel contains 'sta'" "$stderr_log" \
        || { cat "$stderr_log" >&2; fail "bridge did not warn about invalid release-channel value"; }
    grep -q "not in the {stable, main, dev} allowlist" "$stderr_log" \
        || { cat "$stderr_log" >&2; fail "bridge warning missing allowlist hint"; }
    echo "release-channel invalid-content preservation passed"
}

test_release_channel_whitespace_only_is_self_healed() {
    setup_case release-channel-whitespace
    prepare_deferred_path_fixture
    mkdir -p "$ROOT_DIR/etc/airplanes"
    # Whitespace-only file (size > 0 but no usable content). The
    # is-empty check `! -s` wouldn't catch this; the validator-based
    # self-heal does.
    printf '   \n\t\n' > "$ROOT_DIR/etc/airplanes/release-channel"

    run_update "file://$FEED_BARE" success "" 0 0 \
        "$CASE_DIR/installed-update/update-airplanes.sh" \
        || fail "release-channel-whitespace self-heal path failed"

    [[ "$(cat "$ROOT_DIR/etc/airplanes/release-channel")" == "stable" ]] \
        || fail "release-channel = $(cat "$ROOT_DIR/etc/airplanes/release-channel"), want stable"
    echo "release-channel whitespace-only self-heal passed"
}

test_operator_feed_branch_override_passes_through() {
    setup_case operator-feed-branch-override
    FEED_BRANCH="v9.9.9-operator-override"
    prepare_common_fixture

    # Operator sets AIRPLANES_FEED_BRANCH to a distinct value that the
    # harness wouldn't otherwise produce. The bridge must pass that
    # value through verbatim, overriding the release-channel resolution
    # that would otherwise apply. A distinct value rules out the test
    # accidentally passing because of the harness's own env-var
    # injection.
    run_update || fail "operator override path failed"
    assert_success_state apt "v9.9.9-operator-override"
    echo "operator feed-branch override path passed"
}

test_tag_present_uses_deferred_resolution() {
    setup_case tag-present-deferred
    prepare_deferred_path_fixture
    # The dev-checkout and raw-script cases above exercise the no-tags
    # fallback. Once a vX.Y.Z tag exists on the feed remote, the
    # bridge's preflight succeeds and the deferred-resolution path
    # takes over: no AIRPLANES_FEED_BRANCH is passed, and the stub
    # feed/update.sh logs branch=empty. The actual tag → ref
    # resolution lives in feed/update.sh (not exercised here — this
    # test only proves the bridge stops pinning a branch).
    git -C "$FEED_BARE" tag v0.1.0 "$(git -C "$FEED_BARE" rev-parse HEAD)"

    run_update "file://$FEED_BARE" success "" 0 0 \
        "$CASE_DIR/installed-update/update-airplanes.sh" \
        || fail "tag-present deferred-resolution path failed"

    assert_success_state apt ""
    echo "tag-present deferred-resolution path passed"
}

test_no_tags_with_release_channel_dev_falls_back_to_dev() {
    setup_case no-tags-channel-dev
    # Bridge on main, feed bare carrying both main and a separately-
    # named dev branch. release-channel=dev should pin AIRPLANES_FEED_
    # BRANCH=dev despite the bridge's own auto-detected default being
    # main — proving the channel wins over the bridge's checkout state.
    UPDATE_BRANCH="main"
    FEED_BRANCH="main"
    prepare_common_fixture
    make_installed_update_checkout "$CASE_DIR/installed-update" main
    # Add a dev ref to the feed bare so the bridge could theoretically
    # pin it. The harness only seeds one branch by default; here we
    # need two so the channel choice is unambiguous.
    git -C "$FEED_BARE" branch dev main

    mkdir -p "$ROOT_DIR/etc/airplanes"
    echo "dev" > "$ROOT_DIR/etc/airplanes/release-channel"

    run_update "file://$FEED_BARE" success "" 0 0 \
        "$CASE_DIR/installed-update/update-airplanes.sh" \
        || fail "no-tags-channel-dev fallback path failed"

    # The bridge auto-detected main from its installed-update checkout;
    # the channel pin (dev) wins in the fallback selection and the
    # stub feed/update.sh logs branch=dev. release-channel=dev was
    # operator-pinned and must be preserved.
    assert_success_state apt "dev" "dev"
    echo "no-tags release-channel=dev (channel wins over bridge default) passed"
}

test_no_tags_with_release_channel_stable_falls_back_to_main() {
    setup_case no-tags-channel-stable
    # Symmetric to the dev case: a dev-checkout bridge running on a
    # stable-channel feeder must NOT silently flip the operator to dev.
    # Channel rules.
    UPDATE_BRANCH="dev"
    FEED_BRANCH="dev"
    prepare_common_fixture
    make_installed_update_checkout "$CASE_DIR/installed-update" dev
    # Add a main ref to the feed bare so the channel-driven mapping
    # has somewhere to land.
    git -C "$FEED_BARE" branch main dev

    mkdir -p "$ROOT_DIR/etc/airplanes"
    echo "stable" > "$ROOT_DIR/etc/airplanes/release-channel"

    run_update "file://$FEED_BARE" success "" 0 0 \
        "$CASE_DIR/installed-update/update-airplanes.sh" \
        || fail "no-tags-channel-stable fallback path failed"

    # release-channel=stable + no tags → fallback pins
    # AIRPLANES_FEED_BRANCH=main regardless of the bridge's dev
    # checkout. (The bridge's auto-detected default would have been
    # dev; the channel beats it.)
    assert_success_state apt "main" "stable"
    echo "no-tags release-channel=stable (channel wins over bridge default) passed"
}

test_operator_stable_sentinel_bootstraps_correctly() {
    setup_case operator-stable-sentinel
    UPDATE_BRANCH="main"
    FEED_BRANCH="main"
    prepare_common_fixture
    make_installed_update_checkout "$CASE_DIR/installed-update" main
    # Tag the feed bare so feed/update.sh has something to resolve.
    git -C "$FEED_BARE" tag v0.1.0 "$(git -C "$FEED_BARE" rev-parse main)"

    # Operator passes AIRPLANES_FEED_BRANCH=stable expecting feed's
    # release-channel sentinel. The bridge must NOT try to clone feed
    # at a branch literally named "stable" (no such branch exists) —
    # it has to bootstrap from DEFAULT_BRANCH (main here) and still
    # pass the sentinel through to feed/update.sh.
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
        AIRPLANES_FEED_BRANCH="stable" \
        AIRPLANES_TEST_FEED_UPDATE_MODE=success \
        AIRPLANES_TEST_IS_CHROOT=0 \
        AIRPLANES_PACKAGE_MANAGER=apt \
        bash "$CASE_DIR/installed-update/update-airplanes.sh" \
        || fail "operator-stable-sentinel path failed"

    # The bridge cloned feed from main (DEFAULT_BRANCH on a main
    # checkout) and passed AIRPLANES_FEED_BRANCH=stable through to
    # feed unchanged.
    assert_contains "$FEED_UPDATE_LOG" '^branch=stable$'
    echo "operator AIRPLANES_FEED_BRANCH=stable sentinel passed"
}

test_no_tags_with_release_channel_stable_falls_back_to_main() {
    setup_case no-tags-channel-stable
    UPDATE_BRANCH="dev"
    FEED_BRANCH="dev"
    prepare_common_fixture
    make_installed_update_checkout "$CASE_DIR/installed-update" dev
    git -C "$FEED_BARE" branch main dev
    mkdir -p "$ROOT_DIR/etc/airplanes"
    echo "stable" > "$ROOT_DIR/etc/airplanes/release-channel"

    run_update "file://$FEED_BARE" success "" 0 0 \
        "$CASE_DIR/installed-update/update-airplanes.sh" \
        || fail "no-tags-channel-stable fallback path failed"

    # Bridge auto-detected dev from its installed-update checkout; the
    # channel pin (stable) wins in the fallback selection so the stub
    # feed/update.sh logs branch=main.
    assert_success_state apt "main" "stable"
    echo "no-tags release-channel=stable (channel wins over bridge default) passed"
}

test_operator_stable_sentinel_bootstraps_correctly() {
    setup_case operator-stable-sentinel
    UPDATE_BRANCH="main"
    FEED_BRANCH="main"
    prepare_common_fixture
    make_installed_update_checkout "$CASE_DIR/installed-update" main
    git -C "$FEED_BARE" tag v0.1.0 "$(git -C "$FEED_BARE" rev-parse main)"

    # Operator passes AIRPLANES_FEED_BRANCH=stable expecting feed's
    # release-channel sentinel. The bridge must NOT try to clone feed
    # at a branch literally named "stable" (no such branch exists) -
    # it has to bootstrap from DEFAULT_BRANCH (main here) and still
    # pass the sentinel through to feed/update.sh.
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
        AIRPLANES_FEED_BRANCH="stable" \
        AIRPLANES_TEST_FEED_UPDATE_MODE=success \
        AIRPLANES_TEST_IS_CHROOT=0 \
        AIRPLANES_PACKAGE_MANAGER=apt \
        bash "$CASE_DIR/installed-update/update-airplanes.sh" \
        || fail "operator-stable-sentinel path failed"

    assert_contains "$FEED_UPDATE_LOG" '^branch=stable$'
    echo "operator AIRPLANES_FEED_BRANCH=stable sentinel passed"
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
    # Release-channel seed must NOT run in chroot — image-build flows
    # have their own logic for that file (image stage 06 writes it from
    # the channel config) and a chroot bridge run shouldn't second-guess.
    [[ ! -e "$ROOT_DIR/etc/airplanes/release-channel" ]] \
        || fail "release-channel was seeded in chroot: $(cat "$ROOT_DIR/etc/airplanes/release-channel")"
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
    test_dev_checkout_defaults_to_dev_branches
    test_raw_script_defaults_to_main_branches
    test_release_channel_already_present_is_preserved
    test_release_channel_empty_file_is_self_healed
    test_release_channel_invalid_content_is_preserved
    test_release_channel_whitespace_only_is_self_healed
    test_operator_feed_branch_override_passes_through
    test_tag_present_uses_deferred_resolution
    test_no_tags_with_release_channel_dev_falls_back_to_dev
    test_no_tags_with_release_channel_stable_falls_back_to_main
    test_operator_stable_sentinel_bootstraps_correctly
    test_bad_feed_repo_fails_before_tar1090
    test_feed_update_failure_propagates
    test_chroot_skips_feed_update

    echo "update-airplanes rootfs smoke passed"
}

main "$@"
