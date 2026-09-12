#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install.sh - automated installer for coolify-backup-encrypt (age, public key)
#
# What it does
# ------------
#   1. root / docker / Coolify checks
#   2. installs dependencies (age, util-linux, coreutils)
#   3. installs the main script to /usr/local/bin/
#   4. creates /etc/coolify-backup-encrypt/
#   5. generates an age key pair, private key -> /root/GRAB-ME-BEFORE-DELETE-identity.txt
#   6. writes /etc/coolify-backup-encrypt.conf (age, public key only)
#   7. installs and enables the systemd service + timer
#   8. prints a big warning telling you to copy the key away and then finalize
#
# !! The private key exists on this host until you run:
#        coolify-backup-encrypt.sh --finalize
#    Until then this host CAN decrypt. Copy the key away first, verify it, then finalize.
#
# Usage:
#   ./install.sh                       # generate a new key pair on this host
#   ./install.sh --recipient age1...   # use your own public key, no keypair generated
#   ./install.sh --no-enable           # install only, do not start the timer
#   ./install.sh --force               # rewrite an existing config
#   ./install.sh --help
#
set -Eeuo pipefail

SCRIPT_NAME="coolify-backup-encrypt"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="/usr/local/bin/${SCRIPT_NAME}.sh"
CONF_DIR="/etc/${SCRIPT_NAME}"
CONF="/etc/${SCRIPT_NAME}.conf"
GRAB_IDENTITY="/root/GRAB-ME-BEFORE-DELETE-identity.txt"
SYSTEMD_DIR="/etc/systemd/system"
DB_CONTAINER="coolify-db"
BACKUP_ROOT="/data/coolify/backups"
COOLIFY_ENV_FILE="/data/coolify/source/.env"

RECIPIENT=""
FORCE=0
DO_ENABLE=1
GENERATED_KEYS=0

log() {
    printf '[install] %s\n' "$*"
}

warn() {
    printf '[install] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[install] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --recipient)
            shift
            [ "$#" -gt 0 ] || die "--recipient needs an age1... value"
            RECIPIENT="$1"
            ;;
        --force)
            FORCE=1
            ;;
        --no-enable)
            DO_ENABLE=0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
    shift
done

# -----------------------------------------------------------------------------
# 1. Checks
# -----------------------------------------------------------------------------
log "Checking prerequisites"

[ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0)"

case "$(uname -s)" in
    Linux) : ;;
    *) die "this installer targets Linux (systemd) hosts" ;;
esac

command -v docker >/dev/null 2>&1 || die "docker not found - is this really the Coolify host?"
docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true \
    || die "Coolify database container '${DB_CONTAINER}' is not running"

[ -d "$(dirname "$BACKUP_ROOT")" ] || warn "backup root '${BACKUP_ROOT}' does not exist (yet)"

command -v systemctl >/dev/null 2>&1 || die "systemctl not found - systemd is required"

for f in "${SCRIPT_NAME}.sh" "${SCRIPT_NAME}.service" "${SCRIPT_NAME}.timer" "${SCRIPT_NAME}-alert.service"; do
    [ -f "${SRC_DIR}/${f}" ] || die "missing file next to install.sh: ${f}"
done

log "Checks passed"

# -----------------------------------------------------------------------------
# 2. Dependencies
# -----------------------------------------------------------------------------
need_pkg() {
    command -v "$1" >/dev/null 2>&1 && return 1
    return 0
}

install_deps() {
    local packages=""

    need_pkg age && packages="${packages} age"
    need_pkg flock && packages="${packages} util-linux"
    need_pkg shred && packages="${packages} coreutils"

    if [ -z "$packages" ]; then
        log "Dependencies already present"
        return 0
    fi

    log "Installing:${packages}"

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || die "apt-get update failed"
        # shellcheck disable=SC2086
        apt-get install -y -qq $packages || die "apt-get install failed"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $packages || die "dnf install failed"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $packages || die "yum install failed"
    else
        die "no supported package manager found - install manually:${packages}"
    fi
}

