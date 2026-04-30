#!/bin/bash
set -e
trap 'echo "[ERROR] Error in line $LINENO when executing: $BASH_COMMAND"' ERR

if [[ "$(id -u)" != "0" ]]; then
    exec sudo bash "${BASH_SOURCE[0]}"
fi

# let's do all of this in a clean directory:
updir=/tmp/update-airplanes

rm -rf $updir
mkdir -p $updir
cd $updir

# in case /var/log is full ... delete some logs
echo test > /var/log/.test 2>/dev/null || rm -f /var/log/*.log

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

FEED_REPO="${AIRPLANES_FEED_REPO:-https://github.com/airplanes-live/feed.git}"
FEED_BRANCH="${AIRPLANES_FEED_BRANCH:-main}"

git clone --quiet --depth 1 https://github.com/airplanes-live/airplanes-update.git
cd airplanes-update

find skeleton -type d | cut -d / -f1 --complement | grep -v '^skeleton' | xargs -t -I '{}' -s 2048 mkdir -p /'{}' &>/dev/null
find skeleton -type f | cut -d / -f1 --complement | xargs -I '{}' -s 2048 cp -T --remove-destination -v skeleton/'{}' /'{}' >/dev/null

# make sure the config has all the options, if not add them with default value:
for line in $(grep -v -e '^#' -e '^$' boot-configs/airplanes-config.txt); do
    if ! grep -qs "$(echo $line | cut -d= -f1)" /boot/airplanes-config.txt; then
        echo $line >> /boot/airplanes-config.txt
    fi
done

# remove strange dhcpcd wait.conf in case it's there
rm -f /etc/systemd/system/dhcpcd.service.d/wait.conf


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

cd $updir
git clone --quiet --depth 1 https://github.com/airplanes-live/readsb.git

echo 'compiling readsb (this can take a while) .......'

cd readsb

if dpkg --print-architecture | grep -qs armhf; then
    make -j3 AIRCRAFT_HASH_BITS=12 RTLSDR=yes OPTIMIZE="-O2 -mcpu=arm1176jzf-s -mfpu=vfp"
else
    make -j3 AIRCRAFT_HASH_BITS=12 RTLSDR=yes OPTIMIZE="-O3"
fi

echo 'copying new readsb binaries ......'
cp -f readsb /usr/bin/airplanes-feeder
cp -f readsb /usr/bin/airplanes-978
cp -f readsb /usr/bin/readsb
cp -f viewadsb /usr/bin/viewadsb


echo 'make sure unprivileged users exist (readsb / airplanes) ......'
for USER in airplanes readsb; do
    if ! id -u "${USER}" &>/dev/null
    then
        adduser --system --home "/usr/local/share/$USER" --no-create-home --quiet "$USER"
    fi
done

# plugdev required for bladeRF USB access
adduser readsb plugdev
# dialout required for Mode-S Beast and GNS5894 ttyAMA0 access
adduser readsb dialout

mkdir -p /var/globe_history
chown readsb /var/globe_history

echo 'restarting services .......'
restartIfEnabled readsb
restartIfEnabled airplanes-978

cd $updir
rm -rf $updir/readsb

echo 'updating airplanes.live feed components .......'
cd $updir
git clone --quiet --depth 1 --single-branch --branch "$FEED_BRANCH" "$FEED_REPO" feed
AIRPLANES_FEED_REPO="$FEED_REPO" \
AIRPLANES_FEED_BRANCH="$FEED_BRANCH" \
AIRPLANES_PACKAGE_MANAGER=apt \
    bash "$updir/feed/update.sh"

cd $updir
rm -f -R $updir/feed

cd $updir

echo 'update tar1090 ...........'
bash -c "$(wget -nv -O - https://raw.githubusercontent.com/airplanes-live/tar1090/master/install.sh)"

if [[ -f /boot/airplanes-config.txt ]]; then
    if ! grep -qs -e 'GRAPHS1090' /boot/airplanes-config.txt; then
        echo "GRAPHS1090=yes" >> /boot/airplanes-config.txt
    fi
fi


# the following doesn't apply for chroot (image creation)
if ischroot; then
    exit 0
fi

echo "#####################################"
cat /boot/airplanes-uuid
echo "#####################################"
echo "#####################################"

echo "8.2.$(date '+%y%m%d')" > /boot/airplanes-version-decoder

echo '--------------------------------------------'
echo '--------------------------------------------'
echo '             UPDATE COMPLETE'
echo '--------------------------------------------'
echo '--------------------------------------------'


cd /tmp
rm -rf $updir
