#!/usr/bin/env bash
# migrate-config.sh - Migrate legacy boot-config keys to the canonical
# schema expected by the new feed daemons in airplanes-live/feed.
#
# Canonical home: airplanes-live/airplanes-webconfig:helpers/migrate-config.sh
# Vendored byte-equivalent copy: airplanes-live/airplanes-update:
#     skeleton/usr/local/lib/airplanes-update/migrate-config.sh
# Drift between the two is enforced by a CI test in airplanes-update.
#
# Usage:
#   migrate-config.sh <path>            apply migrations in-place
#   migrate-config.sh --version         print MIGRATOR_VERSION and exit
#
# Migrations run, in order:
#
#   1. USER → MLAT_USER + MLAT_ENABLED  (do_migrate calls _migrate_user_to_split)
#
#      - USER="0" or USER="disable"  → MLAT_USER="", MLAT_ENABLED=false
#      - USER=""                     → MLAT_USER="Anonymous", MLAT_ENABLED=true
#                                      (matches feed/configure.sh's default;
#                                      avoids the daemon's empty-MLAT_USER fail)
#      - USER=<other>                → MLAT_USER=<value>, MLAT_ENABLED=true
#      - USER absent                 → no-op
#
#      USER is preserved on disk in normalized `USER="<escaped>"` form so
#      legacy consumers that still key off USER keep working. Backup at
#      `<path>.pre-mlat-split` written once on first transition out of
#      pure-legacy state.
#
#   2. MLAT_MARKER → MLAT_PRIVATE  (do_migrate calls _migrate_marker_to_private)
#
#      - MLAT_MARKER="no"            → MLAT_PRIVATE=true   (inverted polarity)
#      - MLAT_MARKER="yes"           → MLAT_PRIVATE=false
#      - MLAT_MARKER=<other>         → exit 2 (strict-fail; privacy keys
#                                      must not silently default to public)
#      - MLAT_MARKER absent          → no-op
#
#      Case-insensitive (PHP webconfig's yes/no dropdown matches uppercase
#      values too). MLAT_MARKER is PRESERVED on the file alongside the
#      newly emitted MLAT_PRIVATE: PHP webconfig (deprecating; archived
#      after MVP soak) rebuilds airplanes-config.txt from $_POST and would
#      strip MLAT_PRIVATE on the next save without a corresponding form
#      control. Keeping MLAT_MARKER lets the legacy writer keep working;
#      the migrator re-derives MLAT_PRIVATE from MLAT_MARKER on every save,
#      mirroring USER → MLAT_USER re-derivation above. MLAT_MARKER wins
#      when both keys are present. Backup at `<path>.pre-marker-split`.
#
# Behavior shared by all migrations:
#   - Idempotent. Each migration byte-compares its rendered output against
#     the input and only mv's if different (mtime unchanged on no-op).
#   - Never sources the file. Sourcing would execute user-supplied shell.
#   - Atomic via mktemp adjacent + mv.
#   - Single flock around the chain. Each migration assumes the caller
#     holds the lock; nested invocations re-enter via AIRPLANES_CONFIG_LOCK_HELD.
#
# Env vars:
#   AIRPLANES_CONFIG_LOCK_HELD=1     Skip flock (caller already holds it).
#                                    Used by install-adsbconfig.sh wrapper.
#   AIRPLANES_CONFIG_BACKUP_BASE     Override path prefix for `.pre-X-split`
#                                    backups. Defaults to the migrated file's
#                                    path. install-adsbconfig.sh sets this to
#                                    /boot/airplanes-config.txt so backups land
#                                    at the canonical location even when the
#                                    migrator runs on a random temp file.

set -euo pipefail

MIGRATOR_VERSION=2
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

# Decide MLAT_PRIVATE from a MLAT_MARKER value per migration rules.
# Sets caller-scope variable MLAT_PRIVATE_OUT. Inverted polarity: legacy
# MLAT_MARKER="no" meant privacy ON. Case-insensitive: PHP webconfig's
# dropdown handles uppercase, so the migrator does too. Strict-fail on
# anything else — for a privacy key, silently defaulting to public on
# unrecognized input is the wrong failure mode.
derive_private_from_marker() {
    local marker="${1,,}"
    case "$marker" in
        no)  MLAT_PRIVATE_OUT="true" ;;
        yes) MLAT_PRIVATE_OUT="false" ;;
        *)
            printf 'migrate-config.sh: unrecognized MLAT_MARKER value: %s\n' "$1" >&2
            exit 2
            ;;
    esac
}

