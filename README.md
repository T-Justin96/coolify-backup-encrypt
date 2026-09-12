# coolify-backup-encrypt

Encrypts [Coolify](https://coolify.io) backup files **in place** — same path,
same filename — so that Coolify's own backup retention keeps working while
every backup that Coolify writes ends up encrypted on disk.

Encryption is **asymmetric** with [`age`](https://age-encryption.org): the server
only holds a **public key** (recipient) and can therefore only encrypt. The
private key stays offline, on a different machine.

> **No warranty. Use at your own risk.** This is a small script for people who
> run Coolify in production and are willing to own their backup *and* restore
> process. It is not a one-click backup product, and it has not been tested
> against every Coolify version. Read [Schema dependency](#schema-dependency)
> and [Restore](#restore) before you rely on it.

---

## Why "in place"?

Coolify decides what to delete purely from its database: the retention logic
runs `rm -f <filename>` (or `delete(<filename>)` against S3) using the exact
path it recorded when the backup finished.

If you move, rename or re-wrap a backup file, Coolify keeps looking at the
original path — retention breaks, or you accumulate files forever.

This script therefore **never changes the path**. It rewrites the file in place
once Coolify has finished writing it, and keeps the path, so retention keeps
deleting the (now encrypted) file. Coolify itself is not patched, which is what
makes this survive Coolify upgrades.

## How it works

1. Every run (systemd timer, by default every 10 seconds) reads **finished**
   backup executions from Coolify's own PostgreSQL database. The database is
   only ever read — never written.
2. For every referenced file that is not encrypted yet, the file is encrypted to
   `<file>.tmp.$$` and then atomically `mv`'d over the original. Owner, group
   and permission bits of the original are preserved.
3. Every encrypted file starts with a magic header (`COOLIFYENC1`), so a file
   that was already encrypted is skipped on the next run. The script is
   idempotent.
4. Only files below `BACKUP_ROOT` (default `/data/coolify/backups`) are touched.
5. Several guards run *before* anything is modified: the database container must
   be running, the age recipient must actually be usable, and the Coolify schema
   must still match (see below).

Covered sources:

| Source | Table |
| --- | --- |
| Standalone database backups, including Coolify's own `coolify-db` self-backup | `scheduled_database_backup_executions` |
| Volume backups | `scheduled_volume_backup_executions` |

## Who this is for

- You run Coolify in production and hold data you cannot lose.
- You want your backups encrypted **offsite** (Hetzner Storage Box, S3, ...)
  and you do not want to give the backup host the ability to decrypt them.
- You are comfortable with SSH, `systemd` and `age`, and with running a
  restore drill yourself.

This is **not** for you if you want a one-click solution, if you cannot keep a
private key safe, or if you will never test a restore.

## What this is NOT

- Not "production ready", no warranty, no support guarantees. Verify your own
  restores.
- Not a Coolify plugin or patch — it is an external script.
- Not a replacement for Coolify's backup feature; it only encrypts what Coolify
  already wrote.
- Not covering backups that live on **other** servers. Only files present on the
  machine running the script are encrypted; anything else is logged as `MISSING`.
- No CI and no automatic releases.

---

## Requirements

- Ubuntu 24.04 (other systemd distributions should work).
- Root / `sudo` on the Coolify host.
- Docker, with the Coolify database container running (default `coolify-db`).
- `age` (the installer installs it for you).
- `systemd`.

## Install

### The one-liner (no checkout, no git)

```bash
curl -fsSL https://raw.githubusercontent.com/T-Justin96/coolify-backup-encrypt/main/install.sh | sudo bash
```

It downloads the remaining files itself, so nothing has to be cloned. Options go
through the pipe:

```bash
# do not start the timer yet
curl -fsSL <url> | sudo bash -s -- --no-enable

# bring your own public key - nothing is generated on the host, nothing to finalize
curl -fsSL <url> | sudo bash -s -- --recipient age1...

# pin a version instead of following main
curl -fsSL https://raw.githubusercontent.com/T-Justin96/coolify-backup-encrypt/main/install.sh \
  | sudo bash -s -- --ref v1.1.0
```

> Piping a script into a root shell means trusting it blindly. If that bothers
> you, download it, read it, then run it:
>
> ```bash
> curl -fsSLO https://raw.githubusercontent.com/T-Justin96/coolify-backup-encrypt/main/install.sh
> less install.sh
> sudo bash install.sh --ref v1.1.0
> ```

> `raw.githubusercontent.com` may serve a cached copy for a few minutes after a
> push. If you want the exact published release instead of whatever `main`
> currently looks like, pin it with `--ref v1.1.0`.

### What the installer does either way

It checks root / docker / Coolify, fetches the files if needed, installs `age`,
copies the script to `/usr/local/bin/`, writes
`/etc/coolify-backup-encrypt.conf`, generates an age key pair, installs the
systemd units, runs `--check-schema` and `--dry-run`, and starts the timer.

**Read this:** it generates the key pair *on the host*, so the private key sits
at `/root/GRAB-ME-BEFORE-DELETE-identity.txt` until you delete it. It prints a
large warning; the intended flow is:

1. copy the identity file to your own machine,
2. store it in your password manager **and** on an offline medium,
3. prove that the copy decrypts a real backup,
4. then run `sudo coolify-backup-encrypt.sh --finalize` on the host.

Until step 4 the host *can* decrypt. That is the trade-off for a one-command
setup. If the private key must never touch the host, use the manual install below.

Installer flags:

| Flag | Effect |
| --- | --- |
| `--recipient age1...` | use your own public key; no key pair is generated on the host, so there is nothing to finalize |
| `--no-enable` | install everything but do not start the timer |
| `--force` | overwrite an existing `/etc/coolify-backup-encrypt.conf` |
| `--ref <git ref>` | download this branch/tag/commit instead of `main` (same as `CBX_REF=...`) |
| `--help` | usage |

### After the install: where it went and how to use it

There is nothing to run day to day. The systemd timer does one encryption pass
every 10 seconds, forever.

| Path | What it is |
| --- | --- |
| `/usr/local/bin/coolify-backup-encrypt.sh` | the script itself; `--help` lists every option |
| `/etc/coolify-backup-encrypt.conf` | configuration, mode 600 |
| `/etc/systemd/system/coolify-backup-encrypt.timer` | the schedule |
| `/etc/systemd/system/coolify-backup-encrypt.service` | the unit the timer starts |
| `/root/GRAB-ME-BEFORE-DELETE-identity.txt` | temporary private key; remove it with `--finalize` |

Useful commands:

```bash
coolify-backup-encrypt.sh --dry-run        # what would be encrypted right now
coolify-backup-encrypt.sh --check-schema   # after every Coolify upgrade
coolify-backup-encrypt.sh --help           # all options
journalctl -u coolify-backup-encrypt.service -n 30
systemctl list-timers coolify-backup-encrypt.timer
systemctl --failed
```

After an install, files that already exist get encrypted by the first few timer
runs, and everything Coolify writes afterwards is encrypted within seconds.

### From a clone

```bash
git clone https://github.com/T-Justin96/coolify-backup-encrypt
cd coolify-backup-encrypt
sudo ./install.sh
```

Run from a checkout, the installer just uses the files next to it — no download.

### Manual install (private key stays offline)

Everything below runs as root on the Coolify host.

### 1. The script

```bash
install -m 0755 coolify-backup-encrypt.sh /usr/local/bin/coolify-backup-encrypt.sh
```

### 2. Generate a key pair OFFLINE (not on the Coolify host)

On a machine you trust, ideally offline:

```bash
age-keygen -o coolify-backup-age.key   # the IDENTITY (private key) - keep it OFFLINE
age-keygen -y coolify-backup-age.key   # prints age1... -> this RECIPIENT goes to the server
```

The first file is the private key, the printed `age1...` value is the public key.
Never copy the identity to the Coolify host, and make sure you will still have
access to it in five years.

### 3. Install age on the Coolify host

```bash
apt-get update && apt-get install -y age
```

Nothing has to be imported: the host only ever sees the public recipient as a
string, which you configure in the next step.

### 4. Configure

```bash
install -m 0644 coolify-backup-encrypt.conf.example /etc/coolify-backup-encrypt.conf
$EDITOR /etc/coolify-backup-encrypt.conf
```

At minimum set:

```ini
AGE_RECIPIENT=age1...   # the public key from step 2
```

### 5. Verify BEFORE enabling anything

```bash
coolify-backup-encrypt.sh --check-schema    # must exit 0
coolify-backup-encrypt.sh --dry-run         # shows what would be encrypted
```

`--check-schema` validates the config, the age recipient, the database container
**and** the Coolify schema. Nothing is encrypted. Do not continue until it exits
0.

### 6. Enable the timer

```bash
install -m 0644 coolify-backup-encrypt.service       /etc/systemd/system/
install -m 0644 coolify-backup-encrypt.timer         /etc/systemd/system/
install -m 0644 coolify-backup-encrypt-alert.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now coolify-backup-encrypt.timer
```

Watch it:

```bash
journalctl -u coolify-backup-encrypt.service -f
systemctl list-timers coolify-backup-encrypt.timer
systemctl --failed
```

### 7. (Optional) local self-test before committing

```bash
git config core.hooksPath .githooks
```

---

## Schema dependency

**Read this after every Coolify upgrade.**

This script reads Coolify's **internal** tables. They have no public stability
contract, so a Coolify upgrade may rename or remove a column at any time.

Required tables and columns (verified against **Coolify v4.3.19**):

| Table | Columns |
| --- | --- |
| `scheduled_database_backup_executions` | `status`, `finished_at`, `local_storage_deleted`, `filename` |
| `scheduled_volume_backup_executions` | `status`, `finished_at`, `local_storage_deleted`, `filename` |

Value dependency: only rows with `status = 'success'` are picked up.

**Safety net.** Before touching a single file, the script verifies those columns
against `information_schema` and exits **non-zero** with a message that names the
missing columns. `--check-schema` does exactly this check and nothing else.
Because the timer runs every 10 seconds, a changed schema shows up in the
journal immediately, and `OnFailure=` triggers
`coolify-backup-encrypt-alert.service`.

```bash
# after every Coolify upgrade
coolify-backup-encrypt.sh --check-schema || echo "SCHEMA CHANGED - do not trust your backups"
```

If that fails, the fix is usually a one-line change to the query in
`fetch_filenames()` plus `SCHEMA_TABLES` / `SCHEMA_COLUMNS` — and the matching
update in `coolify-backup-encrypt.selftest.sh`, whose fake `docker` returns a
fixed column list.

### Tested with

- Coolify **v4.3.19** (2026-09) — schema verified against this version.
- Other versions: run `--check-schema` first. Nothing else is guaranteed.

## Command reference

| Command | What it does |
| --- | --- |
| `coolify-backup-encrypt.sh` | One encryption pass (this is what the timer runs). |
| `--dry-run` | Print what would be encrypted, change nothing. |
| `--check-schema` | Preflight + schema guard. Encrypts nothing. Exit != 0 on problem. |
| `--decrypt FILE` | Decrypt an encrypted backup to stdout. |
| `--decrypt-to OUT ENC` | Decrypt into `OUT` (mode 0600, atomic rename). Refuses to overwrite without `--force`. |
| `--force` | Allow `--decrypt-to` to overwrite. Must come *before* `--decrypt-to`. |
| `--cleanup-tmp` | Remove orphaned `*.tmp.*` files left by crashed runs. |
| `--finalize` | Delete the temporary private key that `install.sh` left at `/root/GRAB-ME-BEFORE-DELETE-identity.txt`. Asks for confirmation (`ja`). |
| `--version`, `--help` | Version / usage information. |

Exit codes: `0` on success (including "nothing to do" and "another instance is
already running"), non-zero on preflight or encryption failure.

## Configuration

See `coolify-backup-encrypt.conf.example`. Every value has a built-in default, so
the file is optional — **except `AGE_RECIPIENT`, which is required** and has no
sensible default.

| Variable | Default | Meaning |
| --- | --- | --- |
| `AGE_RECIPIENT` | – | **Required.** The public key (`age1...`) that backups are encrypted to. |
| `AGE_IDENTITY` | `/etc/coolify-backup-encrypt/age/identity.txt` | Private key path. Only used by `--decrypt` / `--decrypt-to`, i.e. on the machine that holds the key. |
| `GRAB_IDENTITY` | `/root/GRAB-ME-BEFORE-DELETE-identity.txt` | Where `install.sh` leaves the bootstrapped private key so `--finalize` can find it. |
| `BACKUP_ROOT` | `/data/coolify/backups` | Files outside this root are never touched. |
| `COOLIFY_ENV_FILE` | `/data/coolify/source/.env` | Source of DB credentials and `COOLIFY_VERSION`. |
| `DB_CONTAINER` | `coolify-db` | Database container name. |
| `GRACE_SECONDS` | `5` | Wait this long after `finished_at` before encrypting. |
| `MAX_LOAD` | `0` | `>0`: skip the run when load1 > `MAX_LOAD * cpus`. |
| `LOCK_FILE` | `/run/coolify-backup-encrypt.lock` | Prevents concurrent runs. |
| `TMP_MAX_AGE_MINUTES` | `60` | `--cleanup-tmp` age threshold. |
| `MAGIC` | `COOLIFYENC1` | Idempotency header. **Never change it once you have encrypted backups.** |

---

## Restore

This is where most people fail. **Do a restore drill before you need one.**

Coolify's own restore button and its download links hand you the **encrypted**
file. Decryption is not something Coolify can do, so restores are manual:
decrypt first, then restore the plain dump as usual.

### 1. Get the file and decrypt it

Do this on a machine that holds the **private key** — not on the Coolify host.

```bash
# copy the encrypted file over
scp root@coolify:/data/coolify/backups/.../backup.dmp .

# decrypt into a new file (refuses to overwrite unless you add --force)
coolify-backup-encrypt.sh --decrypt-to restore.dmp backup.dmp

# or by hand - strip the 12-byte magic header first:
tail -c +13 backup.dmp | age --decrypt --identity coolify-backup-age.key > restore.dmp
```

The magic header is `COOLIFYENC1` plus a newline, i.e. the first 12 bytes.

### 2. Verify the decrypted file

```bash
ls -l restore.dmp
file restore.dmp                    # should look like a database dump, not noise
pg_restore --list restore.dmp       # PostgreSQL: must list objects, no error
```

If `age` printed an error and `--decrypt-to` exited non-zero, the file is
corrupt or you used the wrong key. Do not continue.

### 3. Restore

- **Database backup**: restore the plain dump the way you normally would. Prefer
  restoring into a throwaway container first. For Coolify's own database,
  remember that the `coolify-db` self-backup exists.
- **Volume backup**: stop the container that uses the volume, unpack the archive
  into the volume path, then start the container again.
- Never restore over a running production database without a snapshot.

### 4. Restore drill checklist

- [ ] Can I decrypt a backup today, on a machine that is not the Coolify host?
- [ ] Does the decrypted dump pass `pg_restore --list`?
- [ ] Did I actually restore it somewhere and query data?
- [ ] Is the private key backed up, and can I still find it in five years?

## Key management

- The Coolify host holds **only the public key**. It can encrypt, never decrypt.
- The private key never goes on the Coolify host. Keep it offline, and keep a
  backup of it somewhere else.
- Losing the private key means losing every backup. There is no recovery path.
- Rotating keys cannot make old backups readable with a new key. Keep old private
  keys until the corresponding backups have aged out of your retention.
- `install.sh` bootstraps the key pair on the host for convenience. Until you run
  `--finalize`, that host can decrypt. `--finalize` deletes the file after an
  explicit confirmation; `shred` is used when available (on SSDs and some
  filesystems this is best-effort only, so treat the key as "copied away and
  deleted", not as "securely erased").

## Self-test

```bash
bash coolify-backup-encrypt.selftest.sh
```

Needs no Coolify, no docker and no root: `docker` and `flock` are faked and an
isolated age key pair is generated per case. It covers dry-run, in-place
encryption, idempotency, the decrypt roundtrip, `--decrypt-to`, the overwrite
guard, the magic header guard, the **schema-changed failure path**,
`--cleanup-tmp` and `--finalize`.

If `age` is not installed on the machine running the test, the crypto cases fall
back to a base64 stub and say so:

```
[stub] age not installed here - plumbing only, no real crypto
```

That still verifies all of the file handling, but not the cryptography itself —
so run the test once on a host that has `age` before you trust a release.

## Uninstall

```bash
systemctl disable --now coolify-backup-encrypt.timer
rm -f /etc/systemd/system/coolify-backup-encrypt.service \
      /etc/systemd/system/coolify-backup-encrypt-alert.service \
      /etc/systemd/system/coolify-backup-encrypt.timer
rm -f /usr/local/bin/coolify-backup-encrypt.sh
rm -rf /etc/coolify-backup-encrypt /etc/coolify-backup-encrypt.conf
systemctl daemon-reload
```

**Existing backup files stay encrypted.** Decrypt them before deleting the
private key, or keep the key. Coolify will keep writing plaintext backups again.

## Security notes

- `age` provides authenticated encryption. There is no symmetric fallback and no
  `gpg` mode: the host is only ever given a public key, which keeps the
  "encrypt only" guarantee simple to reason about.
- The script never writes to the Coolify database and never modifies Coolify.
- Never paste private keys, identities, or decrypted dumps into a public issue.

## Contributing

Small, focused changes with a test please: run `bash coolify-backup-encrypt.selftest.sh`.
If you touch the SQL, also update the fake `docker` column list in the self-test
and the [Schema dependency](#schema-dependency) section.

## License

MIT — see [LICENSE](LICENSE). Provided as is, without warranty of any kind.



