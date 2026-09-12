#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Functional self-test for coolify-backup-encrypt.sh
#
# No Coolify, no docker and no root needed: docker/flock are faked and an
# isolated keyring is generated per case. Run it before every release and after
# touching the script:   bash coolify-backup-encrypt.selftest.sh
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$ROOT/coolify-backup-encrypt.sh"
MAGIC="COOLIFYENC1"
FAILED=0
AGE_STUB=0

fail() {
    echo "FAIL: $*"
    FAILED=1
    return 1
}

write_fakes() { # $1 = workdir
    local w="$1"
    mkdir -p "$w/bin"
    cat > "$w/bin/docker" <<'FAKE'
#!/usr/bin/env bash
if [[ "$*" == *inspect* ]]; then echo true; exit 0; fi
if [[ "$*" == *psql* ]]; then
    if [[ "$*" == *information_schema* ]]; then
        for entry in \
            scheduled_database_backup_executions.filename \
            scheduled_database_backup_executions.finished_at \
            scheduled_database_backup_executions.local_storage_deleted \
            scheduled_database_backup_executions.status \
            scheduled_volume_backup_executions.filename \
            scheduled_volume_backup_executions.finished_at \
            scheduled_volume_backup_executions.local_storage_deleted \
            scheduled_volume_backup_executions.status ; do
            [ "${FAKE_SCHEMA_DROP:-}" = "$entry" ] && continue
            echo "$entry"
        done
        exit 0
    fi
    cat "$FAKE_FILENAMES"
    exit 0
fi
echo "unexpected docker call: $*" >&2
exit 1
FAKE
    chmod +x "$w/bin/docker"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$w/bin/flock"
    chmod +x "$w/bin/flock"

    # If the real age is missing, drop in a stub so the plumbing is still
    # exercised. The stub does base64, i.e. NO encryption: it only proves the
    # magic header, temp file + atomic replace, idempotency, --decrypt-to and
    # the header guard. configure_crypt reports which one is in use.
    if ! command -v age >/dev/null 2>&1; then
        cat > "$w/bin/age" <<'FAKE'
#!/usr/bin/env bash
if [[ "$*" == *--decrypt* ]]; then base64 -d; else base64; fi
FAKE
        chmod +x "$w/bin/age"
    fi
}

prepare_work() { # $1 = workdir
    local w="$1" i
    write_fakes "$w"
    for i in $(seq 1 200); do printf 'fake dump line %s\n' "$i"; done > "$w/orig.txt"
    cp "$w/orig.txt" "$w/dump.dmp"
    printf '%s\n' "$w/dump.dmp" > "$w/filenames"
    {
        echo "COOLIFY_ENV_FILE=$w/nonexistent.env"
        echo "DB_CONTAINER=fake"
        echo "BACKUP_ROOT=$w"
        echo "GRACE_SECONDS=0"
        echo "MAX_LOAD=0"
        echo "LOCK_FILE=$w/lock"
        echo "STATE_DIR=$w/state"
        echo "AGE_IDENTITY=$w/no-such-identity.txt"
        echo "SYSTEMD_DIR=$w/systemd"
    } > "$w/conf"
}

# age is the only supported tool. Uses the real age when it is installed,
# otherwise the base64 stub created by write_fakes (AGE_STUB=1).
configure_crypt() { # $1 = workdir
    local w="$1"

    AGE_STUB=0

    if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
        age-keygen -o "$w/agekey.txt" >/dev/null 2>&1 || return 1
        echo "AGE_RECIPIENT=$(age-keygen -y "$w/agekey.txt")" >> "$w/conf"
        echo "AGE_IDENTITY=$w/agekey.txt" >> "$w/conf"
    else
        # Stub mode: the recipient and identity are never validated by the stub.
        echo "AGE_RECIPIENT=age1stubstubstubstubstubstubstubstubstubstubstubstubstubstubstub" >> "$w/conf"
        printf 'AGE-SECRET-KEY-1STUBSTUBSTUBSTUBSTUBSTUBSTUBSTUBSTUBSTUBSTUBSTUBSTUBSTUB\n' > "$w/agekey.txt"
        echo "AGE_IDENTITY=$w/agekey.txt" >> "$w/conf"
        AGE_STUB=1
    fi

    return 0
}

