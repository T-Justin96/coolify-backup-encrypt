#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install.sh - automated installer for coolify-backup-encrypt (age, public key)
#
# One command, no checkout needed:
#
#   curl -fsSL https://raw.githubusercontent.com/T-Justin96/coolify-backup-encrypt/main/install.sh | sudo bash
#
# Run standalone it downloads the remaining files from the repository; run from a
# git clone it simply uses the files sitting next to this script.
#
# What it does
# ------------
#   1. root / docker / Coolify checks
#   2. fetches the remaining files (only when run standalone)
#   3. installs dependencies (age, util-linux, coreutils)
#   4. decides which key to use. If that is ambiguous it asks you, with a safe
#      default, BEFORE anything is written. It never silently replaces a key
#      that existing backups were encrypted with.
#   5. creates and verifies the key pair (only if step 4 decided to)
#   6. installs the main script to /usr/local/bin/
#   7. creates /etc/coolify-backup-encrypt/
#   8. writes /etc/coolify-backup-encrypt.conf (age, public key only)
#   9. installs and enables the systemd service + timer
#  10. prints where everything is and what to do next
#
# !! The private key exists on this host until you run:
#        coolify-backup-encrypt.sh --finalize
#    Until then this host CAN decrypt. Copy the key away first, verify it, then finalize.
#
# Usage:
#   ./install.sh                       # generate a new key pair on this host
#   ./install.sh --recipient age1...   # use your own public key, no keypair generated
#   ./install.sh --keep-key            # keep the recipient already in the config
#   ./install.sh --new-key             # deliberately start over with a new key pair
#   ./install.sh --no-prompt           # never ask; fail instead (for scripts)
#   ./install.sh --no-enable           # install only, do not start the timer
#   ./install.sh --force               # overwrite an existing config
#   ./install.sh --ref v1.2.1          # pull this git ref instead of main
#   ./install.sh --help
#
# Every option also works through the pipe:
#   curl -fsSL <url> | sudo bash -s -- --keep-key
#
# If the key situation is ambiguous and there is a terminal, the installer asks
# instead of guessing. Without a terminal it refuses and prints what to pass.
#
set -Eeuo pipefail

SCRIPT_NAME="coolify-backup-encrypt"
REPO_SLUG="T-Justin96/coolify-backup-encrypt"
REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/${REPO_SLUG}}"
CBX_REF="${CBX_REF:-main}"

# Where do our own files live? When this script is piped into bash there is no
# usable $0, which is exactly the standalone (curl | bash) case.
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -r "$SELF" ]; then
    SRC_DIR="$(cd "$(dirname "$SELF")" && pwd)"
else
    SRC_DIR=""
fi

# Overridable so the self-test can point them at a scratch directory.
BIN="${BIN:-/usr/local/bin/${SCRIPT_NAME}.sh}"
CONF_DIR="${CONF_DIR:-/etc/${SCRIPT_NAME}}"
CONF="${CONF:-/etc/${SCRIPT_NAME}.conf}"
GRAB_IDENTITY="${GRAB_IDENTITY:-/root/GRAB-ME-BEFORE-DELETE-identity.txt}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
DB_CONTAINER="${DB_CONTAINER:-coolify-db}"
BACKUP_ROOT="${BACKUP_ROOT:-/data/coolify/backups}"
COOLIFY_ENV_FILE="${COOLIFY_ENV_FILE:-/data/coolify/source/.env}"

RECIPIENT=""
FORCE=0
DO_ENABLE=1
GENERATED_KEYS=0
KEEP_KEY=0
NEW_KEY=0
NO_PROMPT=0

# A ready-to-paste way to run this installer again, whichever way it was started.
# Using $0 here would print "bash" when the script came from a pipe.
if [ -n "$SRC_DIR" ] && [ -r "${SRC_DIR}/install.sh" ]; then
    SELF_CMD="sudo bash $(printf '%q' "${SRC_DIR}/install.sh")"
else
    SELF_CMD="curl -fsSL ${REPO_RAW_URL}/${CBX_REF}/install.sh | sudo bash -s --"
fi

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
    cat <<'EOF'
Install coolify-backup-encrypt (age, public key only) on a Coolify host.

Usage:
  ./install.sh                       generate a new key pair on this host
  ./install.sh --recipient age1...   use your own public key, no keypair generated
  ./install.sh --keep-key            keep the recipient already in the config
  ./install.sh --new-key             deliberately start over with a new key pair
  ./install.sh --no-prompt           never ask; fail instead (for scripts)
  ./install.sh --no-enable           install only, do not start the timer
  ./install.sh --force               overwrite an existing config
  ./install.sh --ref v1.2.1          pull this git ref instead of main
  ./install.sh --help

