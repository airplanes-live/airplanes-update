#!/bin/bash
set -e
trap 'echo "[ERROR] Error in line $LINENO when executing: $BASH_COMMAND"' ERR

AIRPLANES_ROOT="${AIRPLANES_ROOT:-/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"

airplanes_default_branch() {
    local branch
    if command -v git &>/dev/null && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        branch="$(git -C "$SCRIPT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
        if [[ "$branch" == "dev" ]]; then
            printf '%s\n' "dev"
            return 0
        fi
    fi
    printf '%s\n' "main"
}

DEFAULT_BRANCH="$(airplanes_default_branch)"
UPDATE_REPO="${AIRPLANES_UPDATE_REPO:-https://github.com/airplanes-live/airplanes-update.git}"
UPDATE_BRANCH="${AIRPLANES_UPDATE_BRANCH:-$DEFAULT_BRANCH}"
READSB_REPO="${AIRPLANES_READSB_REPO:-https://github.com/airplanes-live/readsb.git}"
READSB_BRANCH="${AIRPLANES_READSB_BRANCH:-}"
FEED_REPO="${AIRPLANES_FEED_REPO:-https://github.com/airplanes-live/feed.git}"
# FEED_BRANCH is the bootstrap clone ref for the bridge's own copy of
# feed/ (just enough to get feed/update.sh on disk). It is NOT what
# ends up installed — feed/update.sh self-replaces and re-execs from
# the resolved tag (or the AIRPLANES_FEED_BRANCH override) once it is
# running. Two operator-facing edge cases:
#   - AIRPLANES_FEED_BRANCH=stable is feed's sentinel for "resolve via
#     release-channel"; no real branch is named that. Fall through to
#     DEFAULT_BRANCH for the bootstrap clone, then still pass the
#     sentinel to feed via AIRPLANES_FEED_BRANCH below.
#   - empty / unset: auto-detect from the bridge's own checkout
#     (main / dev).
FEED_BRANCH="${AIRPLANES_FEED_BRANCH:-$DEFAULT_BRANCH}"
if [[ "$FEED_BRANCH" == "stable" ]]; then
    FEED_BRANCH="$DEFAULT_BRANCH"
fi

airplanes_path() {
    local path="$1"
    if [[ "$AIRPLANES_ROOT" == "/" ]]; then
        printf '%s\n' "$path"
    else
        printf '%s\n' "${AIRPLANES_ROOT%/}$path"
    fi
}

if [[ "$(id -u)" != "0" ]]; then
    exec sudo -E bash -- "${BASH_SOURCE[0]}"
fi

# let's do all of this in a clean directory:
updir="$(airplanes_path /tmp/update-airplanes)"

cleanup() {
    rm -rf "$updir"
}
trap cleanup EXIT

rm -rf "$updir"
mkdir -p "$updir"
cd "$updir"