# Migration 1: USER → MLAT_USER + MLAT_ENABLED. Caller holds the lock.
_migrate_user_to_split() {
    local path="$1"
    local backup_path="${AIRPLANES_CONFIG_BACKUP_BASE:-$path}.pre-mlat-split"

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

# Migration 2: MLAT_MARKER → MLAT_PRIVATE. Caller holds the lock.
#
# MLAT_MARKER is preserved on disk because PHP webconfig is still the only
# writer of /boot/airplanes-config.txt and only knows about MLAT_MARKER;
# stripping it would cause the next PHP save (which rebuilds from $_POST)
# to drop both keys. So this migration co-emits MLAT_PRIVATE alongside
# MLAT_MARKER and re-derives MLAT_PRIVATE on every save — mirroring the
# USER → MLAT_USER re-derivation pattern above.
#
# Conflict rule: MLAT_MARKER wins when both keys are present (PHP is the
# active writer; any existing MLAT_PRIVATE is re-derived).
_migrate_marker_to_private() {
    local path="$1"
    local backup_path="${AIRPLANES_CONFIG_BACKUP_BASE:-$path}.pre-marker-split"

    local marker_value="" marker_present=0
    local mlat_private_present=0 rc

    if marker_value="$(extract_key "$path" MLAT_MARKER)"; then
        marker_present=1
    else
        rc=$?
        case "$rc" in
            1) marker_present=0 ;;
            2) exit 2 ;;
            *) exit "$rc" ;;
        esac
    fi

    if extract_key "$path" MLAT_PRIVATE >/dev/null; then
        mlat_private_present=1
    else
        rc=$?
        case "$rc" in
            1) mlat_private_present=0 ;;
            2) exit 2 ;;
            *) exit "$rc" ;;
        esac
    fi

    # MLAT_MARKER absent → nothing to translate. MLAT_PRIVATE (if present)
    # is left alone so feeders without PHP webconfig keep whatever
    # canonical value was written by another writer.
    if (( ! marker_present )); then
        return 0
    fi

    # MLAT_MARKER is authoritative: any stale MLAT_PRIVATE is stripped
    # and re-derived from MLAT_MARKER.
    local MLAT_PRIVATE_OUT=""
    derive_private_from_marker "$marker_value"

    # Backup once on first transition out of pure-legacy (MLAT_MARKER
    # present, MLAT_PRIVATE absent). Never overwritten.
    if [[ ! -f "$backup_path" ]] && (( ! mlat_private_present )); then
        cp -fp "$path" "$backup_path"
    fi

    # Render new output. The first MLAT_MARKER line becomes the anchor:
    # the line itself is preserved (legacy writer keeps working), and
    # MLAT_PRIVATE is emitted on the line immediately after. Subsequent
    # MLAT_MARKER= duplicates and any existing MLAT_PRIVATE= lines are
    # dropped.
    local tmp
    tmp="$(mktemp "${path}.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT

    {
        local line trimmed marker_seen=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            trimmed="${line%$'\r'}"
            case "$trimmed" in
                'MLAT_MARKER='*)
                    if (( ! marker_seen )); then
                        printf '%s\n' "$line"
                        printf 'MLAT_PRIVATE=%s\n' "$MLAT_PRIVATE_OUT"
                        marker_seen=1
                    fi
                    ;;
                'MLAT_PRIVATE='*)
                    : # drop; re-emitted at the MLAT_MARKER anchor above
                    ;;
                *)
                    printf '%s\n' "$line"
                    ;;
            esac
        done < "$path"
    } > "$tmp"

    chmod --reference="$path" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    chown --reference="$path" "$tmp" 2>/dev/null || true

    if cmp -s "$path" "$tmp"; then
        rm -f "$tmp"
        trap - EXIT
        return 0
    fi

    mv -f "$tmp" "$path"
    trap - EXIT
}

# Run the chain of migrations on $path. Caller is responsible for the lock.
do_migrate() {
    local path="$1"
    _migrate_user_to_split "$path"
    _migrate_marker_to_private "$path"
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