Standalone (no checkout needed):
  curl -fsSL https://raw.githubusercontent.com/T-Justin96/coolify-backup-encrypt/main/install.sh | sudo bash

  Every option also works through the pipe - note the "-s --":
  curl -fsSL <url> | sudo bash -s -- --keep-key

If the key situation is ambiguous the installer asks, with a safe default, and
without a terminal it refuses instead of guessing.

Standalone mode downloads coolify-backup-encrypt.sh and the systemd units from
the repository. Read the downstream script before piping anything into root.
EOF
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
        --keep-key)
            KEEP_KEY=1
            ;;
        --new-key)
            NEW_KEY=1
            ;;
        --no-prompt)
            NO_PROMPT=1
            ;;
        --force)
            FORCE=1
            ;;
        --no-enable)
            DO_ENABLE=0
            ;;
        --ref)
            shift
            [ "$#" -gt 0 ] || die "--ref needs a git ref (branch, tag or commit)"
            CBX_REF="$1"
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
    shift
done

if [ "$KEEP_KEY" -eq 1 ] && [ "$NEW_KEY" -eq 1 ]; then
    die "--keep-key and --new-key contradict each other"
fi
if [ -n "$RECIPIENT" ] && { [ "$KEEP_KEY" -eq 1 ] || [ "$NEW_KEY" -eq 1 ]; }; then
    die "--recipient cannot be combined with --keep-key or --new-key"
fi

# -----------------------------------------------------------------------------
# 1. Checks
# -----------------------------------------------------------------------------
log "Checking prerequisites"

[ "$(id -u)" -eq 0 ] || die "must run as root. Try: ${SELF_CMD}"

case "$(uname -s)" in
    Linux) : ;;
    *) die "this installer targets Linux (systemd) hosts" ;;
esac

command -v docker >/dev/null 2>&1 || die "docker not found - is this really the Coolify host?"
docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true \
    || die "Coolify database container '${DB_CONTAINER}' is not running"

[ -d "$(dirname "$BACKUP_ROOT")" ] || warn "backup root '${BACKUP_ROOT}' does not exist (yet)"

command -v systemctl >/dev/null 2>&1 || die "systemctl not found - systemd is required"

log "Checks passed"

# -----------------------------------------------------------------------------
# 2. Source files (downloaded when this script is run standalone)
# -----------------------------------------------------------------------------
REQUIRED_FILES="${SCRIPT_NAME}.sh ${SCRIPT_NAME}.service ${SCRIPT_NAME}.timer ${SCRIPT_NAME}-alert.service"

fetch_file() { # $1 = file name, $2 = destination
    local name="$1" dest="$2" url="${REPO_RAW_URL}/${CBX_REF}/${1}"

    log "Downloading ${name} (${CBX_REF})"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$dest" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url" || return 1
    else
        die "need curl or wget to download ${name}"
    fi

    [ -s "$dest" ] || return 1
    return 0
}

resolve_sources() {
    local f have_all=1

    if [ -n "$SRC_DIR" ]; then
        for f in $REQUIRED_FILES; do
            [ -f "${SRC_DIR}/${f}" ] || have_all=0
        done
    else
        have_all=0
    fi

    if [ "$have_all" -eq 1 ]; then
        log "Using the files next to install.sh (${SRC_DIR})"
        return 0
    fi

    log "Standalone mode: not a checkout, fetching ${REPO_SLUG} @ ${CBX_REF}"
    SRC_DIR="$(mktemp -d)" || die "mktemp failed"
    trap 'rm -rf -- "$SRC_DIR"' EXIT

    for f in $REQUIRED_FILES; do
        fetch_file "$f" "${SRC_DIR}/${f}" \
            || die "could not download '${f}' from ${REPO_RAW_URL}/${CBX_REF}/"
    done

    # Never install something that is not even valid bash.
    bash -n "${SRC_DIR}/${SCRIPT_NAME}.sh" || die "downloaded ${SCRIPT_NAME}.sh is not valid bash"

    log "Source files ready"
}

resolve_sources

# -----------------------------------------------------------------------------
# 3. Dependencies
# -----------------------------------------------------------------------------
need_pkg() {
    command -v "$1" >/dev/null 2>&1 && return 1
    return 0
}

