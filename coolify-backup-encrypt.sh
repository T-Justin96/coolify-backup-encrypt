#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# coolify-backup-encrypt.sh
# =============================================================================
# Encrypts Coolify backup files IN PLACE (same path/filename) so that Coolify's
# own retention keeps deleting them correctly.
#
# Provided AS IS, WITHOUT ANY WARRANTY. You are responsible for verifying that
# your own restores work. See LICENSE and the README.
# https://github.com/T-Justin96/coolify-backup-encrypt
#
# How it works
# ------------
# 1. Reads finished backup executions (status = 'success', finished_at set)
#    from the Coolify PostgreSQL database. The database is only READ, never
#    written, and no Coolify file is modified.
# 2. For every referenced file that is not yet encrypted, the file is encrypted
#    to "<file>.tmp.$$" and then atomically moved over the original (same name,
#    same location).
# 3. Idempotent: every encrypted file starts with a magic header, so files that
#    were already encrypted are skipped on the next run.
#
# Encryption is ASYMMETRIC using age: the host only needs the PUBLIC key
# (recipient) and therefore can only encrypt, never decrypt. Keep the private
# key offline and decrypt elsewhere. There is no symmetric fallback, by design.
#
# Because the filename/path never changes, Coolify's retention
# (removeOldBackups / deleteBackupsLocally / deleteBackupsS3) still works and
# deletes the encrypted file. Downloads/restores return the encrypted blob,
# which you have to decrypt yourself.
#
# -----------------------------------------------------------------------------
# SCHEMA DEPENDENCY - READ BEFORE AND AFTER EVERY COOLIFY UPGRADE
# -----------------------------------------------------------------------------
# This script reads Coolify's INTERNAL tables directly. They are not a public
# contract, so a Coolify upgrade may rename or remove a column. Without a guard
# this script would then silently encrypt nothing - and nobody would notice
# until a restore is needed.
#
# Required tables and columns (verified against Coolify v4.3.19):
#   scheduled_database_backup_executions : status, finished_at,
#                                          local_storage_deleted, filename
#   scheduled_volume_backup_executions   : status, finished_at,
#                                          local_storage_deleted, filename
# Value dependency: only rows with status = 'success' are picked up.
#
# Safety net: before doing any work the script verifies these columns against
# information_schema and exits NON-ZERO with a clear message when one is
# missing. Run this after every Coolify upgrade:
#     coolify-backup-encrypt.sh --check-schema
#
# Usage:
#   coolify-backup-encrypt.sh                          # encrypt pass (timer/cron)
#   coolify-backup-encrypt.sh --dry-run                # show what would be done
#   coolify-backup-encrypt.sh --check-schema           # preflight + schema guard
#   coolify-backup-encrypt.sh --decrypt FILE           # decrypt FILE to stdout
#   coolify-backup-encrypt.sh --decrypt-to OUT ENC     # decrypt ENC into OUT
#   coolify-backup-encrypt.sh --cleanup-tmp            # remove orphaned *.tmp.*
#   coolify-backup-encrypt.sh --finalize               # delete the bootstrapped key
#   coolify-backup-encrypt.sh --version                # script + Coolify version
#
# Config (optional, sourced if present): /etc/coolify-backup-encrypt.conf
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="1.1.0"

