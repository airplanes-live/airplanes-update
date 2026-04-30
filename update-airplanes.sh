#!/bin/bash
set -e
trap 'echo "[ERROR] Error in line $LINENO when executing: $BASH_COMMAND"' ERR

AIRPLANES_ROOT="${AIRPLANES_ROOT:-/}"
UPDATE_REPO="${AIRPLANES_UPDATE_REPO:-https://github.com/airplanes-live/airplanes-update.git}"
UPDATE_BRANCH="${AIRPLANES_UPDATE_BRANCH:-main}"
READSB_REPO="${AIRPLANES_READSB_REPO:-https://github.com/airplanes-live/readsb.git}"
READSB_BRANCH="${AIRPLANES_READSB_BRANCH:-}"
FEED_REPO="${AIRPLANES_FEED_REPO:-https://github.com/airplanes-live/feed.git}"
FEED_BRANCH="${AIRPLANES_FEED_BRANCH:-main}"

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