# in case /var/log is full ... delete some logs
mkdir -p "$(airplanes_path /var/log)"
echo test > "$(airplanes_path /var/log/.test)" 2>/dev/null || rm -f "$(airplanes_path /var/log)"/*.log

restartIfEnabled() {
    # check if enabled
    if systemctl is-enabled "$1" &>/dev/null; then
            systemctl restart "$1"
    fi
}

function aptInstall() {
    if ! apt-get install -y --no-install-recommends --no-install-suggests "$@"; then
        apt-get update || true
        apt-get install -y --no-install-recommends --no-install-suggests "$@"
    fi
}

packages="git wget make gcc libusb-1.0-0 libusb-1.0-0-dev librtlsdr0 librtlsdr-dev ncurses-bin ncurses-dev zlib1g zlib1g-dev python3-dev python3-venv libzstd-dev libzstd1"
aptInstall $packages

git clone --quiet --depth 1 --single-branch --branch "$UPDATE_BRANCH" "$UPDATE_REPO" airplanes-update
cd airplanes-update

while IFS= read -r -d '' dir; do
    mkdir -p "$(airplanes_path "/$dir")"
done < <(find skeleton -mindepth 1 -type d -printf '%P\0')

while IFS= read -r -d '' file; do
    mkdir -p "$(dirname "$(airplanes_path "/$file")")"
    cp -T --remove-destination -v "skeleton/$file" "$(airplanes_path "/$file")" >/dev/null
done < <(find skeleton -type f -printf '%P\0')

# make sure the config has all the options, if not add them with default value:
while IFS= read -r line; do
    key="${line%%=*}"
    if ! grep -qs "^${key}=" "$(airplanes_path /boot/airplanes-config.txt)"; then
        echo "$line" >> "$(airplanes_path /boot/airplanes-config.txt)"
    fi
done < <(grep -v -e '^#' -e '^$' boot-configs/airplanes-config.txt)

# Translate the legacy USER= key into the split MLAT_USER + MLAT_ENABLED
# schema expected by the new feed daemons. Idempotent (byte-compares before
# rewriting); safe to run on every update. Must run BEFORE delegating to
# feed/update.sh so the new wrappers see a migrated config.
migrator="$(airplanes_path /usr/local/lib/airplanes-update/migrate-config.sh)"
config_file="$(airplanes_path /boot/airplanes-config.txt)"
# Use -r (readable), not -x: we invoke via `bash "$migrator"`, which only
# needs the file to be readable. An install path that drops the exec bit
# (cp without -p, archive extraction with neutral mode) would otherwise
# silently skip the migration and surface as a confusing "Run Update
# Webconfig" error from feed's strict guard on the next daemon start.
if [[ -r "$migrator" && -f "$config_file" ]]; then
    bash "$migrator" "$config_file"
fi
unset migrator config_file

# Persist /etc/airplanes/release-channel=stable on legacy-bridge boxes
# that don't yet have one. feed/update.sh treats the file's `stable`
# value as a sentinel that resolves to the latest semver tag at runtime
# via git ls-remote --tags. feed's update.sh also defaults to the stable
# channel when both AIRPLANES_FEED_BRANCH and the file are absent, so
# this isn't strictly required for first-run resolution — it's the
# persistent channel signal that survives across runs and is visible to
# anyone inspecting the box. Operator-pinned values (e.g. `dev` on a
# test feeder) are preserved; an empty file from a previous interrupted
# write is self-healed.
#
# Skip in chroot: image-build flows have their own release-channel
# logic (image stage 06 writes it from the config-{dev,stable} channel),
# and a chroot run of this bridge shouldn't second-guess that.
if ! ischroot; then
    release_channel_file="$(airplanes_path /etc/airplanes/release-channel)"
    release_channel_existing=""
    release_channel_raw=""
    if [[ -r "$release_channel_file" ]]; then
        release_channel_raw="$(head -n1 "$release_channel_file" 2>/dev/null || true)"
        release_channel_existing="$(printf '%s' "$release_channel_raw" | tr -d '[:space:]')"
    fi
    case "$release_channel_existing" in
        stable|main|dev)
            # Valid value present — leave it alone (operator pin, or
            # previous seed).
            ;;
        '')
            # File missing, empty, or whitespace-only (e.g. from a
            # previous interrupted write). Self-heal to stable via temp
            # + rename so feed/update.sh's strict allowlist accepts it.
            mkdir -p "$(dirname "$release_channel_file")"
            release_channel_tmp="$(mktemp "${release_channel_file}.XXXXXX")"
            chmod 0644 "$release_channel_tmp"
            printf 'stable\n' > "$release_channel_tmp"
            mv -f "$release_channel_tmp" "$release_channel_file"
            release_channel_existing="stable"
            unset release_channel_tmp
            ;;
        *)
            # Non-empty content that doesn't match the allowlist — e.g.
            # an operator hand-edit typo like `deev`. Leave the file
            # alone: silently rewriting to stable would mask the typo,
            # whereas feed/update.sh's release-channel check refuses
            # the value loudly with a clear "expected one of: stable,
            # dev, main" error. Surfacing the operator's mistake beats
            # second-guessing it.
            echo "warning: $release_channel_file contains '$release_channel_raw' which is not in the {stable, main, dev} allowlist; feed/update.sh will refuse this on the next run." >&2
            ;;
    esac
    unset release_channel_file release_channel_raw
fi

# remove strange dhcpcd wait.conf in case it's there
rm -f "$(airplanes_path /etc/systemd/system/dhcpcd.service.d/wait.conf)"


systemctl daemon-reload

# enable services
systemctl enable \
    airplanes-first-run.service \
    readsb.service \
    airplanes-mlat.service \
    airplanes-feed.service \
    pingfail.service

# mask services we don't need on this image
# disable autogain script and timer readsb gain=auto current
MASK="dump1090-fa dump1090 dump1090-mutability dump978-rb dump1090-rb autogain1090.service autogain1090.timer"
for service in $MASK; do
    systemctl disable $service || true
    systemctl stop $service || true
    systemctl mask $service || true
done &>/dev/null

cd "$updir"
readsb_clone_args=(--quiet --depth 1)
if [[ -n "$READSB_BRANCH" ]]; then
    readsb_clone_args+=(--single-branch --branch "$READSB_BRANCH")
fi
git clone "${readsb_clone_args[@]}" "$READSB_REPO" readsb

echo 'compiling readsb (this can take a while) .......'

cd readsb

if dpkg --print-architecture | grep -qs armhf; then
    make -j3 AIRCRAFT_HASH_BITS=12 RTLSDR=yes OPTIMIZE="-O2 -mcpu=arm1176jzf-s -mfpu=vfp"
else
    make -j3 AIRCRAFT_HASH_BITS=12 RTLSDR=yes OPTIMIZE="-O3"
fi

echo 'copying new readsb binaries ......'
cp -f readsb "$(airplanes_path /usr/bin/airplanes-feeder)"
cp -f readsb "$(airplanes_path /usr/bin/airplanes-978)"
cp -f readsb "$(airplanes_path /usr/bin/readsb)"
cp -f viewadsb "$(airplanes_path /usr/bin/viewadsb)"


echo 'make sure unprivileged users exist (readsb / airplanes) ......'
for USER in airplanes readsb; do
    if ! id -u "${USER}" &>/dev/null
    then
        adduser --system --home "$(airplanes_path "/usr/local/share/$USER")" --no-create-home --quiet "$USER"
    fi
done

# plugdev required for bladeRF USB access
adduser readsb plugdev
# dialout required for Mode-S Beast and GNS5894 ttyAMA0 access
adduser readsb dialout

mkdir -p "$(airplanes_path /var/globe_history)"
chown readsb "$(airplanes_path /var/globe_history)"

echo 'restarting services .......'
restartIfEnabled readsb
restartIfEnabled airplanes-feed
restartIfEnabled airplanes-978

cd "$updir"
rm -rf "$updir/readsb"

if ischroot; then
    echo 'skipping airplanes.live feed update in chroot'
else
    echo 'updating airplanes.live feed components .......'
    git clone --quiet --depth 1 --single-branch --branch "$FEED_BRANCH" "$FEED_REPO" feed
    # The bridge's own clone of feed/ has to pin a ref to bootstrap
    # update.sh (above). Inside that update.sh, if the operator has not
    # explicitly set AIRPLANES_FEED_BRANCH, defer to feed's release-
    # channel resolution — it self-replaces + re-execs from the resolved
    # tag, so the end state is the tagged release even though we cloned
    # main. An explicit operator AIRPLANES_FEED_BRANCH still wins (used
    # for testing / recovery / pinning).
    feed_env_args=(
        "AIRPLANES_ROOT=$AIRPLANES_ROOT"
        "AIRPLANES_FEED_REPO=$FEED_REPO"
        "AIRPLANES_PACKAGE_MANAGER=${AIRPLANES_PACKAGE_MANAGER:-apt}"
    )
    if [[ -n "${AIRPLANES_FEED_BRANCH:-}" ]]; then
        feed_env_args+=("AIRPLANES_FEED_BRANCH=$AIRPLANES_FEED_BRANCH")
    else
        # No-tags-yet fallback. feed/update.sh on the stable channel
        # aborts with "no v[MAJOR].[MINOR].[PATCH] tags exist" when the
        # remote has no semver tags. Until v0.1.0 is cut on
        # airplanes-live/feed, that's the production state — so a real
        # bridge run today on the deferred-resolution path would refuse
        # to update. Preflight: query the feed remote for tags. Three
        # outcomes:
        #   - query succeeds + has semver tag → defer to feed
        #   - query succeeds + no semver tag → fall back to a concrete
        #     branch chosen by the (validated) release-channel:
        #       dev                          → dev
        #       stable / main / empty / unset → main
        #     The channel is the operator's intent; the bridge's own
        #     auto-detected checkout branch is incidental and must not
        #     leak through to the installed feed. (A dev-checkout bridge
        #     run on a stable-channel feeder still pins feed to main.)
        #   - query fails (network/DNS/TLS) → don't fall back; let feed/
        #     update.sh surface its own structured network error rather
        #     than mask the failure by silently pinning a branch.
        # The fallback becomes a no-op once v0.1.0 exists upstream.
        feed_tag_refs=""
        if feed_tag_refs="$(git ls-remote --tags --refs "$FEED_REPO" 2>/dev/null)"; then
            if ! grep -Eq 'refs/tags/v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' <<<"$feed_tag_refs"; then
                fallback_branch=""
                case "${release_channel_existing:-stable}" in
                    dev)              fallback_branch="dev" ;;
                    stable|main|"")   fallback_branch="main" ;;
                esac
                if [[ -n "$fallback_branch" ]]; then
                    echo "no semver tags on $FEED_REPO yet; pinning AIRPLANES_FEED_BRANCH=$fallback_branch (channel=${release_channel_existing:-stable}) as a transitional measure" >&2
                    feed_env_args+=("AIRPLANES_FEED_BRANCH=$fallback_branch")
                fi
                unset fallback_branch
            fi
        else
            echo "warning: could not query $FEED_REPO for tags; deferring to feed/update.sh's network-error handling" >&2
        fi
        unset feed_tag_refs
    fi
    # Other exported AIRPLANES_* overrides (MLAT/readsb repos etc.) are
    # inherited by bash through the env.
    env "${feed_env_args[@]}" bash "$updir/feed/update.sh"
    unset feed_env_args

    rm -f -R "$updir/feed"
fi

echo 'update tar1090 ...........'
bash -c "$(wget -nv -O - https://raw.githubusercontent.com/airplanes-live/tar1090/master/install.sh)"

if [[ -f "$(airplanes_path /boot/airplanes-config.txt)" ]]; then
    if ! grep -qs -e 'GRAPHS1090' "$(airplanes_path /boot/airplanes-config.txt)"; then
        echo "GRAPHS1090=yes" >> "$(airplanes_path /boot/airplanes-config.txt)"
    fi
fi


# the following doesn't apply for chroot (image creation)
if ischroot; then
    exit 0
fi

echo "#####################################"
cat "$(airplanes_path /boot/airplanes-uuid)"
echo "#####################################"
echo "#####################################"

echo "8.3.$(date '+%y%m%d')" > "$(airplanes_path /boot/airplanes-version-decoder)"

echo '--------------------------------------------'
echo '--------------------------------------------'
echo '             UPDATE COMPLETE'
echo '--------------------------------------------'
echo '--------------------------------------------'
