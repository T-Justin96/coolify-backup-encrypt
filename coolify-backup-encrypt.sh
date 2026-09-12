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
#   coolify-backup-encrypt.sh --status                 # what is installed, what is going on
#   coolify-backup-encrypt.sh --dry-run                # show what would be done
#   coolify-backup-encrypt.sh --check-schema           # preflight + schema guard
#   coolify-backup-encrypt.sh --verify FILE            # sanity-check an encrypted file
#   coolify-backup-encrypt.sh --decrypt FILE           # decrypt FILE to stdout
#   coolify-backup-encrypt.sh --decrypt-to OUT ENC     # decrypt ENC into OUT
#   coolify-backup-encrypt.sh --cleanup-tmp            # remove orphaned *.tmp.*
#   coolify-backup-encrypt.sh --finalize               # delete the bootstrapped key
#   coolify-backup-encrypt.sh --update [--ref REF]     # upgrade script + systemd units
#   coolify-backup-encrypt.sh --uninstall              # remove everything but the backups
#   coolify-backup-encrypt.sh --version                # script + Coolify version
#
# Config (optional, sourced if present): /etc/coolify-backup-encrypt.conf
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="1.2.0"

# Where this script and its units live. Overridable so the self-test can point
# them at a scratch directory.
SELF_PATH="${BASH_SOURCE[0]:-}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/coolify-backup-encrypt.sh}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
UNIT_NAME="coolify-backup-encrypt"

# For --update: where to fetch new versions from.
REPO_SLUG="T-Justin96/coolify-backup-encrypt"
REPO_RAW_URL="https://raw.githubusercontent.com/${REPO_SLUG}"
CBX_REF="${CBX_REF:-main}"

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
: "${STATE_DIR:=/run}"                 # remembers which files were reported missing

DRY_RUN=0
FORCE=0
PURGE=0
IDENTITY=""
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
  --status                  Show what is installed and what is going on:
                            version, config, recipient, key, timer, counters.
  -n, --dry-run             Print what would be encrypted, change nothing.
  --check-schema            Preflight: config, tools, database and Coolify
                            schema. Nothing is encrypted. Exit != 0 on problem.
                            Run this after every Coolify upgrade.
  --verify FILE             Sanity-check an encrypted backup: magic header,
                            format and size. With --identity it also really
                            decrypts. Replaces the need for pg_restore.
  -d, --decrypt FILE        Decrypt an encrypted backup file to stdout.
  --decrypt-to OUT ENC      Decrypt ENC and write it to OUT (mode 0600, atomic).
                            Refuses to overwrite OUT unless --force is given.
  --identity FILE           Private key to use for --verify/--decrypt, instead
                            of AGE_IDENTITY.
  -f, --force               Allow --decrypt-to to overwrite an existing file.
  --cleanup-tmp             Remove orphaned '*.tmp.*' files (crashed runs).
  --finalize                Delete the temporary private key that install.sh
                            left on this host. Asks for confirmation.
  --update                  Download and install the newest script + systemd
                            units. Never touches your config or your keys.
  --ref REF                 Which branch/tag/commit --update should use
                            (default: main, e.g. --ref v1.2.0).
  --uninstall               Stop and remove timer, units and the script.
                            Backup files are never deleted. Asks twice.
  --purge                   With --uninstall: also remove the config and
                            /etc/coolify-backup-encrypt/.
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