install_deps

command -v age >/dev/null 2>&1 || die "age is still missing after install"
command -v age-keygen >/dev/null 2>&1 || die "age-keygen is still missing after install"
command -v flock >/dev/null 2>&1 || warn "flock is missing - concurrent runs cannot be prevented"

# -----------------------------------------------------------------------------
# 3. Main script
# -----------------------------------------------------------------------------
log "Installing ${BIN}"
install -m 0755 "${SRC_DIR}/${SCRIPT_NAME}.sh" "$BIN"

# -----------------------------------------------------------------------------
# 4. Directories
# -----------------------------------------------------------------------------
install -d -m 0700 "$CONF_DIR"

# -----------------------------------------------------------------------------
# 5. age key pair
# -----------------------------------------------------------------------------
if [ -n "$RECIPIENT" ]; then
    case "$RECIPIENT" in
        age1*) : ;;
        *) die "--recipient must be an age public key (age1...)" ;;
    esac
    log "Using the recipient you provided - no key pair generated on this host"
elif [ -f "$GRAB_IDENTITY" ]; then
    log "Reusing the existing private key at ${GRAB_IDENTITY}"
    chmod 600 "$GRAB_IDENTITY" 2>/dev/null || true
    RECIPIENT="$(age-keygen -y "$GRAB_IDENTITY")" || die "cannot read recipient from ${GRAB_IDENTITY}"
else
    log "Generating an age key pair"
    umask 077
    age-keygen -o "$GRAB_IDENTITY" >/dev/null 2>&1 || die "age-keygen failed"
    chmod 600 "$GRAB_IDENTITY"
    RECIPIENT="$(age-keygen -y "$GRAB_IDENTITY")" || die "cannot read recipient from ${GRAB_IDENTITY}"
    GENERATED_KEYS=1
    log "Private key written to ${GRAB_IDENTITY} (mode 600)"
fi

[ -n "$RECIPIENT" ] || die "no age recipient available"

if [ -f "$GRAB_IDENTITY" ]; then
    if printf 'smoke test\n' | age -r "$RECIPIENT" | age -d -i "$GRAB_IDENTITY" >/dev/null 2>&1; then
        log "Key pair verified (encrypt + decrypt roundtrip OK)"
    else
        die "key pair smoke test failed - refusing to continue"
    fi
fi

# -----------------------------------------------------------------------------
# 6. Config
# -----------------------------------------------------------------------------
write_config() {
    local tmp="${CONF}.tmp.$$"
    cat > "$tmp" <<EOF
# Generated by install.sh on $(date '+%Y-%m-%d %H:%M:%S')
# See README.md. After every Coolify upgrade run:
#   ${SCRIPT_NAME}.sh --check-schema

COOLIFY_ENV_FILE=${COOLIFY_ENV_FILE}
DB_CONTAINER=${DB_CONTAINER}
BACKUP_ROOT=${BACKUP_ROOT}

# The PUBLIC key. This host can only encrypt, never decrypt.
AGE_RECIPIENT=${RECIPIENT}

# Only needed on the machine that holds the private key (for --decrypt):
# AGE_IDENTITY=/path/to/identity.txt

# Used by `--finalize` to remove the bootstrapped private key:
GRAB_IDENTITY=${GRAB_IDENTITY}

GRACE_SECONDS=5
MAGIC=COOLIFYENC1
MAX_LOAD=0
LOCK_FILE=/run/${SCRIPT_NAME}.lock
TMP_MAX_AGE_MINUTES=60
EOF
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$CONF"
    log "Wrote ${CONF} (mode 600)"
}

if [ -f "$CONF" ] && [ "$FORCE" -ne 1 ]; then
    warn "${CONF} already exists and was NOT modified."
    warn "Make sure it contains:"
    warn "    AGE_RECIPIENT=${RECIPIENT}"
    warn "Re-run with --force to overwrite the whole file."
