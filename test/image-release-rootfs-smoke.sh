#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
    exec sudo -E bash "$0" "$@"
fi

UPDATE_DIR="${AIRPLANES_UPDATE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
IMAGE_RELEASE_REPO="${AIRPLANES_IMAGE_RELEASE_REPO:-airplanes-live/image-releases}"
IMAGE_ASSET_REGEX="${AIRPLANES_IMAGE_ASSET_REGEX:-(?i)\\.(img|img\\.xz|img\\.gz|zip|7z)$}"
WORK_DIR="${AIRPLANES_RELEASE_ROOTFS_WORK_DIR:-}"
KEEP_WORK_DIR="${AIRPLANES_RELEASE_ROOTFS_KEEP_WORK_DIR:-0}"

if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="$(mktemp -d)"
else
    mkdir -p "$WORK_DIR"
    WORK_DIR="$(cd "$WORK_DIR" && pwd)"
fi

IMAGE_FILE="$WORK_DIR/airplanes-image.img"
ROOT_MNT="$WORK_DIR/rootfs"
BOOT_MNT="$ROOT_MNT/boot"
DOWNLOAD_DIR="$WORK_DIR/download"
UPDATE_BRANCH="release-rootfs-smoke"
READSB_BRANCH="release-rootfs-smoke"
FEED_BRANCH="release-rootfs-smoke"
UPDATE_SOURCE="$WORK_DIR/airplanes-update-source"
UPDATE_BARE="$WORK_DIR/airplanes-update.git"
READSB_SOURCE="$WORK_DIR/readsb-source"
READSB_BARE="$WORK_DIR/readsb.git"
FEED_SOURCE="$WORK_DIR/feed-source"
FEED_BARE="$WORK_DIR/feed.git"
STUB_DIR="$WORK_DIR/bin"
COMMAND_LOG="$WORK_DIR/commands.log"
FEED_UPDATE_LOG="$WORK_DIR/feed-update.log"
TAR1090_LOG="$WORK_DIR/tar1090.log"

cleanup() {
    set +e
    if mountpoint -q "$BOOT_MNT"; then
        umount "$BOOT_MNT"
    fi
    if mountpoint -q "$ROOT_MNT"; then
        umount "$ROOT_MNT"
    fi
    if [[ "$KEEP_WORK_DIR" != "1" ]]; then
        rm -rf "$WORK_DIR"
    else
        echo "Keeping release rootfs smoke work dir: $WORK_DIR"
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

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_commands() {
    local command
    for command in "$@"; do
        require_command "$command"
    done
}

github_api() {
    local url="$1"
    local -a headers
    headers=(-H "Accept: application/vnd.github+json")
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        headers+=(
            -H "Authorization: Bearer $GITHUB_TOKEN"
            -H "X-GitHub-Api-Version: 2022-11-28"
        )
    fi
    curl --fail --location --silent --show-error "${headers[@]}" "$url"
}

download_latest_release_image() {
    local release_json asset_name asset_url output
    mkdir -p "$DOWNLOAD_DIR"
    release_json="$DOWNLOAD_DIR/latest-release.json"

    echo "Fetching latest image release from $IMAGE_RELEASE_REPO" >&2
    github_api "https://api.github.com/repos/$IMAGE_RELEASE_REPO/releases/latest" > "$release_json"

    asset_name="$(jq -r --arg re "$IMAGE_ASSET_REGEX" '
        [.assets[] | select(.name | test($re))] as $matches
        | (($matches | map(select(.name | test("qemu"; "i"))) | first) // ($matches | first) // empty)
        | .name // empty
    ' "$release_json")"
    asset_url="$(jq -r --arg name "$asset_name" '
        .assets[] | select(.name == $name) | .browser_download_url
    ' "$release_json")"

    [[ -n "$asset_name" && -n "$asset_url" ]] || {
        jq -r '.assets[].name' "$release_json" >&2
        fail "no release asset in $IMAGE_RELEASE_REPO matched $IMAGE_ASSET_REGEX"
    }

    output="$DOWNLOAD_DIR/$asset_name"
    echo "Downloading image asset: $asset_name" >&2
    curl --fail --location --show-error --output "$output" "$asset_url"
    printf '%s\n' "$output"
}

find_single_image() {
    local dir="$1"
    local image
    image="$(find "$dir" -type f -name '*.img' -print | sort | head -n 1)"
    [[ -n "$image" ]] || fail "no .img file found in $dir"
    printf '%s\n' "$image"
}

extract_image() {
    local archive="$1"
    local extract_dir="$WORK_DIR/extracted"
    local image
    mkdir -p "$extract_dir"

    case "$archive" in
        *.img)
            cp --reflink=auto "$archive" "$IMAGE_FILE" 2>/dev/null || cp "$archive" "$IMAGE_FILE"
            ;;
        *.img.xz|*.xz)
            xz -dc "$archive" > "$IMAGE_FILE"
            ;;
        *.img.gz|*.gz)
            gzip -dc "$archive" > "$IMAGE_FILE"
            ;;
        *.zip)
            unzip -q "$archive" -d "$extract_dir"
            image="$(find_single_image "$extract_dir")"
            cp --reflink=auto "$image" "$IMAGE_FILE" 2>/dev/null || cp "$image" "$IMAGE_FILE"
            ;;
        *.7z)
            7z x "-o$extract_dir" "$archive"
            image="$(find_single_image "$extract_dir")"
            cp --reflink=auto "$image" "$IMAGE_FILE" 2>/dev/null || cp "$image" "$IMAGE_FILE"
            ;;
        *)
            fail "unsupported image archive: $archive"
            ;;
    esac

    [[ -s "$IMAGE_FILE" ]] || fail "extracted image is empty: $IMAGE_FILE"
    echo "Prepared image: $IMAGE_FILE"
    ls -lh "$IMAGE_FILE"
}