# dry-run -> in-place encrypt -> idempotency -> decrypt roundtrip -> decrypt-to
run_age_case() {
    local w orig_size size1 size2 quiet_out

    w="$(mktemp -d)"
    prepare_work "$w"
    echo "== case: age / public-key =="

    configure_crypt "$w"

    if [ "$AGE_STUB" -eq 1 ]; then
        echo "   [stub] age not installed here - plumbing only, no real crypto"
    fi

    PATH="$w/bin:$PATH"
    FAKE_FILENAMES="$w/filenames"
    CONF_FILE="$w/conf"
    unset FAKE_SCHEMA_DROP 2>/dev/null || true
    export PATH FAKE_FILENAMES CONF_FILE

    bash "$SCRIPT" --check-schema >"$w/check.log" 2>&1
    if [ $? -ne 0 ]; then
        fail "--check-schema failed: $(cat "$w/check.log")"
        rm -rf "$w"
        return 1
    fi

    orig_size="$(wc -c < "$w/dump.dmp")"
    bash "$SCRIPT" --dry-run >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        fail "dry-run errored"
        rm -rf "$w"
        return 1
    fi
    if [ "$(wc -c < "$w/dump.dmp")" != "$orig_size" ]; then
        fail "dry-run changed the file"
        rm -rf "$w"
        return 1
    fi

    bash "$SCRIPT" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        fail "encryption pass errored"
        rm -rf "$w"
        return 1
    fi
    if [ "$(head -c "${#MAGIC}" "$w/dump.dmp")" != "$MAGIC" ]; then
        fail "magic header missing after encryption"
        rm -rf "$w"
        return 1
    fi
    if grep -aq 'fake dump line 1' "$w/dump.dmp"; then
        fail "plaintext still present after encryption"
        rm -rf "$w"
        return 1
    fi

    size1="$(wc -c < "$w/dump.dmp")"
    quiet_out="$(bash "$SCRIPT" 2>&1)"
    size2="$(wc -c < "$w/dump.dmp")"
    if [ "$size1" != "$size2" ]; then
        fail "not idempotent (file changed on the second run)"
        rm -rf "$w"
        return 1
    fi
    if [ -n "$quiet_out" ]; then
        fail "a pass with nothing to do was not silent (journal spam): ${quiet_out}"
        rm -rf "$w"
        return 1
    fi

    bash "$SCRIPT" --decrypt "$w/dump.dmp" > "$w/out1.txt" 2>/dev/null
    if ! diff -q "$w/out1.txt" "$w/orig.txt" >/dev/null 2>&1; then
        fail "--decrypt roundtrip differs from the original"
        rm -rf "$w"
        return 1
    fi

    bash "$SCRIPT" --decrypt-to "$w/out2.txt" "$w/dump.dmp" >/dev/null 2>&1
    if ! diff -q "$w/out2.txt" "$w/orig.txt" >/dev/null 2>&1; then
        fail "--decrypt-to roundtrip differs from the original"
        rm -rf "$w"
        return 1
    fi

    if bash "$SCRIPT" --decrypt-to "$w/out2.txt" "$w/dump.dmp" >/dev/null 2>&1; then
        fail "--decrypt-to overwrote an existing file without --force"
        rm -rf "$w"
        return 1
    fi

    bash "$SCRIPT" --force --decrypt-to "$w/out2.txt" "$w/dump.dmp" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        fail "--force --decrypt-to failed"
        rm -rf "$w"
        return 1
    fi

    printf 'not encrypted\n' > "$w/plain.dmp"
    if bash "$SCRIPT" --decrypt-to "$w/should-not-exist.out" "$w/plain.dmp" >/dev/null 2>&1; then
        fail "--decrypt-to accepted a file without the magic header"
        rm -rf "$w"
        return 1
    fi

    echo "   PASS (check-schema, dry-run, in-place, idempotent, decrypt, decrypt-to, force, header guard)"
    rm -rf "$w"
    return 0
}

# The whole point of the guard: a Coolify schema change must be LOUD.
run_schema_guard_case() {
    local w before

    w="$(mktemp -d)"
    prepare_work "$w"
    echo "== case: schema guard (column removed by a Coolify upgrade) =="

    configure_crypt "$w"

    PATH="$w/bin:$PATH"
    FAKE_FILENAMES="$w/filenames"
    FAKE_SCHEMA_DROP="scheduled_volume_backup_executions.filename"
    CONF_FILE="$w/conf"
    export PATH FAKE_FILENAMES CONF_FILE FAKE_SCHEMA_DROP

    before="$(wc -c < "$w/dump.dmp")"

    bash "$SCRIPT" --check-schema >"$w/check.log" 2>&1
    if [ $? -eq 0 ]; then
        fail "--check-schema did not fail on a changed schema"
        unset FAKE_SCHEMA_DROP
        rm -rf "$w"
        return 1
    fi
    if ! grep -q 'scheduled_volume_backup_executions.filename' "$w/check.log"; then
        fail "--check-schema did not name the missing column"
        unset FAKE_SCHEMA_DROP
        rm -rf "$w"
        return 1
    fi

    bash "$SCRIPT" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        fail "encryption pass did not fail on a changed schema"
        unset FAKE_SCHEMA_DROP
        rm -rf "$w"
        return 1
    fi
    if [ "$(wc -c < "$w/dump.dmp")" != "$before" ]; then
        fail "file was modified even though the schema check failed"
        unset FAKE_SCHEMA_DROP
        rm -rf "$w"
        return 1
    fi

    echo "   PASS (fails loudly, names the missing column, touches nothing)"
    unset FAKE_SCHEMA_DROP
    rm -rf "$w"
    return 0
}

run_cleanup_case() {
    local w

    w="$(mktemp -d)"
    prepare_work "$w"
    echo "== case: --cleanup-tmp =="

    PATH="$w/bin:$PATH"
    FAKE_FILENAMES="$w/filenames"
    CONF_FILE="$w/conf"
    export PATH FAKE_FILENAMES CONF_FILE

    echo "leftover" > "$w/stranded.dmp.tmp.1234"
    echo "recent" > "$w/fresh.dmp.tmp.9999"

    bash "$SCRIPT" --cleanup-tmp >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        fail "--cleanup-tmp errored"
        rm -rf "$w"
        return 1
    fi
    if [ ! -f "$w/fresh.dmp.tmp.9999" ]; then
        fail "--cleanup-tmp removed a file younger than the threshold"
        rm -rf "$w"
        return 1
    fi

    if touch -d '3 hours ago' "$w/stranded.dmp.tmp.1234" 2>/dev/null; then
        bash "$SCRIPT" --cleanup-tmp >/dev/null 2>&1
        if [ -f "$w/stranded.dmp.tmp.1234" ]; then
            fail "--cleanup-tmp did not remove an old orphaned temp file"
            rm -rf "$w"
            return 1
        fi
        echo "   PASS (old orphan removed, recent file kept)"
    else
        echo "   PASS (recent file kept; touch -d unsupported, old-file check skipped)"
    fi

    rm -rf "$w"
    return 0
}

# Files that live on another server must be reported once, not on every pass.
run_missing_dedupe_case() {
    local w out1 out2

    w="$(mktemp -d)"
    prepare_work "$w"
    echo "== case: missing files are reported once, not every pass =="
    configure_crypt "$w"

    printf '%s\n%s\n' "$w/dump.dmp" "$w/gone.dmp" > "$w/filenames"

    PATH="$w/bin:$PATH"
    FAKE_FILENAMES="$w/filenames"
    CONF_FILE="$w/conf"
    export PATH FAKE_FILENAMES CONF_FILE

    out1="$(bash "$SCRIPT" 2>&1)"
    out2="$(bash "$SCRIPT" 2>&1)"

    if ! printf '%s' "$out1" | grep -q 'NOT ON THIS HOST'; then
        fail "first pass did not report the file that is not on this host"
        rm -rf "$w"
        return 1
    fi
    if printf '%s' "$out2" | grep -q 'NOT ON THIS HOST'; then
        fail "second pass reported it again - that is the journal spam we removed"
        rm -rf "$w"
        return 1
    fi

    echo "   PASS (reported once, silent afterwards)"
    rm -rf "$w"
    return 0
}

# A real failure has to reach systemd, otherwise OnFailure never fires.
run_failure_exit_case() {
    local w rc

    w="$(mktemp -d)"
    prepare_work "$w"
    echo "== case: a path outside BACKUP_ROOT fails the run =="
    configure_crypt "$w"

    printf '%s\n' "/tmp/definitely-not-a-backup-root/evil.dmp" > "$w/filenames"

    PATH="$w/bin:$PATH"
    FAKE_FILENAMES="$w/filenames"
    CONF_FILE="$w/conf"
    export PATH FAKE_FILENAMES CONF_FILE

    bash "$SCRIPT" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "a path outside BACKUP_ROOT exited 0 - OnFailure would never fire"
        rm -rf "$w"
        return 1
    fi

    echo "   PASS (exit ${rc}, visible to systemd)"
    rm -rf "$w"
    return 0
}

run_verify_case() {
    local w rc stub recipient

    w="$(mktemp -d)"
    prepare_work "$w"
    echo "== case: --verify =="
    configure_crypt "$w"
    stub="$AGE_STUB"

    # Point AGE_IDENTITY at nothing so the container checks are deterministic:
    # --verify must be able to judge a file without having a key at all.
    echo "AGE_IDENTITY=$w/no-such-identity.txt" >> "$w/conf"

    PATH="$w/bin:$PATH"
    CONF_FILE="$w/conf"
    export PATH CONF_FILE

    { printf '%s\n' "$MAGIC"; printf 'PGDMP\000\001\002\003payload'; } > "$w/pg.dmp"

    bash "$SCRIPT" --verify "$w/pg.dmp" > "$w/ok.log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "--verify rejected a file with a valid header (exit ${rc}): $(cat "$w/ok.log")"
        rm -rf "$w"
        return 1
    fi
    if ! grep -q 'PGDMP' "$w/ok.log"; then
        fail "--verify did not recognise the PGDMP payload"
        rm -rf "$w"
        return 1
    fi

    printf 'not encrypted\n' > "$w/plain.dmp"
    if bash "$SCRIPT" --verify "$w/plain.dmp" >/dev/null 2>&1; then
        fail "--verify accepted a file without the magic header"
        rm -rf "$w"
        return 1
    fi

    if bash "$SCRIPT" --verify "$w/does-not-exist" >/dev/null 2>&1; then
        fail "--verify accepted a file that does not exist"
        rm -rf "$w"
        return 1
    fi

    if [ "$stub" -eq 0 ]; then
        # Real crypto available: prove --verify actually decrypts, and that it
        # fails with the wrong key. This is the claim the whole flag rests on.
        recipient="$(sed -n 's/^AGE_RECIPIENT=//p' "$w/conf" | head -n1)"
        printf 'PGDMP\000\001\002\003real payload\n' > "$w/body.dmp"
        { printf '%s\n' "$MAGIC"; age --encrypt --recipient "$recipient" < "$w/body.dmp"; } > "$w/real.enc"

        bash "$SCRIPT" --verify "$w/real.enc" --identity "$w/agekey.txt" > "$w/real.log" 2>&1
        if [ $? -ne 0 ]; then
            fail "--verify failed on a file encrypted with the matching key: $(cat "$w/real.log")"
            rm -rf "$w"
            return 1
        fi

        if bash "$SCRIPT" --verify "$w/real.enc" --identity "$w/pg.dmp" >/dev/null 2>&1; then
            fail "--verify claimed success with a wrong identity"
            rm -rf "$w"
            return 1
        fi

        echo "   PASS (PGDMP detected, header+existence checked, real decrypt OK, wrong key rejected)"
    else
        echo "   PASS (PGDMP detected, header and existence checked; real decrypt needs age)"
    fi

    rm -rf "$w"
    return 0
}

run_cli_case() {
    echo "== case: --help / --version =="

    bash "$SCRIPT" --help >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        fail "--help exited non-zero"
        return 1
    fi

    if ! bash "$SCRIPT" --version 2>/dev/null | grep -q 'coolify-backup-encrypt 1'; then
        fail "--version did not print the script version"
        return 1
    fi

    if bash "$SCRIPT" --definitely-not-an-option >/dev/null 2>&1; then
        fail "an unknown option was accepted"
        return 1
    fi

    echo "   PASS"
    return 0
}

run_finalize_case() {
    local w

    w="$(mktemp -d)"
    prepare_work "$w"
    echo "== case: --finalize =="

    printf 'AGE-SECRET-KEY-1FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE\n' > "$w/grab-identity.txt"
    chmod 600 "$w/grab-identity.txt" 2>/dev/null || true
    echo "GRAB_IDENTITY=$w/grab-identity.txt" >> "$w/conf"

    PATH="$w/bin:$PATH"
    FAKE_FILENAMES="$w/filenames"
    CONF_FILE="$w/conf"
    export PATH FAKE_FILENAMES CONF_FILE

    printf 'nein\n' | bash "$SCRIPT" --finalize >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        fail "--finalize accepted a wrong confirmation"
        rm -rf "$w"
        return 1
    fi
    if [ ! -f "$w/grab-identity.txt" ]; then
        fail "--finalize deleted the key without confirmation"
        rm -rf "$w"
        return 1
    fi

    printf 'ja\n' | bash "$SCRIPT" --finalize >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        fail "--finalize failed with a correct confirmation"
        rm -rf "$w"
        return 1
    fi
    if [ -e "$w/grab-identity.txt" ]; then
        fail "--finalize did not delete the private key"
        rm -rf "$w"
        return 1
    fi

    bash "$SCRIPT" --finalize >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        fail "--finalize succeeded although there was no pending key"
        rm -rf "$w"
        return 1
    fi

    echo "   PASS (aborts without 'ja', deletes with 'ja', no-op when already finalized)"
    rm -rf "$w"
    return 0
}

run_cli_case
run_age_case
run_schema_guard_case
run_cleanup_case
run_finalize_case
run_verify_case
run_failure_exit_case
run_missing_dedupe_case

if [ "$FAILED" -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "SOME TESTS FAILED"
    exit 1
fi