install_deps() {
    local packages="" apt_log=""

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
        # Keep needrestart from interrupting or printing a scan report.
        export NEEDRESTART_MODE=a
        export NEEDRESTART_SUSPEND=1

        apt_log="$(mktemp 2>/dev/null || echo /dev/null)"
        # Not fatal: with a stale index apt can still install from the cache.
        if ! apt-get update -qq 2>"$apt_log"; then
            warn "apt-get update did not fully succeed, trying to install anyway"
            if grep -q "could not create temporary file\|Couldn't create temporary file" "$apt_log" 2>/dev/null; then
                warn "apt cannot create temporary files in /tmp - that is a problem with THIS HOST,"
                warn "not with this installer. Check with:"
                warn "  df -h /tmp / ; df -i /tmp / ; ls -ld /tmp ; mount | grep -w /tmp"
            fi
        fi
        rm -f -- "$apt_log"

        # shellcheck disable=SC2086
        apt-get install -y -qq $packages || die "apt-get install failed for:${packages}"
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
# 4. Decide which key to use
# -----------------------------------------------------------------------------
# Nothing is written to disk before this is settled, so an abort - including a
# "no" at the prompt - leaves the host exactly as it was.

# Reading from stdin would eat the installer itself when it arrived through a
# pipe (`curl ... | sudo bash`), so prompts must use the controlling terminal.
can_prompt() {
    if [ "$NO_PROMPT" -eq 1 ]; then
        return 1
    fi
    { : < /dev/tty; } 2>/dev/null
}

ask_choice() { # $1 = question, $2 = default answer
    local answer=""
    printf '%s' "$1" > /dev/tty
    read -r answer < /dev/tty || true
    [ -n "$answer" ] || answer="$2"
    printf '%s' "$answer"
}

# Updates only the AGE_RECIPIENT line, keeping every other change you made.
set_config_recipient() {
    local tmp="${CONF}.tmp.$$"
    if grep -q '^AGE_RECIPIENT=' "$CONF" 2>/dev/null; then
        sed "s|^AGE_RECIPIENT=.*|AGE_RECIPIENT=${RECIPIENT}|" "$CONF" > "$tmp" \
            || die "cannot rewrite ${CONF}"
    else
        cat "$CONF" > "$tmp" || die "cannot read ${CONF}"
        printf 'AGE_RECIPIENT=%s\n' "$RECIPIENT" >> "$tmp"
    fi
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$CONF"
    log "Updated AGE_RECIPIENT in ${CONF} (everything else kept)."
}

choose_new_key() { # $1 = why
    log "Starting over with a new key pair (${1})"
    warn "Backups encrypted with the previous recipient can never be read again."
    KEY_MODE="generate"
    NEED_KEYGEN=1
    VERIFY_KEYPAIR=1
    UPDATE_CONFIG_RECIPIENT=1
}

die_ambiguous() { # $1 = recipient already configured
    cat >&2 <<EOF

[install] ERROR: refusing to guess - guessing here risks your backups.

  ${CONF} already encrypts to:

      ${1}

  Pick one on the command line. Nothing has been changed yet.

    keep that key, change nothing about encryption:

        ${SELF_CMD} --keep-key

    generate a new key pair and update the config
    (backups encrypted with the key above become UNREADABLE):

        ${SELF_CMD} --new-key

    use a public key you keep somewhere else:

        ${SELF_CMD} --recipient age1...

EOF
    exit 1
}

resolve_key() { # $1 = recipient in the config, $2 = recipient of the key on this host
    local configured="$1" onhost="$2" answer=""

    if [ -n "$RECIPIENT" ]; then
        case "$RECIPIENT" in
            age1*) : ;;
            *) die "--recipient must be an age public key (age1...)" ;;
        esac
        log "Using the recipient you provided - no key pair generated on this host"
        KEY_MODE="given"
        return 0
    fi

    # A key that matches (or a host with no config yet): just use it.
    if [ -n "$onhost" ] && { [ -z "$configured" ] || [ "$onhost" = "$configured" ]; }; then
        RECIPIENT="$onhost"
        KEY_MODE="reuse"
        VERIFY_KEYPAIR=1
        log "Reusing the private key already on this host"
        return 0
    fi

    # Nothing configured, nothing on the host: a plain fresh install.
    if [ -z "$configured" ]; then
        choose_new_key "nothing configured yet"
        return 0
    fi

    if [ "$KEEP_KEY" -eq 1 ]; then
        RECIPIENT="$configured"
        KEY_MODE="reuse"
        log "Keeping the recipient already configured (--keep-key)"
        if [ -n "$onhost" ]; then
            warn "The private key at ${GRAB_IDENTITY} does not match it and is useless"
            warn "for these backups. Delete it once you are sure you hold the right key."
        fi
        return 0
    fi
    if [ "$NEW_KEY" -eq 1 ]; then
        choose_new_key "you asked for --new-key"
        return 0
    fi

    if ! can_prompt; then
        die_ambiguous "$configured"
    fi

    if [ -n "$onhost" ]; then
        cat > /dev/tty <<EOF

  Careful - two different keys are in play:

      config says:          ${configured}
      key on this host is:  ${onhost}

  Backups encrypted with the config key can only be read with ITS private key.

    a) keep the key from the config                          [default]
       the private key on this host does not match it and is useless
    b) use the key that is on this host and update the config
       backups encrypted with the config key become UNREADABLE