partition_values() {
    local part="$1"
    parted -ms "$IMAGE_FILE" unit B print \
        | awk -F: -v part="$part" '$1 == part { gsub(/B/, "", $2); gsub(/B/, "", $4); print $2, $4 }'
}

mount_partitions() {
    local boot_start boot_size root_start root_size configured_boot
    mkdir -p "$ROOT_MNT"
    read -r boot_start boot_size < <(partition_values 1)
    read -r root_start root_size < <(partition_values 2)
    [[ -n "${boot_start:-}" && -n "${root_start:-}" ]] || fail "could not read image partition table"

    mount -o "loop,offset=$root_start,sizelimit=$root_size,rw" "$IMAGE_FILE" "$ROOT_MNT"

    configured_boot="$(awk '$2 == "/boot" || $2 == "/boot/firmware" { print $2; exit }' "$ROOT_MNT/etc/fstab" 2>/dev/null || true)"
    if [[ -n "$configured_boot" ]]; then
        BOOT_MNT="$ROOT_MNT$configured_boot"
        mkdir -p "$BOOT_MNT"
        mount -o "loop,offset=$boot_start,sizelimit=$boot_size,rw" "$IMAGE_FILE" "$BOOT_MNT"
        echo "Mounted image boot partition at $configured_boot"
    else
        BOOT_MNT="$ROOT_MNT/boot"
        echo "Image fstab does not mount a boot partition; using rootfs /boot"
    fi
}

make_repo() {
    local source="$1"
    local branch="$2"
    local bare="$3"

    git -C "$source" init -q -b "$branch"
    git -C "$source" config user.email "release-rootfs-smoke@example.invalid"
    git -C "$source" config user.name "Release Rootfs Smoke"
    git -C "$source" add .
    git -C "$source" commit -q -m "release rootfs smoke fixture"
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
printf '%s\n' '22222222-3333-4444-5555-666666666666' > "$AIRPLANES_ROOT/boot/airplanes-uuid"
printf '%s\n' 'feed update ran' > "$AIRPLANES_ROOT/usr/local/share/airplanes/feed-update-marker"
SH
    chmod +x "$FEED_SOURCE/update.sh"
    make_repo "$FEED_SOURCE" "$FEED_BRANCH" "$FEED_BARE"
}

set_env_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    if grep -q "^${key}=" "$file"; then
        sed -i -e "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