CONF_FILE="${CONF_FILE:-/etc/coolify-backup-encrypt.conf}"
if [ -f "$CONF_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONF_FILE"
fi

# ---- Defaults (override them in $CONF_FILE) ---------------------------------
: "${COOLIFY_ENV_FILE:=/data/coolify/source/.env}"
: "${DB_CONTAINER:=coolify-db}"
: "${BACKUP_ROOT:=/data/coolify/backups}"
: "${AGE_RECIPIENT:=}"                 # PUBLIC key (age1...) - required
: "${AGE_IDENTITY:=/etc/coolify-backup-encrypt/age/identity.txt}"  # decrypt only
: "${GRAB_IDENTITY:=/root/GRAB-ME-BEFORE-DELETE-identity.txt}"  # install.sh bootstrap
: "${GRACE_SECONDS:=5}"                # wait this long after finished_at
: "${MAGIC:=COOLIFYENC1}"              # idempotency marker (must stay constant)
: "${MAX_LOAD:=0}"                     # >0: skip run when load1 > MAX_LOAD * cpus
: "${LOCK_FILE:=/run/coolify-backup-encrypt.lock}"
: "${TMP_MAX_AGE_MINUTES:=60}"         # --cleanup-tmp: age threshold for *.tmp.*

DRY_RUN=0
FORCE=0
MODE="run"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: coolify-backup-encrypt.sh [options]

  (no option)               Run one encryption pass and exit.
  -n, --dry-run             Print what would be encrypted, change nothing.
  --check-schema            Preflight: config, tools, database and Coolify
                            schema. Nothing is encrypted. Exit != 0 on problem.
                            Run this after every Coolify upgrade.
  -d, --decrypt FILE        Decrypt an encrypted backup file to stdout.
  --decrypt-to OUT ENC      Decrypt ENC and write it to OUT (mode 0600, atomic).
                            Refuses to overwrite OUT unless --force is given.
  -f, --force               Allow --decrypt-to to overwrite an existing file.
  --cleanup-tmp             Remove orphaned '*.tmp.*' files (crashed runs).
  --finalize                Delete the temporary private key that install.sh
                            left on this host. Asks for confirmation.
  -V, --version             Print script and Coolify version.
  -h, --help                Show this help.

Configuration is read from /etc/coolify-backup-encrypt.conf (optional).

  SCHEMA DEPENDENCY: this script reads Coolify's internal backup execution
  tables. Verify them after every Coolify upgrade with --check-schema.
EOF
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
# Reads the first value of KEY=... from an env file (strips surrounding quotes).
read_env() {
    local key="$1"
    [ -f "$COOLIFY_ENV_FILE" ] || return 1
    sed -n "s/^${key}=//p" "$COOLIFY_ENV_FILE" | head -n1 | sed -e 's/^"//' -e 's/"$//'
}

# True when the file starts with the magic header.
is_encrypted() {
    local file="$1" prefix
    [ -f "$file" ] || return 1
    prefix="$(head -c "${#MAGIC}" "$file" 2>/dev/null | tr -d '\000')"
    [ "$prefix" = "$MAGIC" ]
}

# Coolify version from the env file (best effort, may be empty).
coolify_version() {
    read_env COOLIFY_VERSION 2>/dev/null || true
}

# Read-only query against the Coolify database, one value per line.
db_query() {
    docker exec -e PGPASSWORD="${DB_PASSWORD:-}" "$DB_CONTAINER" \
        psql -U "$DB_USERNAME" -d "$DB_DATABASE" -Atc "$1"
}

# Encrypts a single file in place.
encrypt_file() {
    local src="$1"
    local tmp="${src}.tmp.$$"
    local mode owner group rc=0

    mode="$(stat -c '%a' "$src" 2>/dev/null || true)"
    owner="$(stat -c '%u' "$src" 2>/dev/null || true)"
    group="$(stat -c '%g' "$src" 2>/dev/null || true)"

    # age, public-key mode: this host can encrypt, it cannot decrypt.
    {   printf '%s\n' "$MAGIC"
        age --encrypt --recipient "$AGE_RECIPIENT"
    } < "$src" > "$tmp" || rc=$?

    if [ "$rc" -ne 0 ] || [ ! -s "$tmp" ]; then
        log "  ERROR: encryption failed (rc=${rc}) for ${src}"
        rm -f -- "$tmp"
        return 1
    fi

    if ! is_encrypted "$tmp"; then
        log "  ERROR: sanity check failed for ${tmp}"
        rm -f -- "$tmp"
        return 1
    fi

    [ -n "$mode" ] && chmod "$mode" "$tmp" 2>/dev/null || true
    if [ -n "$owner" ] && [ -n "$group" ] && [ "$(id -u)" -eq 0 ]; then
        chown "${owner}:${group}" "$tmp" 2>/dev/null || true
    fi

    sync -d "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$src"
    return 0
}

# -----------------------------------------------------------------------------
# Decryption (manual use, e.g. before a restore)
# -----------------------------------------------------------------------------
decrypt_stream() {
    [ -r "$AGE_IDENTITY" ] || die "AGE_IDENTITY '${AGE_IDENTITY}' is not readable"
    age --decrypt --identity "$AGE_IDENTITY"
}

do_decrypt() {
    local file="$1"
    [ -f "$file" ] || die "file not found: ${file}"
    if ! is_encrypted "$file"; then
        die "not encrypted with this script (missing ${MAGIC} header): ${file}"
    fi
    # Skip the magic header and the newline that follows it.
    tail -c "+$(( ${#MAGIC} + 2 ))" "$file" | decrypt_stream
}

# Decrypts an encrypted backup into a new file (mode 0600, atomic rename).
do_decrypt_to() {
    local out="$1" file="$2" tmp
    [ -f "$file" ] || die "file not found: ${file}"
    if ! is_encrypted "$file"; then
        die "not encrypted with this script (missing ${MAGIC} header): ${file}"
    fi
    if [ -e "$out" ] && [ "$FORCE" -ne 1 ]; then
        die "output file already exists: ${out} (use --force to overwrite)"
    fi

    tmp="${out}.tmp.$$"
    if ! tail -c "+$(( ${#MAGIC} + 2 ))" "$file" | decrypt_stream > "$tmp"; then
        rm -f -- "$tmp"
        die "decryption failed for ${file} (wrong key, truncated or corrupt file?)"
    fi

    chmod 600 "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$out"
    log "Decrypted: ${file} -> ${out}"
}

# -----------------------------------------------------------------------------
# --finalize: remove the private key that install.sh left on this host
# -----------------------------------------------------------------------------
# install.sh generates the key pair on the host so that encryption works
# immediately. That temporary private key must be copied away and then deleted,
# otherwise the host can decrypt, which defeats the whole point.
do_finalize() {
    local grab="$GRAB_IDENTITY"

    [ -f "$grab" ] || die "no pending private key at '${grab}' - already finalized?"

    log "Pending private key found: ${grab}"
    log "This will PERMANENTLY delete it from this server. Without a copy elsewhere"
    log "every backup encrypted with it becomes unrecoverable."

    printf 'Type exactly "ja" to delete it, anything else aborts: '
    local answer=""
    read -r answer || true
    if [ "$answer" != "ja" ]; then
        die "aborted - nothing was deleted"
    fi

    if command -v shred >/dev/null 2>&1; then
        shred -u -- "$grab" 2>/dev/null || rm -f -- "$grab"
    else
        rm -f -- "$grab"
    fi
    if [ -e "$grab" ]; then
        die "could not delete '${grab}' - remove it manually"
    fi

    log "Private key removed from this server."

    if [ -z "$AGE_RECIPIENT" ]; then
        log "WARNING: AGE_RECIPIENT is not set in ${CONF_FILE} - encryption will fail."
    else
        log "Public recipient still configured: ${AGE_RECIPIENT}"
    fi

    log "Now verify the copy you took away can actually decrypt:"
    log "  tail -c +13 <backup-file> | age --decrypt --identity <your-copy> > restore.dmp"
}

# -----------------------------------------------------------------------------
# Coolify schema guard
# -----------------------------------------------------------------------------
# These are INTERNAL Coolify tables, not a public contract. If a column is
# renamed/removed by a Coolify upgrade, the script must fail loudly instead of
# silently encrypting nothing. Verified against Coolify v4.3.19.
SCHEMA_TABLES="scheduled_database_backup_executions scheduled_volume_backup_executions"
SCHEMA_COLUMNS="status finished_at local_storage_deleted filename"

# Prints the missing "<table>.<column>" pairs (space separated) and returns 1
# when the expected schema is incomplete. Returns 0 when everything is present.
check_schema() {
    local sql rows missing="" table column

    sql="SELECT table_name || '.' || column_name
           FROM information_schema.columns
          WHERE table_schema = 'public'
            AND table_name IN ('scheduled_database_backup_executions',
                               'scheduled_volume_backup_executions')
            AND column_name IN ('status', 'finished_at',
                                'local_storage_deleted', 'filename');"

    if ! rows="$(db_query "$sql")"; then
        die "schema check failed: could not query information_schema"
    fi

    for table in $SCHEMA_TABLES; do
        for column in $SCHEMA_COLUMNS; do
            if ! printf '%s\n' "$rows" | grep -qxF "${table}.${column}"; then
                missing="${missing} ${table}.${column}"
            fi
        done
    done

    if [ -n "$missing" ]; then
        printf '%s' "${missing# }"
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Database (read only)
# -----------------------------------------------------------------------------
fetch_filenames() {
    local sql
    sql="SELECT filename FROM scheduled_database_backup_executions
          WHERE status = 'success'
            AND finished_at IS NOT NULL
            AND filename IS NOT NULL
            AND filename <> ''
            AND local_storage_deleted = false
            AND finished_at <= (now() AT TIME ZONE 'UTC') - interval '${GRACE_SECONDS} seconds'
          UNION ALL
          SELECT filename FROM scheduled_volume_backup_executions
          WHERE status = 'success'
            AND finished_at IS NOT NULL
            AND filename IS NOT NULL
            AND filename <> ''
            AND local_storage_deleted = false
            AND finished_at <= (now() AT TIME ZONE 'UTC') - interval '${GRACE_SECONDS} seconds';"

    db_query "$sql"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
acquire_lock() {
    if ! exec 9>"$LOCK_FILE" 2>/dev/null; then
        LOCK_FILE="/tmp/coolify-backup-encrypt.lock"
        exec 9>"$LOCK_FILE"
    fi
    if ! flock -n 9; then
        log "another instance is already running, exiting"
        exit 0
    fi
}

load_too_high() {
    [ "$MAX_LOAD" != "0" ] || return 1
    local cpus load1
    cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
    awk -v l="$load1" -v c="$cpus" -v m="$MAX_LOAD" 'BEGIN { exit !(l > c * m) }'
}

print_version() {
    printf 'coolify-backup-encrypt %s\n' "$SCRIPT_VERSION"
    local cv
    cv="$(coolify_version)"
    printf 'coolify %s\n' "${cv:-unknown}"
}

# Everything that must be true before a single file is touched. In particular
# this verifies the Coolify tables/columns we depend on, so a Coolify upgrade
# cannot silently turn this script into a no-op.
preflight() {
    DB_USERNAME="$(read_env DB_USERNAME || true)"
    DB_DATABASE="$(read_env DB_DATABASE || true)"
    DB_PASSWORD="$(read_env DB_PASSWORD || true)"
    : "${DB_USERNAME:=coolify}"
    : "${DB_DATABASE:=coolify}"
    COOLIFY_VERSION_DETECTED="$(coolify_version)"

    command -v docker >/dev/null 2>&1 || die "docker not found"
    docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true \
        || die "database container '${DB_CONTAINER}' is not running"

    command -v age >/dev/null 2>&1 || die "age not found (install it: apt-get install age)"
    [ -n "$AGE_RECIPIENT" ] || die "AGE_RECIPIENT is not set in ${CONF_FILE} - nothing to encrypt with"

    # Prove the recipient is usable BEFORE a single backup is touched.
    if ! printf 'recipient check\n' | age --encrypt --recipient "$AGE_RECIPIENT" >/dev/null 2>&1; then
        die "AGE_RECIPIENT '${AGE_RECIPIENT}' is not a usable age recipient"
    fi

    # SCHEMA DEPENDENCY guard - see the header of this file and the README.
    local missing
    if ! missing="$(check_schema)"; then
        die "Coolify schema changed - missing: ${missing}. Nothing was encrypted. See README > Schema dependency (verified against Coolify v4.3.19)."
    fi
}

# --check-schema / --doctor: validate everything, encrypt nothing.
check_only() {
    preflight
    log "preflight OK: tool=age container=${DB_CONTAINER} backup_root=${BACKUP_ROOT} coolify=${COOLIFY_VERSION_DETECTED:-unknown}"
    log "schema OK: ${SCHEMA_TABLES// /, } with columns: ${SCHEMA_COLUMNS// /, }"
}

# --cleanup-tmp: remove leftovers of interrupted runs.
cleanup_tmp() {
    [ -d "$BACKUP_ROOT" ] || die "BACKUP_ROOT '${BACKUP_ROOT}' does not exist"
    log "Removing orphaned '*.tmp.*' files older than ${TMP_MAX_AGE_MINUTES} minutes under ${BACKUP_ROOT}"
    local count=0 file
    while IFS= read -r -d '' file; do
        if [ "$DRY_RUN" -eq 1 ]; then
            log "DRY-RUN would remove: ${file}"
        else
            rm -f -- "$file"
            log "Removed: ${file}"
        fi
        count=$((count + 1))
    done < <(find "$BACKUP_ROOT" -type f -name '*.tmp.*' -mmin "+${TMP_MAX_AGE_MINUTES}" -print0 2>/dev/null)
    log "Cleanup done. removed=${count}"
}

run_pass() {
    acquire_lock

    if load_too_high; then
        log "system load is too high, skipping this run"
        exit 0
    fi

    preflight
    log "Starting pass (script ${SCRIPT_VERSION}, coolify ${COOLIFY_VERSION_DETECTED:-unknown}, age public-key)"

    local rows
    if ! rows="$(fetch_filenames)"; then
        die "database query failed"
    fi

    local total=0 encrypted=0 skipped=0 missing=0 empty=0 outside=0 failed=0 filename
    while IFS= read -r filename; do
        [ -n "$filename" ] || continue
        case "$filename" in
            *.tmp|*.tmp.*) continue ;;
        esac
        total=$((total + 1))

        # Safety bound: never touch anything outside the backup root.
        if [[ "$filename" != "${BACKUP_ROOT}/"* ]]; then
            outside=$((outside + 1))
            log "SKIP (outside BACKUP_ROOT ${BACKUP_ROOT}): ${filename}"
            continue
        fi

        if [ ! -e "$filename" ]; then
            # Not on this host: remote server, S3-only backup, or already deleted.
            missing=$((missing + 1))
            log "MISSING: ${filename} (remote server, S3-only, or already deleted)"
            continue
        fi
        [ -f "$filename" ] || { log "SKIP (not a regular file): ${filename}"; continue; }

        if is_encrypted "$filename"; then
            skipped=$((skipped + 1))
            continue
        fi

        if [ ! -s "$filename" ]; then
            empty=$((empty + 1))
            log "SKIP (empty file): ${filename}"
            continue
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            log "DRY-RUN would encrypt: ${filename}"
            encrypted=$((encrypted + 1))
            continue
        fi

        log "Encrypting: ${filename}"
        if encrypt_file "$filename"; then
            encrypted=$((encrypted + 1))
        else
            failed=$((failed + 1))
        fi
    done <<< "$rows"

    log "Done. candidates=${total} encrypted=${encrypted} already=${skipped} empty=${empty} missing=${missing} outside=${outside} failed=${failed}"
}

main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -V|--version)
                print_version
                exit 0
                ;;
            --check-schema|--doctor)
                MODE="check"
                ;;
            --cleanup-tmp)
                MODE="cleanup"
                ;;
            --finalize)
                MODE="finalize"
                ;;
            -n|--dry-run)
                DRY_RUN=1
                ;;
            -f|--force)
                FORCE=1
                ;;
            -d|--decrypt)
                shift
                [ "$#" -gt 0 ] || die "usage: $0 --decrypt FILE"
                do_decrypt "$1"
                exit 0
                ;;
            --decrypt-to)
                shift
                [ "$#" -ge 2 ] || die "usage: $0 --decrypt-to OUTPUT ENCRYPTED_FILE"
                do_decrypt_to "$1" "$2"
                exit 0
                ;;
            *)
                die "unknown option: $1"
                ;;
        esac
        shift
    done

    case "$MODE" in
        check) check_only ;;
        cleanup) cleanup_tmp ;;
        finalize) do_finalize ;;
        *) run_pass ;;
    esac
}

main "$@"