warn() {
    printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

load_db_creds() {
    DB_USERNAME="$(read_env DB_USERNAME || true)"
    DB_DATABASE="$(read_env DB_DATABASE || true)"
    DB_PASSWORD="$(read_env DB_PASSWORD || true)"
    : "${DB_USERNAME:=coolify}"
    : "${DB_DATABASE:=coolify}"
}

# How many backups Coolify already pushed to S3. Those copies are PLAINTEXT:
# Coolify uploads right after finishing the dump, this script runs afterwards and
# only rewrites the local file. Returns a number, or nothing when it cannot tell.
count_s3_plaintext() {
    local sql rows
    sql="SELECT filename FROM scheduled_database_backup_executions WHERE s3_uploaded = true
         UNION
         SELECT filename FROM scheduled_volume_backup_executions WHERE s3_uploaded = true;"
    rows="$(db_query "$sql" 2>/dev/null || true)"
    [ -n "$rows" ] || return 0
    printf '%s\n' "$rows" | grep -c .
}

# Backups that live on another server are normal and expected. Log them only
# when the set actually changes, otherwise the 60s timer buries the journal.
report_missing() { # $1 = newline separated list
    local current="$1" state_file="$STATE_DIR/${UNIT_NAME}.missing" previous="" line

    mkdir -p "$STATE_DIR" 2>/dev/null || true
    if [ -f "$state_file" ]; then
        previous="$(cat "$state_file" 2>/dev/null || true)"
    fi

    if [ "$current" = "$previous" ]; then
        return 0
    fi

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if ! printf '%s\n' "$previous" | grep -qxF -- "$line"; then
            log "NOT ON THIS HOST (other server, S3-only, or deleted): ${line}"
        fi
    done <<< "$current"

    printf '%s' "$current" > "$state_file" 2>/dev/null || true
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
# --status: what is installed and what is going on
# -----------------------------------------------------------------------------
# Shortens a long key/recipient for display.
shorten() {
    local value="$1"
    if [ "${#value}" -gt 34 ]; then
        printf '%s...%s' "$(printf '%s' "$value" | cut -c1-18)" \
                         "$(printf '%s' "$value" | rev | cut -c1-12 | rev)"
    else
        printf '%s' "$value"
    fi
}

status_counts() {
    local rows filename total=0 enc=0 pending=0 missing=0 s3_count=""

    load_db_creds
    if ! rows="$(fetch_filenames 2>/dev/null)"; then
        printf 'backups     cannot query the database (container down, or wrong creds)\n'
        return 0
    fi

    while IFS= read -r filename; do
        [ -n "$filename" ] || continue
        case "$filename" in
            *.tmp|*.tmp.*) continue ;;
        esac
        total=$((total + 1))
        if [ ! -e "$filename" ]; then
            missing=$((missing + 1))
        elif is_encrypted "$filename"; then
            enc=$((enc + 1))
        else
            pending=$((pending + 1))
        fi
    done <<< "$rows"

    printf 'backups     %s referenced -> %s encrypted, %s pending, %s not on this host\n' \
        "$total" "$enc" "$pending" "$missing"

    s3_count="$(count_s3_plaintext)"
    if [ -n "$s3_count" ] && [ "$s3_count" -gt 0 ]; then
        printf 's3          %s backup(s) were uploaded to S3 by Coolify in PLAINTEXT\n' "$s3_count"
        printf '            this script only encrypts the local copy afterwards\n'
    fi
}

do_status() {
    local cv tline tenabled tactiver

    printf 'coolify-backup-encrypt %s\n' "$SCRIPT_VERSION"
    printf 'script      %s\n' "${SELF_PATH:-$BIN_PATH}"

    if [ -f "$CONF_FILE" ]; then
        printf 'config      %s (mode %s)\n' "$CONF_FILE" "$(stat -c '%a' "$CONF_FILE" 2>/dev/null || echo '?')"
    else
        printf 'config      %s (MISSING - using built-in defaults)\n' "$CONF_FILE"
    fi

    printf 'crypto      age, public-key only\n'

    if [ -n "$AGE_RECIPIENT" ]; then
        printf 'recipient   %s\n' "$(shorten "$AGE_RECIPIENT")"
    else
        printf 'recipient   NOT SET - encryption cannot work, fix %s\n' "$CONF_FILE"
    fi

    if [ -f "$GRAB_IDENTITY" ]; then
        printf 'key on host YES -> %s\n' "$GRAB_IDENTITY"
        printf '            this host CAN decrypt; run --finalize once your copy is verified\n'
    else
        printf 'key on host no (good)\n'
    fi

    if [ -r "$AGE_IDENTITY" ]; then
        printf 'identity    %s (readable)\n' "$AGE_IDENTITY"
    else
        printf 'identity    %s (absent - only needed for --decrypt/--verify)\n' "$AGE_IDENTITY"
    fi

    load_db_creds
    if command -v docker >/dev/null 2>&1; then
        if docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true; then
            printf 'container   %s running\n' "$DB_CONTAINER"
        else
            printf 'container   %s NOT running\n' "$DB_CONTAINER"
        fi
    else
        printf 'container   docker not found\n'
    fi

    cv="$(coolify_version)"
    printf 'coolify     version %s\n' "${cv:-unknown}"

    if [ ! -f "${SYSTEMD_DIR}/${UNIT_NAME}.timer" ]; then
        printf 'timer       not installed (%s/%s.timer is missing)\n' "$SYSTEMD_DIR" "$UNIT_NAME"
    elif command -v systemctl >/dev/null 2>&1; then
        tenabled="$(systemctl is-enabled "${UNIT_NAME}.timer" 2>/dev/null)" || tenabled="unknown"
        tactiver="$(systemctl is-active "${UNIT_NAME}.timer" 2>/dev/null)" || tactiver="unknown"
        printf 'timer       %s, %s\n' "$tenabled" "$tactiver"
        tline="$(systemctl list-timers --no-pager "${UNIT_NAME}.timer" 2>/dev/null | sed -n '2p')"
        if [ -n "$tline" ]; then
            printf 'schedule    %s\n' "$tline"
        fi
    fi

    status_counts
}

# -----------------------------------------------------------------------------
# --verify: sanity check an encrypted backup, no pg_restore required
# -----------------------------------------------------------------------------
do_verify() {
    local file="$1" size hex identity

    [ -f "$file" ] || die "file not found: ${file}"
    [ -s "$file" ] || die "file is empty: ${file}"

    if ! is_encrypted "$file"; then
        die "not encrypted by this script (missing ${MAGIC} header): ${file}"
    fi

    size="$(wc -c < "$file" | tr -d ' ')"
    hex="$(tail -c "+$(( ${#MAGIC} + 2 ))" "$file" | od -An -tx1 -N4 2>/dev/null | tr -d ' \n' || true)"

    printf 'file        %s\n' "$file"
    printf 'size        %s bytes\n' "$size"
    printf 'header      %s (ok)\n' "$MAGIC"

    case "$hex" in
        5047444d*) printf 'payload     PGDMP - PostgreSQL custom-format dump\n' ;;
        1f8b*)     printf 'payload     gzip - compressed archive (typical for volume backups)\n' ;;
        "")        printf 'payload     could not read (od missing?)\n' ;;
        *)         printf 'payload     unrecognised, first bytes: %s\n' "$hex" ;;
    esac

    identity="${IDENTITY:-$AGE_IDENTITY}"
    if [ -r "$identity" ]; then
        if tail -c "+$(( ${#MAGIC} + 2 ))" "$file" | age --decrypt --identity "$identity" >/dev/null 2>&1; then
            printf 'decrypt     OK with %s\n' "$identity"
            printf '\nVERIFY OK - this file really decrypts with that key.\n'
            return 0
        fi
        die "decryption FAILED with ${identity} - wrong key, or the file is damaged"
    fi

    printf 'decrypt     skipped, no readable private key at %s\n' "$identity"
    printf '\nVERIFY OK - header and payload look right.\n'
    printf 'Run the same command on the machine that holds your private key to prove\n'
    printf 'that the content really decrypts.\n'
    return 0
}

