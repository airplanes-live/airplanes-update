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

# Resolve the latest semver-strict release tag from the feed remote.
# Strict format: vMAJOR.MINOR.PATCH with no leading zeroes, no prereleases.
# Mirrors the resolver in airplanes-live/feed's scripts/lib/install-update-common.sh
# so the bridge picks the same tag the feeders themselves would resolve.
# Echoes the tag name on success.
# Returns 0 = found, 1 = lookup OK but no matching tags, 2 = lookup itself failed.
airplanes_resolve_latest_feed_tag() {
    local repo="${1:-$FEED_REPO}"
    local refs latest=""
    if ! refs="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs "$repo" 2>/dev/null)"; then
        return 2
    fi
    if [[ -z "$refs" ]]; then
        return 1
    fi
    local _sha _refname _tag
    while IFS=$'\t' read -r _sha _refname; do
        _tag="${_refname#refs/tags/}"
        if [[ "$_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
            if [[ -z "$latest" ]]; then
                latest="$_tag"
            else
                latest="$(printf '%s\n%s\n' "$latest" "$_tag" | sort -V | tail -n 1)"
            fi
        fi
    done <<< "$refs"
    if [[ -z "$latest" ]]; then
        return 1
    fi
    printf '%s' "$latest"
    return 0
}

# FEED_BRANCH: legacy-bridge delivery channel for feeders updating through
# this script. Explicit AIRPLANES_FEED_BRANCH env var always wins (used by
# test fixtures and operator overrides). Otherwise the bridge resolves the
# latest stable feed tag — by design the bridge is stable-only; there is no
# airplanes-update/dev user fleet that needs dev-channel pre-release code.
# Fail closed if no matching tags exist or the lookup itself fails: don't
# silently fall back to a branch HEAD, which would defeat the entire reason
# we tag releases (controlled-rollout to the legacy fleet).
if [[ -n "${AIRPLANES_FEED_BRANCH:-}" ]]; then
    FEED_BRANCH="$AIRPLANES_FEED_BRANCH"
else
    _resolved_tag=""
    _resolve_rc=0
    _resolved_tag="$(airplanes_resolve_latest_feed_tag "$FEED_REPO")" || _resolve_rc=$?
    case $_resolve_rc in
        0) FEED_BRANCH="$_resolved_tag" ;;
        1)
            echo "ERROR: airplanes.live feed has no v[MAJOR].[MINOR].[PATCH] release tags at $FEED_REPO." >&2
            echo "       The bridge installs only stable feed releases; aborting before touching the legacy stack." >&2
            exit 1
            ;;
        2)
            echo "ERROR: could not query release tags from $FEED_REPO (network/DNS/TLS failure)." >&2
            echo "       Aborting before touching the legacy stack." >&2
            exit 1
            ;;
    esac
    unset _resolved_tag _resolve_rc
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
    # Other exported AIRPLANES_* overrides, such as MLAT/readsb repos, are inherited by bash.
    AIRPLANES_ROOT="$AIRPLANES_ROOT" \
    AIRPLANES_FEED_REPO="$FEED_REPO" \
    AIRPLANES_FEED_BRANCH="$FEED_BRANCH" \
    AIRPLANES_PACKAGE_MANAGER="${AIRPLANES_PACKAGE_MANAGER:-apt}" \
        bash "$updir/feed/update.sh"

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

echo "8.2.$(date '+%y%m%d')" > "$(airplanes_path /boot/airplanes-version-decoder)"

echo '--------------------------------------------'
echo '--------------------------------------------'
echo '             UPDATE COMPLETE'
echo '--------------------------------------------'
echo '--------------------------------------------'