prepare_mounted_image() {
    [[ -f "$ROOT_MNT/boot/airplanes-config.txt" ]] || {
        echo "--- /boot contents ---" >&2
        find "$ROOT_MNT/boot" -maxdepth 2 -mindepth 1 -printf '%P\n' | sort | head -n 80 >&2 || true
        fail "release image lacks /boot/airplanes-config.txt"
    }
    [[ -f "$ROOT_MNT/boot/airplanes-env" ]] || fail "release image lacks /boot/airplanes-env"
    mkdir -p "$ROOT_MNT/tmp" "$ROOT_MNT/var/log" "$ROOT_MNT/etc/systemd/system/dhcpcd.service.d"
    printf '%s\n' 'remove me' > "$ROOT_MNT/etc/systemd/system/dhcpcd.service.d/wait.conf"

    set_env_value "$ROOT_MNT/boot/airplanes-config.txt" USER "release-rootfs-smoke"
    set_env_value "$ROOT_MNT/boot/airplanes-config.txt" DUMP1090 "no"
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

run_update() {
    PATH="$STUB_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    COMMAND_LOG="$COMMAND_LOG" \
    FEED_UPDATE_LOG="$FEED_UPDATE_LOG" \
    TAR1090_LOG="$TAR1090_LOG" \
    AIRPLANES_ROOT="$ROOT_MNT" \
    AIRPLANES_UPDATE_REPO="file://$UPDATE_BARE" \
    AIRPLANES_UPDATE_BRANCH="$UPDATE_BRANCH" \
    AIRPLANES_READSB_REPO="file://$READSB_BARE" \
    AIRPLANES_READSB_BRANCH="$READSB_BRANCH" \
    AIRPLANES_FEED_REPO="file://$FEED_BARE" \
    AIRPLANES_FEED_BRANCH="$FEED_BRANCH" \
        bash "$UPDATE_DIR/update-airplanes.sh"
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    grep -q -- "$pattern" "$file" || fail "$file does not contain $pattern"
}

assert_updated_image() {
    [[ -f "$ROOT_MNT/boot/airplanes-config.txt" ]] || fail "missing boot config"
    [[ -f "$ROOT_MNT/boot/airplanes-env" ]] || fail "missing boot env"
    [[ -f "$ROOT_MNT/boot/airplanes-uuid" ]] || fail "missing boot UUID"
    [[ -f "$ROOT_MNT/boot/airplanes-version-decoder" ]] || fail "missing decoder version"
    [[ -x "$ROOT_MNT/usr/bin/airplanes-feeder" ]] || fail "missing airplanes-feeder"
    [[ -x "$ROOT_MNT/usr/bin/airplanes-978" ]] || fail "missing airplanes-978"
    [[ -x "$ROOT_MNT/usr/bin/readsb" ]] || fail "missing readsb"
    [[ -x "$ROOT_MNT/usr/bin/viewadsb" ]] || fail "missing viewadsb"
    [[ -f "$ROOT_MNT/etc/systemd/system/airplanes-first-run.service" ]] || fail "missing first-run service"
    [[ -f "$ROOT_MNT/etc/systemd/system/readsb.service" ]] || fail "missing readsb service"
    [[ -f "$ROOT_MNT/etc/systemd/system/airplanes-feed.service" ]] || fail "missing airplanes-feed service"
    [[ -f "$ROOT_MNT/usr/local/share/airplanes/feed-update-marker" ]] || fail "feed update marker missing"
    [[ ! -e "$ROOT_MNT/etc/systemd/system/dhcpcd.service.d/wait.conf" ]] || fail "wait.conf was not removed"
    [[ ! -e "$ROOT_MNT/tmp/update-airplanes" ]] || fail "temporary updater directory was not removed"

    assert_contains "$ROOT_MNT/boot/airplanes-config.txt" '^USER="release-rootfs-smoke"$'
    assert_contains "$ROOT_MNT/boot/airplanes-config.txt" '^MLAT_USER="release-rootfs-smoke"$'
    assert_contains "$ROOT_MNT/boot/airplanes-config.txt" '^MLAT_ENABLED=true$'
    assert_contains "$ROOT_MNT/boot/airplanes-config.txt" '^DUMP1090=no$'
    assert_contains "$ROOT_MNT/boot/airplanes-config.txt" '^LATITUDE='
    assert_contains "$ROOT_MNT/boot/airplanes-config.txt" '^GRAPHS1090=yes$'
    [[ "$(cat "$ROOT_MNT/boot/airplanes-uuid")" == "22222222-3333-4444-5555-666666666666" ]] \
        || fail "feed update did not create expected UUID"

    assert_contains "$FEED_UPDATE_LOG" "root=$ROOT_MNT"
    assert_contains "$FEED_UPDATE_LOG" "repo=file://$FEED_BARE"
    assert_contains "$FEED_UPDATE_LOG" "branch=$FEED_BRANCH"
    assert_contains "$FEED_UPDATE_LOG" '^package_manager=apt$'
    assert_contains "$TAR1090_LOG" '^tar1090 install$'
    assert_contains "$COMMAND_LOG" '^apt-get install '
    assert_contains "$COMMAND_LOG" '^systemctl daemon-reload$'
    assert_contains "$COMMAND_LOG" '^systemctl enable airplanes-first-run.service readsb.service airplanes-mlat.service airplanes-feed.service pingfail.service$'
    assert_contains "$COMMAND_LOG" '^systemctl mask autogain1090.timer$'
    assert_contains "$COMMAND_LOG" '^systemctl restart readsb$'
    assert_contains "$COMMAND_LOG" '^systemctl restart airplanes-feed$'
    assert_contains "$COMMAND_LOG" '^systemctl restart airplanes-978$'
}

main() {
    local image_archive
    require_commands curl jq git parted awk mount umount find cp tee unzip xz gzip make

    if [[ -n "${AIRPLANES_IMAGE_PATH:-}" ]]; then
        image_archive="$AIRPLANES_IMAGE_PATH"
        [[ -f "$image_archive" ]] || fail "AIRPLANES_IMAGE_PATH does not exist: $image_archive"
    else
        image_archive="$(download_latest_release_image)"
    fi

    echo "Work dir: $WORK_DIR"
    df -h .
    extract_image "$image_archive"
    mount_partitions
    make_update_repo
    make_readsb_repo
    make_feed_repo
    prepare_mounted_image
    write_stubs
    run_update
    assert_updated_image

    echo "image release rootfs smoke passed"
}

main "$@"
