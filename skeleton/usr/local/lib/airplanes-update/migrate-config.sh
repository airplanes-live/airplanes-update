#!/usr/bin/env bash
# migrate-config.sh - Migrate legacy USER= schema in airplanes-config.txt
# to the split MLAT_USER + MLAT_ENABLED schema expected by the new feed
# daemons in airplanes-live/feed.
#
# Canonical home: airplanes-live/airplanes-webconfig:helpers/migrate-config.sh
# Vendored byte-equivalent copy: airplanes-live/airplanes-update:
#     skeleton/usr/local/lib/airplanes-update/migrate-config.sh
# Drift between the two is enforced by a CI test in airplanes-update.
#
# Usage:
#   migrate-config.sh <path>            apply migration in-place
#   migrate-config.sh --version         print MIGRATOR_VERSION and exit
#
# Behavior:
#   - Idempotent. Byte-compares the rendered output against the input;
#     only mv's if different (mtime unchanged on no-op).
#   - Never sources the file. Sourcing would execute user-supplied shell.
#   - Atomic via mktemp adjacent + mv.
#   - On first migration of a legacy file (USER present, MLAT_USER absent)
#     writes a `.pre-mlat-split` backup. Idempotent: never overwritten.
#   - When USER is present it is authoritative: any stale MLAT_USER /
#     MLAT_ENABLED lines are stripped and re-derived. The USER= line is
#     re-emitted in `USER="<escaped>"` form for shell-meta safety
#     (defense for hand-edited files; PHP webconfig sanitize already
#     restricts to [A-Za-z0-9_.-]).
#   - When USER is absent, the file is treated as already on the new
#     schema and not touched.
#   - Empty USER (USER="") is treated as "opted in, no name" and
#     produces MLAT_USER="Anonymous" / MLAT_ENABLED=true, matching the
#     defaults in feed/configure.sh and feed/scripts/apl-feed/mlat.sh.
#
# Env vars:
#   AIRPLANES_CONFIG_LOCK_HELD=1   Skip flock (caller already holds it).
#                                  Used by install-adsbconfig.sh wrapper.

set -euo pipefail

MIGRATOR_VERSION=1
LOCK_FILE="/var/lock/airplanes-config.lock"

# Extract the last-wins value of KEY from FILE without sourcing it.
#
# Returns:
#   0  KEY present (value printed to stdout; may be empty)
#   1  KEY absent
#   2  KEY present but malformed (e.g. unterminated quote)
extract_key() {
    local file="$1" key="$2"
    local line raw found=0
    raw=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        case "$line" in
            "${key}="*)
                raw="${line#"${key}="}"
                found=1
                ;;
        esac
    done < "$file"

    if (( ! found )); then
        return 1
    fi

    case "$raw" in
        '"'*)
            # Double-quoted: handle \\, \", \$, \` escapes; reject if
            # closing quote is missing.
            local result="" i len=${#raw} escaped=0 closed=0 c
            for (( i=1; i<len; i++ )); do
                c="${raw:$i:1}"
                if (( escaped )); then
                    result+="$c"
                    escaped=0
                elif [[ "$c" == '\' ]]; then
                    escaped=1
                elif [[ "$c" == '"' ]]; then
                    closed=1
                    break
                else
                    result+="$c"
                fi
            done
            if (( ! closed )); then
                printf 'migrate-config.sh: %s: malformed double-quoted value for %s=\n' "$file" "$key" >&2
                return 2
            fi
            printf '%s' "$result"
            ;;
        "'"*)
            # Single-quoted: no escapes; reject if closing quote missing.
            local body="${raw#\'}"
            case "$body" in
                *"'"*)
                    body="${body%%\'*}"
                    printf '%s' "$body"
                    ;;
                *)
                    printf 'migrate-config.sh: %s: malformed single-quoted value for %s=\n' "$file" "$key" >&2
                    return 2
                    ;;
            esac
            ;;
        *)
            # Unquoted: ends at first whitespace (trailing comments must
            # be space-separated per shell parsing).
            printf '%s' "${raw%%[[:space:]]*}"
            ;;
    esac
    return 0
}

# Escape a literal value for safe inclusion in `KEY="<value>"` form.
# Order matters: backslash first so subsequent escapes don't double-up.
escape_for_double_quoted() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\$/\\\$}"
    v="${v//\`/\\\`}"
    v="${v//\"/\\\"}"
    printf '%s' "$v"
}