# -----------------------------------------------------------------------------
# --update: replace script + units, never touch config or keys
# -----------------------------------------------------------------------------
fetch_file() { # $1 = url, $2 = destination
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --tlsv1.2 "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        die "need curl or wget to download files"
    fi
}

do_update() {
    local tmp ref="$CBX_REF" new_version old_version f

    tmp="$(mktemp -d)" || die "mktemp failed"
    trap 'rm -rf -- "$tmp"' EXIT

    log "Updating from ${REPO_SLUG} @ ${ref}"

    for f in "${UNIT_NAME}.sh" "${UNIT_NAME}.service" \
             "${UNIT_NAME}.timer" "${UNIT_NAME}-alert.service"; do
        fetch_file "${REPO_RAW_URL}/${ref}/${f}" "${tmp}/${f}" \
            || die "could not download '${f}' at ref '${ref}' - does that ref exist?"
        [ -s "${tmp}/${f}" ] || die "downloaded '${f}' is empty"
    done

    # Never install something that is not even valid bash.
    bash -n "${tmp}/${UNIT_NAME}.sh" || die "downloaded ${UNIT_NAME}.sh is not valid bash - aborted"

    new_version="$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "${tmp}/${UNIT_NAME}.sh" | head -n1)"
    [ -n "$new_version" ] || die "downloaded ${UNIT_NAME}.sh has no SCRIPT_VERSION - aborted"

    old_version="$SCRIPT_VERSION"
    if [ "$new_version" = "$old_version" ] && [ "$FORCE" -ne 1 ]; then
        log "Already at ${old_version} (ref ${ref}). Nothing to do - use --force to reinstall anyway."
        return 0
    fi

    log "Installing ${old_version} -> ${new_version}"

    # Deliberately NOT touching: ${CONF_FILE}, ${AGE_IDENTITY}, ${GRAB_IDENTITY}.
    # An update must never change which key your backups are encrypted to.
    install -m 0755 "${tmp}/${UNIT_NAME}.sh" "$BIN_PATH" \
        || die "cannot write ${BIN_PATH} (are you root?)"
    install -m 0644 "${tmp}/${UNIT_NAME}.service" "${SYSTEMD_DIR}/" \
        || die "cannot write into ${SYSTEMD_DIR}/"
    install -m 0644 "${tmp}/${UNIT_NAME}-alert.service" "${SYSTEMD_DIR}/" \
        || die "cannot write into ${SYSTEMD_DIR}/"
    install -m 0644 "${tmp}/${UNIT_NAME}.timer" "${SYSTEMD_DIR}/" \
        || die "cannot write into ${SYSTEMD_DIR}/"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || warn "systemctl daemon-reload failed"
        if systemctl is-enabled --quiet "${UNIT_NAME}.timer" 2>/dev/null; then
            systemctl restart "${UNIT_NAME}.timer" || warn "could not restart the timer"
        fi
    fi

    log "Updated to ${new_version}. Your config and keys were left untouched."

    if [ -x "$BIN_PATH" ]; then
        "$BIN_PATH" --check-schema || warn "--check-schema failed with the new version, see above"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# --uninstall: remove everything except the backup files
# -----------------------------------------------------------------------------
do_uninstall() {
    local answer=""

    printf '\nThis will remove the backup encryption from this host:\n\n'
    printf '  stop and disable  %s.timer\n' "$UNIT_NAME"
    printf '  remove            %s/%s.service\n' "$SYSTEMD_DIR" "$UNIT_NAME"
    printf '  remove            %s/%s-alert.service\n' "$SYSTEMD_DIR" "$UNIT_NAME"
    printf '  remove            %s/%s.timer\n' "$SYSTEMD_DIR" "$UNIT_NAME"
    printf '  remove            %s\n' "$BIN_PATH"

    if [ "$PURGE" -eq 1 ]; then
        printf '  remove            %s\n' "$CONF_FILE"
        printf '  remove            /etc/%s/\n' "$UNIT_NAME"
    fi

    printf '\nYour backup FILES are not touched. They stay encrypted and can only be\n'
    printf 'read with your private key.\n'

    if [ -f "$GRAB_IDENTITY" ]; then
        printf '\nWARNING: a private key is still on this host:\n'
        printf '         %s\n' "$GRAB_IDENTITY"
        printf '         Move it away (or run --finalize) before you depend on this\n'
        printf '         host being unable to decrypt your backups.\n'
    fi

    if [ "$PURGE" -ne 1 ]; then
        printf '\nThe config and /etc/%s/ will be KEPT. Add --purge to remove them too.\n' "$UNIT_NAME"
    fi

    printf '\nType "yes" to continue: '
    read -r answer || true
    if [ "$answer" != "yes" ]; then
        die "aborted - nothing was removed"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "${UNIT_NAME}.timer" 2>/dev/null || true
    fi

    rm -f -- "${SYSTEMD_DIR}/${UNIT_NAME}.service" \
             "${SYSTEMD_DIR}/${UNIT_NAME}-alert.service" \
             "${SYSTEMD_DIR}/${UNIT_NAME}.timer"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
    fi

    if [ "$PURGE" -eq 1 ]; then
        rm -f -- "$CONF_FILE"
        rm -rf -- "/etc/${UNIT_NAME}"
        log "Removed the config and /etc/${UNIT_NAME}/."
    fi

    log "Removed the systemd units."
    log "Backups stay encrypted. To read one, on the machine that holds the key:"
    log "  tail -c +13 <backup-file> | age --decrypt --identity <your-copy> > restore.dmp"
    log "Reinstall any time with the curl one-liner from the README."

    # Last, because this is the file we are currently running from. On Linux the
    # open file descriptor keeps the rest of the script readable.
    rm -f -- "$BIN_PATH" 2>/dev/null || true
    if [ -n "$SELF_PATH" ] && [ "$SELF_PATH" != "$BIN_PATH" ]; then
        rm -f -- "$SELF_PATH" 2>/dev/null || true
    fi
    return 0
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
    load_db_creds
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

    local rows
    if ! rows="$(fetch_filenames)"; then
        die "database query failed"
    fi

    local total=0 encrypted=0 skipped=0 missing=0 empty=0 outside=0 failed=0 filename
    local missing_list=""
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
            # Not on this host: other server, S3-only backup, or already deleted.
            # Collected, not logged per run - see report_missing.
            missing=$((missing + 1))
            missing_list="${missing_list}${filename}"$'\n'
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

    report_missing "$missing_list"

    local s3_count
    s3_count="$(count_s3_plaintext)"

    # Coolify uploads to S3 before this script ever sees the file, so that copy
    # stays plaintext. Say so, but only when we actually did something.
    if [ "$s3_count" -gt 0 ] 2>/dev/null && { [ "$encrypted" -gt 0 ] || [ "$DRY_RUN" -eq 1 ]; }; then
        warn "${s3_count} backup(s) have s3_uploaded=true - those S3 copies are PLAINTEXT."
        warn "This script only encrypts the local file after Coolify uploaded it."
        warn "See README > 'S3 and offsite copies'."
    fi

    # Stay quiet when there was nothing to do. The timer runs every minute, and a
    # chatty log turns journalctl into noise that hides real errors.
    if [ "$encrypted" -gt 0 ] || [ "$failed" -gt 0 ] || [ "$outside" -gt 0 ] \
        || [ "$empty" -gt 0 ] || [ "$DRY_RUN" -eq 1 ]; then
        log "Done. candidates=${total} encrypted=${encrypted} already=${skipped} empty=${empty} missing=${missing} outside=${outside} failed=${failed}"
    fi

    # A real failure has to reach systemd, otherwise OnFailure never fires and
    # nobody notices that backups silently stopped being encrypted.
    if [ "$failed" -gt 0 ] || [ "$outside" -gt 0 ]; then
        return 1
    fi
    return 0
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
            --status)
                MODE="status"
                ;;
            --update)
                MODE="update"
                ;;
            --uninstall)
                MODE="uninstall"
                ;;
            --purge)
                PURGE=1
                ;;
            --ref)
                shift
                [ "$#" -gt 0 ] || die "usage: $0 --ref BRANCH|TAG|COMMIT"
                CBX_REF="$1"
                ;;
            --identity)
                shift
                [ "$#" -gt 0 ] || die "usage: $0 --identity FILE"
                IDENTITY="$1"
                ;;
            --verify)
                shift
                [ "$#" -gt 0 ] || die "usage: $0 --verify FILE"
                do_verify "$1"
                exit 0
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
        status) do_status ;;
        update) do_update ;;
        uninstall) do_uninstall ;;
        *) run_pass ;;
    esac
}

main "$@"