EOF
        answer="$(ask_choice '  Choose [a/b] (enter = a): ' a)"
        case "$answer" in
            a|A)
                RECIPIENT="$configured"
                KEY_MODE="reuse"
                log "Keeping the config recipient. The key on this host does not match it."
                ;;
            b|B)
                RECIPIENT="$onhost"
                KEY_MODE="reuse"
                VERIFY_KEYPAIR=1
                UPDATE_CONFIG_RECIPIENT=1
                log "Using the key that is on this host and updating the config."
                ;;
            *)
                die "not a valid choice - nothing was changed"
                ;;
        esac
        return 0
    fi

    cat > /dev/tty <<EOF

  ${CONF} already encrypts to:

      ${configured}

  There is no private key on this host. What should happen?

    a) keep that key, change nothing about encryption         [default]
    b) GENERATE A NEW KEY PAIR
       every backup encrypted with the key above becomes UNREADABLE

EOF
    answer="$(ask_choice '  Choose [a/b] (enter = a): ' a)"
    case "$answer" in
        a|A)
            RECIPIENT="$configured"
            KEY_MODE="reuse"
            log "Keeping the recipient already configured"
            ;;
        b|B)
            choose_new_key "you chose b"
            ;;
        *)
            die "not a valid choice - nothing was changed"
            ;;
    esac
}

KEY_MODE=""
NEED_KEYGEN=0
VERIFY_KEYPAIR=0
UPDATE_CONFIG_RECIPIENT=0

configured_recipient=""
if [ -f "$CONF" ]; then
    configured_recipient="$(sed -n 's/^AGE_RECIPIENT=//p' "$CONF" | head -n1)"
fi

grab_recipient=""
if [ -f "$GRAB_IDENTITY" ]; then
    chmod 600 "$GRAB_IDENTITY" 2>/dev/null || true
    grab_recipient="$(age-keygen -y "$GRAB_IDENTITY" 2>/dev/null || true)"
    if [ -z "$grab_recipient" ]; then
        die "cannot read a recipient out of ${GRAB_IDENTITY} - move it away and start again"
    fi
fi

resolve_key "$configured_recipient" "$grab_recipient"

# -----------------------------------------------------------------------------
# 5. Create and verify the key pair, if that is what we decided
# -----------------------------------------------------------------------------
if [ "$NEED_KEYGEN" -eq 1 ]; then
    umask 077
    age-keygen -o "$GRAB_IDENTITY" >/dev/null 2>&1 || die "age-keygen failed"
    chmod 600 "$GRAB_IDENTITY"
    RECIPIENT="$(age-keygen -y "$GRAB_IDENTITY")" || die "cannot read recipient from ${GRAB_IDENTITY}"
    GENERATED_KEYS=1
    log "Private key written to ${GRAB_IDENTITY} (mode 600)"
fi

[ -n "$RECIPIENT" ] || die "no age recipient available"

if [ "$VERIFY_KEYPAIR" -eq 1 ]; then
    if printf 'smoke test\n' | age -r "$RECIPIENT" | age -d -i "$GRAB_IDENTITY" >/dev/null 2>&1; then
        log "Key pair verified (encrypt + decrypt roundtrip OK)"
    else
        if [ "$NEED_KEYGEN" -eq 1 ]; then
            rm -f -- "$GRAB_IDENTITY"
        fi
        die "key pair smoke test failed - refusing to continue"
    fi
fi