else
    write_config
fi

# -----------------------------------------------------------------------------
# 7. systemd
# -----------------------------------------------------------------------------
log "Installing systemd units"
install -m 0644 "${SRC_DIR}/${SCRIPT_NAME}.service" "$SYSTEMD_DIR/"
install -m 0644 "${SRC_DIR}/${SCRIPT_NAME}-alert.service" "$SYSTEMD_DIR/"
install -m 0644 "${SRC_DIR}/${SCRIPT_NAME}.timer" "$SYSTEMD_DIR/"
systemctl daemon-reload

log "Preflight: ${SCRIPT_NAME}.sh --check-schema"
if "$BIN" --check-schema; then
    log "Preflight OK"
else
    warn "--check-schema FAILED"
    warn "Do not trust this install until it passes. Most likely the Coolify schema"
    warn "differs from the tested version (v4.3.19). See README > Schema dependency."
fi

log "Preflight: ${SCRIPT_NAME}.sh --dry-run"
"$BIN" --dry-run || warn "--dry-run reported problems"

# -----------------------------------------------------------------------------
# 8. Enable the timer, then shout about the private key
# -----------------------------------------------------------------------------
if [ "$DO_ENABLE" -eq 1 ]; then
    systemctl enable --now "${SCRIPT_NAME}.timer" || die "could not enable the timer"
    log "Timer enabled (runs every 10 seconds)"
else
    log "Timer NOT enabled (--no-enable). Enable it later with:"
    log "  systemctl enable --now ${SCRIPT_NAME}.timer"
fi

print_final_warning() {
    local host
    host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo YOUR-SERVER)"

    if [ ! -f "$GRAB_IDENTITY" ]; then
        cat <<EOF

==============================================================================
 Installed with your own public key - there is no private key on this host.
 Decrypt on the machine that holds your key:
   tail -c +13 <backup-file> | age --decrypt --identity <your-copy> > restore.dmp
==============================================================================

EOF
        return 0
    fi

    cat <<EOF

##############################################################################
#
#   DEIN PRIVATER SCHLUESSEL LIEGT HIER:
#
#       ${GRAB_IDENTITY}
#
#   Solange diese Datei existiert, KANN DIESER SERVER ENTSSCHLUESSELN.
#   Das ist nur fuer das Setup gedacht. MACH JETZT FOLGENDES:
#
#   1. Kopiere den Key auf DEINE Maschine (auf den Server gehoert er nicht):
#
#        scp root@${host}:${GRAB_IDENTITY} ./backup-identity.txt
#
#   2. Pruefe LOKAL, dass die Datei den Private Key enthaelt:
#
#        grep -q 'AGE-SECRET-KEY-1' ./backup-identity.txt && echo OK
#
#   3. Speichere sie in Vaultwarden UND auf einem Offline-Medium.
#
#   4. Teste die Kopie mit einer ECHTEN Backup-Datei (auf deiner Maschine):
#
#        tail -c +13 <backup-file> | age --decrypt --identity ./backup-identity.txt > restore.dmp
#        pg_restore --list restore.dmp
#
#   5. Erst wenn das nachweislich funktioniert, den Key vom Server loeschen:
#
#        ${SCRIPT_NAME}.sh --finalize
#
#   --finalize loescht den Private Key vom Server (mit Bestaetigungsabfrage).
#   Ohne Private Key = KEINE WIEDERHERSTELLUNG.
#   Sei dir sicher, dass du eine funktionierende Kopie hast.
#
##############################################################################

  Public recipient auf dem Server: ${RECIPIENT}

  Geht der Private Key verloren, sind ALLE Backups unlesbar. Es gibt keinen
  Recovery-Weg und keine Garantie.

EOF
}

print_final_warning
log "Installation finished"