# Decide MLAT_USER / MLAT_ENABLED from a USER value per migration rules.
# Sets caller-scope variables MLAT_USER_OUT and MLAT_ENABLED_OUT.
derive_mlat_from_user() {
    local user="$1"
    case "$user" in
        0|disable)
            MLAT_USER_OUT=""
            MLAT_ENABLED_OUT="false"
            ;;
        '')
            # Empty USER → "Anonymous" so the daemon's strict-fail on
            # empty MLAT_USER + MLAT_ENABLED=true never fires. Mirrors
            # the writer-side defaults in feed/configure.sh and
            # feed/scripts/apl-feed/mlat.sh.
            MLAT_USER_OUT="Anonymous"
            MLAT_ENABLED_OUT="true"
            ;;
        *)
            MLAT_USER_OUT="$user"
            MLAT_ENABLED_OUT="true"
            ;;
    esac
}

# Run the migration on $path. Caller is responsible for the lock.
do_migrate() {
    local path="$1"
    local backup_path="${path}.pre-mlat-split"

    local user_value="" user_present=0 mlat_user_present=0 rc

    if user_value="$(extract_key "$path" USER)"; then
        user_present=1
    else
        rc=$?
        case "$rc" in
            1) user_present=0 ;;
            2) exit 2 ;;
            *) exit "$rc" ;;
        esac
    fi

    if extract_key "$path" MLAT_USER >/dev/null; then
        mlat_user_present=1
    else
        rc=$?
        case "$rc" in
            1) mlat_user_present=0 ;;
            2) exit 2 ;;
            *) exit "$rc" ;;
        esac
    fi

    # MLAT_ENABLED malformed is also a hard fail, even though we don't
    # use its value here (it gets re-derived).
    if extract_key "$path" MLAT_ENABLED >/dev/null; then
        :
    else
        rc=$?
        case "$rc" in
            1) : ;;
            2) exit 2 ;;
            *) exit "$rc" ;;
        esac
    fi

    # USER absent → file is already on new schema (or has no schema).
    # Don't touch it. mtime stays unchanged.
    if (( ! user_present )); then
        return 0
    fi

    # USER present: migrate. USER is authoritative; any stale MLAT_USER
    # / MLAT_ENABLED is stripped and re-derived.
    local MLAT_USER_OUT="" MLAT_ENABLED_OUT=""
    derive_mlat_from_user "$user_value"

    local user_escaped mlat_user_escaped
    user_escaped="$(escape_for_double_quoted "$user_value")"
    mlat_user_escaped="$(escape_for_double_quoted "$MLAT_USER_OUT")"

    # Backup once on first transition out of pure-legacy (USER present,
    # MLAT_USER absent). Never overwritten.
    if [[ ! -f "$backup_path" ]] && (( ! mlat_user_present )); then
        cp -fp "$path" "$backup_path"
    fi

    # Render desired output to an adjacent temp file. The first USER=
    # line becomes the anchor: re-emitted in normalized form, immediately
    # followed by MLAT_USER and MLAT_ENABLED. Subsequent USER= lines and
    # any existing MLAT_USER= / MLAT_ENABLED= lines are dropped.
    local tmp
    tmp="$(mktemp "${path}.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT

    {
        local line trimmed user_seen=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            trimmed="${line%$'\r'}"
            case "$trimmed" in
                'USER='*)
                    if (( ! user_seen )); then
                        printf 'USER="%s"\n' "$user_escaped"
                        printf 'MLAT_USER="%s"\n' "$mlat_user_escaped"
                        printf 'MLAT_ENABLED=%s\n' "$MLAT_ENABLED_OUT"
                        user_seen=1
                    fi
                    ;;
                'MLAT_USER='*|'MLAT_ENABLED='*)
                    : # drop; will be re-emitted by the USER anchor
                    ;;
                *)
                    printf '%s\n' "$line"
                    ;;
            esac
        done < "$path"
    } > "$tmp"

    # Preserve mode and ownership. On vfat /boot ownership is meaningless,
    # so chown failure is tolerated; chmod falls back to 0644.
    chmod --reference="$path" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    chown --reference="$path" "$tmp" 2>/dev/null || true

    # Byte-compare. No-op when output is identical to input so mtime is
    # preserved across idempotent re-runs.
    if cmp -s "$path" "$tmp"; then
        rm -f "$tmp"
        trap - EXIT
        return 0
    fi

    mv -f "$tmp" "$path"
    trap - EXIT
}

main() {
    if [[ "${1:-}" == "--version" ]]; then
        printf 'migrate-config.sh version=%d\n' "$MIGRATOR_VERSION"
        return 0
    fi

    local path="${1:-}"
    if [[ -z "$path" ]]; then
        echo "usage: migrate-config.sh <path>" >&2
        return 2
    fi

    if [[ ! -f "$path" ]]; then
        # Nothing to migrate. Don't fail — could be a fresh install
        # where airplanes-config.txt hasn't been created yet.
        return 0
    fi

    if [[ "${AIRPLANES_CONFIG_LOCK_HELD:-}" == "1" ]]; then
        do_migrate "$path"
        return
    fi

    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock 9
    do_migrate "$path"
}

main "$@"