# -----------------------------------------------------------------------------
# 6. Main script
# -----------------------------------------------------------------------------
log "Installing ${BIN}"
install -m 0755 "${SRC_DIR}/${SCRIPT_NAME}.sh" "$BIN" \
    || die "cannot write ${BIN} (are you root?)"

# -----------------------------------------------------------------------------
# 7. Directories
# -----------------------------------------------------------------------------
install -d -m 0700 "$CONF_DIR"

# -----------------------------------------------------------------------------
# 8. Config
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

# Used by the --finalize option to remove the bootstrapped private key:
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
    if [ "$UPDATE_CONFIG_RECIPIENT" -eq 1 ]; then
        set_config_recipient
    fi
else
    write_config
fi

# -----------------------------------------------------------------------------
# 9. systemd
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
# 10. Enable the timer, then shout about the private key
# -----------------------------------------------------------------------------
if [ "$DO_ENABLE" -eq 1 ]; then
    systemctl enable --now "${SCRIPT_NAME}.timer" || die "could not enable the timer"
    log "Timer enabled (runs every 10 seconds)"
else
    log "Timer NOT enabled (--no-enable). Enable it later with:"
    log "  systemctl enable --now ${SCRIPT_NAME}.timer"
fi

# Shows where the installed pieces live and how to look at them. This is what
# people actually need right after an install.
print_paths_and_checks() {
    cat <<EOF

 Where things live
 -----------------
   ${BIN}
       the script itself - run "${SCRIPT_NAME}.sh --help" for all options
   ${CONF}
       configuration (mode 600)
   /etc/systemd/system/${SCRIPT_NAME}.timer
       runs one encryption pass every 10 seconds

 Check on it
 -----------
   ${SCRIPT_NAME}.sh --status                    everything at a glance
   journalctl -u ${SCRIPT_NAME}.service -n 30    recent runs (silent when idle)
   ${SCRIPT_NAME}.sh --dry-run                   show what would be encrypted
   ${SCRIPT_NAME}.sh --check-schema              after every Coolify upgrade
   systemctl --failed                            did anything break?

 Maintain it
 -----------
   ${SCRIPT_NAME}.sh --update                    newest script + units, keeps config/keys
   ${SCRIPT_NAME}.sh --uninstall                 remove it all (backup files are kept)

 Documentation: https://github.com/${REPO_SLUG}

EOF
}

print_final_warning() {
    local host
    # Short host name on purpose: the fully qualified name would put your
    # domain into terminal logs and issue reports.
    host="$(hostname 2>/dev/null || echo YOUR-SERVER)"

    if [ ! -f "$GRAB_IDENTITY" ]; then
        cat <<EOF

==============================================================================
 INSTALLED - nothing left to do.

 You supplied your own public key, so there is no private key on this host.
 Encrypting happens automatically from now on.

 Decrypt on the machine that holds your key:
   tail -c +13 <backup-file> | age --decrypt --identity <your-copy> > restore.dmp

 Public recipient in use: ${RECIPIENT}
==============================================================================
EOF
        print_paths_and_checks
        return 0
    fi

    cat <<EOF

==============================================================================
 INSTALLED - but one thing is still open.
==============================================================================

 Encrypting already works: the timer below runs every 10 seconds, so every
 finished Coolify backup gets encrypted on its own from now on.

 What is NOT done: the private key still sits on this server at

     ${GRAB_IDENTITY}

 which means THIS HOST COULD DECRYPT YOUR BACKUPS. That is only meant to be
 temporary. Five steps close it:

   1. Copy the private key to YOUR machine, not the server:

        scp root@${host}:${GRAB_IDENTITY} ./backup-identity.txt

   2. Verify you actually got a private key:

        grep -q 'AGE-SECRET-KEY-1' ./backup-identity.txt && echo OK

   3. Store it in a password manager AND on an offline medium.

   4. Prove the copy works, with a real backup file, on your machine:

        tail -c +13 <backup-file> | age --decrypt --identity ./backup-identity.txt > restore.dmp
        head -c 5 restore.dmp        # must print: PGDMP

      No pg_restore needed. If the script is on that machine too:

        ${SCRIPT_NAME}.sh --verify <backup-file> --identity ./backup-identity.txt

   5. Only once step 4 works, delete the key from this server:

        ${SCRIPT_NAME}.sh --finalize

 Lose the private key and every backup becomes unreadable. There is no
 recovery path and no warranty - so do not skip step 4.

 Public recipient in use: ${RECIPIENT}
==============================================================================
EOF

    print_paths_and_checks
}

print_final_warning
log "Installation finished"


