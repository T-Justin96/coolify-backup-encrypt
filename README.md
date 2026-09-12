# coolify-backup-encrypt

Encrypts [Coolify](https://coolify.io) backup files **in place** — same path,
same filename — so Coolify's own retention keeps working, while every backup
Coolify writes ends up encrypted on disk.

Encryption is **asymmetric** with [`age`](https://age-encryption.org): the host
only ever gets a **public key**, so it can encrypt but never decrypt.

> **No warranty. Use at your own risk.** Small script, written for people who run
> Coolify in production and are willing to own their backup *and* restore
> process. It is not a one-click product, and it has been tested against exactly
> one Coolify version (see [Schema dependency](#schema-dependency)).
> **Read [Restore](#restore) and verify your own restore before you rely on it.**

---

## Why "in place"?

Coolify decides what to delete purely from its database: retention runs
`rm -f <filename>` (or `delete(<filename)` against S3) using the exact path it
recorded when the backup finished.

Rename, move or re-wrap a backup file and Coolify keeps looking at the original
path — retention breaks, or files pile up forever.

So this script **never changes the path**. It rewrites the file in place once
Coolify has finished writing it. Coolify itself is not patched, which is what
makes this survive Coolify upgrades.

## How it works

1. Every run reads **finished** backups from Coolify's own PostgreSQL database.
   The database is only ever read, never written.
2. Each referenced file that is not encrypted yet is encrypted to
   `<file>.tmp.$$` and then atomically `mv`'d over the original. Owner, group and
   permission bits are preserved.
3. Every encrypted file starts with the magic header `COOLIFYENC1`, so a file
   that was already encrypted is skipped. The script is idempotent.
4. Only files below `BACKUP_ROOT` are touched. Anything else fails the run.
5. Guards run *before* anything is modified: database container up, recipient
   actually usable, Coolify schema still matching.

Covered sources:

| Source | Table |
| --- | --- |
| Database backups, including Coolify's own `coolify-db` self-backup | `scheduled_database_backup_executions` |
| Volume backups | `scheduled_volume_backup_executions` |

## Who this is for

- You run Coolify in production with data you cannot lose.
- You want backups encrypted **offsite** and you do not want to give the backup
  host the ability to decrypt them.
- You are comfortable with SSH, `systemd` and `age`, and you will actually run a
  restore drill.

Not for you if you want one-click, if you cannot keep a private key safe, or if
you will never test a restore.

## What this is NOT

- Not "production ready", no warranty, no support. Verify your own restores.
- Not a Coolify plugin or patch — an external script.
- **Not covering backups that live on another server.** Only files present on the
  machine running the script are encrypted. See [Multiple servers](#multiple-coolify-servers).
- **Not encrypting what Coolify already pushed to S3.** See [S3](#s3-and-offsite-copies).
- No CI, no automatic releases.

## Requirements

- Ubuntu 24.04 (other systemd distributions should work).
- Root / `sudo` on the Coolify host.
- Docker with the Coolify database container running (`coolify-db`).
- `age` — the installer installs it.
- `systemd`.

---

## Install

### The one-liner (no checkout needed)

```bash
curl -fsSL https://raw.githubusercontent.com/T-Justin96/coolify-backup-encrypt/main/install.sh | sudo bash
```

It downloads the rest itself. Options go through the pipe:

```bash
# install everything but do not start the timer yet
curl -fsSL <url> | sudo bash -s -- --no-enable

# bring your own public key: nothing is generated on the host, nothing to finalize
curl -fsSL <url> | sudo bash -s -- --recipient age1...

# pin a release instead of following main
curl -fsSL https://raw.githubusercontent.com/T-Justin96/coolify-backup-encrypt/main/install.sh \
  | sudo bash -s -- --ref v1.2.0
```

> Piping a script into a root shell means trusting it blindly. If that bothers
> you, download it, read it, then run it:
>
> ```bash
> curl -fsSLO https://raw.githubusercontent.com/T-Justin96/coolify-backup-encrypt/main/install.sh
> less install.sh
> sudo bash install.sh --ref v1.2.0
> ```

> `raw.githubusercontent.com` can serve a cached copy for a few minutes after a
> push. To get exactly the released version, pin it with `--ref v1.2.0`.

### From a clone

```bash
git clone https://github.com/T-Justin96/coolify-backup-encrypt
cd coolify-backup-encrypt
sudo ./install.sh
```

Run from a checkout, the installer just uses the files next to it.

### What the installer does

1. checks root, docker and the Coolify database container
2. fetches the script and the systemd units (only when run standalone)
3. installs `age` if it is missing
4. installs the script to `/usr/local/bin/`
5. creates the config and an age key pair (unless you pass `--recipient`)
6. verifies the key pair with a real encrypt/decrypt roundtrip
7. installs the systemd units and runs `--check-schema` and `--dry-run`
8. starts the timer and prints what to do next

Installer flags:

| Flag | Effect |
| --- | --- |
| `--recipient age1...` | use your own public key; nothing is generated on the host, so there is nothing to finalize |
| `--ref <git ref>` | fetch this branch/tag/commit instead of `main` |
| `--no-enable` | install everything but do not start the timer |
| `--force` | overwrite an existing config, and allow generating a new key pair |
### After the install: where things live

There is nothing to run day to day. The timer encrypts each finished backup
within a minute, forever.

| Path | What it is |
| --- | --- |
| `/usr/local/bin/coolify-backup-encrypt.sh` | the script; `--help` lists every option |
| `/etc/coolify-backup-encrypt.conf` | configuration, mode 600 |
| `/etc/systemd/system/coolify-backup-encrypt.timer` | the schedule (60 seconds) |
| `/etc/systemd/system/coolify-backup-encrypt.service` | what the timer starts |
| `/run/coolify-backup-encrypt.missing` | state file: which backups are not on this host |
| `/root/GRAB-ME-BEFORE-DELETE-identity.txt` | temporary private key; remove it with `--finalize` |

### Manual install (private key never touches the host)

If the installer must not create a key pair on the server at all:

1. **Offline**, on a machine you trust:

   ```bash
   age-keygen -o coolify-backup-age.key   # the IDENTITY - keep it offline
   age-keygen -y coolify-backup-age.key   # prints age1... - this goes to the server
   ```

2. **On the Coolify host** (put your own `age1...` value in):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/T-Justin96/coolify-backup-encrypt/main/install.sh \
     | sudo bash -s -- --recipient age1...
   ```

No key pair is generated, so there is nothing to finalize. The host has a public
key and nothing else.

---

## Day 2: the commands

Run `--status` first, always. It answers "what is installed and what is going on":

```console
# coolify-backup-encrypt.sh --status
coolify-backup-encrypt 1.2.0
script      /usr/local/bin/coolify-backup-encrypt.sh
config      /etc/coolify-backup-encrypt.conf (mode 600)
crypto      age, public-key only
recipient   age192yffpp9qt329...dexeaf2s2e52xp
key on host no (good)
identity    /etc/coolify-backup-encrypt/age/identity.txt (absent - only needed for --decrypt/--verify)
container   coolify-db running
coolify     version 4.3.19
timer       enabled, active
schedule    Sat 2026-09-12 12:32:40 CEST  58s  Sat 2026-09-12 12:31:40 CEST  1min ago  coolify-backup-encrypt.timer  coolify-backup-encrypt.service
backups     8 referenced -> 2 encrypted, 0 pending, 6 not on this host
```

| Command | What it does |
| --- | --- |
| `--status` | everything above, on one screen |
| `--dry-run` | what would be encrypted right now; changes nothing |
| `--check-schema` | preflight + schema guard. **Run after every Coolify upgrade** |
| `--verify FILE [--identity K]` | header, format, size — and with a key, a real decrypt |
| `--decrypt FILE` | decrypt to stdout |
| `--decrypt-to OUT ENC` | decrypt into `OUT` (mode 0600, atomic); refuses to overwrite without `--force` |
| `--update [--ref REF]` | newest script + units. **Never touches config or keys** |
| `--uninstall [--purge]` | stop and remove everything; backup files are kept |
| `--cleanup-tmp` | remove `*.tmp.*` leftovers of crashed runs |
| `--finalize` | delete the bootstrapped private key from this host |
| `--version`, `--help` | version / usage |

A pass prints **nothing** when there is nothing to do, so the journal stays
readable:

```bash
journalctl -u coolify-backup-encrypt.service -n 30
systemctl --failed
```

Exit codes: `0` on success (including "nothing to do"), non-zero when an
encryption failed, when a path fell outside `BACKUP_ROOT`, or when the schema
check failed. That is what makes `OnFailure=` alert you.

### Updating

```bash
sudo coolify-backup-encrypt.sh --update               # follow main
sudo coolify-backup-encrypt.sh --update --ref v1.2.0  # pin a release
```

It downloads the script and the units, checks that the script is valid bash,
prints the version change, installs, reloads systemd, and re-runs
`--check-schema`. Config, keys and backups are never touched.

Re-running the **installer** is not the same thing. It refuses to touch an
existing config on purpose, because generating a second key pair would hand you
a key that does not match your backups.

### Uninstalling

```bash
sudo coolify-backup-encrypt.sh --uninstall            # keeps config and /etc/.../
sudo coolify-backup-encrypt.sh --uninstall --purge     # removes config too
```

Backup files are never deleted. They stay encrypted and need your private key.

---

## S3 and offsite copies

**Read this if you enabled `save_s3` in Coolify.**

Coolify uploads a backup to S3 as soon as it is created. This script runs
*afterwards* and rewrites only the **local** file. So:

> The S3 object stays **plaintext**. Encrypting the local copy does not change it.

`--status` tells you when this applies:

```
s3          3 backup(s) were uploaded to S3 by Coolify in PLAINTEXT
            this script only encrypts the local copy afterwards
```

Your options:

- **Turn `save_s3` off** and copy the encrypted local files offsite with your own
  tooling. This keeps the "host cannot decrypt" property. Recommended.
- Or accept the plaintext S3 copy and secure the bucket accordingly.

## Multiple Coolify servers

Every backup file is written **on the server where the database or volume
lives**. This script only encrypts what exists on the machine it runs on.
Anything else is reported once and then stays quiet:

```
NOT ON THIS HOST (other server, S3-only, or deleted): /data/coolify/backups/databases/root-team-0/.../pg-dump-....dmp
```

If `--status` shows files under `not on this host`, those backups are **not
encrypted by this install**. Install the script on those servers too — with the
same public key (`--recipient`) or a separate key per server.

`/run/coolify-backup-encrypt.missing` remembers what was already reported, so the
journal does not fill up.

---

## Key management

- The Coolify host holds **only the public key**. It can encrypt, never decrypt.
- The private key never goes on the Coolify host. Keep it offline, and keep a
  second copy somewhere else.
- **Never put the private key into a backup directory, a Git repo, or anything
  that gets synced or uploaded** — including `/data/coolify/backups/`.
- Losing the private key means losing every backup. No recovery path.
- Rotating keys cannot make old backups readable with a new key: keep old private
  keys until the corresponding backups have aged out of your retention.
- `install.sh` bootstraps the key pair on the host for convenience, so until you
  run `--finalize` that host *can* decrypt. `--finalize` deletes the file after
  an explicit confirmation and uses `shred` when available (best-effort only on
  SSDs and some filesystems).
- `--status` shows whether a key is still on the host. That is the line to check.

---

## Restore

**Do a drill before you need one.** Coolify's restore button and its download
links hand you the **encrypted** file. Coolify cannot decrypt it, so restoring is
a manual two-step job.

### 1. Decrypt, on the machine that holds the private key

```bash
scp root@your-coolify:/data/coolify/backups/.../backup.dmp .

# with the script present
coolify-backup-encrypt.sh --decrypt-to restore.dmp backup.dmp

# or by hand - the magic header is the first 12 bytes
tail -c +13 backup.dmp | age --decrypt --identity ./backup-identity.txt > restore.dmp
```

### 2. Verify — no extra packages needed

```bash
head -c 5 restore.dmp        # must print: PGDMP
ls -l restore.dmp            # plausible size
```

`PGDMP` is the header of a PostgreSQL custom-format dump. If the script is on
that machine, `--verify` does all of this in one go, including a real decrypt:

```bash
coolify-backup-encrypt.sh --verify backup.dmp --identity ./backup-identity.txt
```

Do **not** install `postgresql-client` just for this. If you want the stronger
check, use the container that already has the tools:

```bash
cat restore.dmp | docker exec -i coolify-db pg_restore --list | head -20
```

### 3. Restore

- **Database**: restore the plain dump as usual. Prefer a throwaway container
  first. Remember that the `coolify-db` self-backup exists.
- **Volume**: stop the container that uses the volume, unpack into the volume
  path, start it again.
- Never restore over a running production database without a snapshot.

### 4. Drill checklist

- [ ] Can I decrypt a backup today, on a machine that is not the Coolify host?
- [ ] Does `head -c 5` show `PGDMP`?
- [ ] Did I actually restore it somewhere and query data?
- [ ] Is the private key backed up, and will I still find it in five years?

---

## Schema dependency

**Read this after every Coolify upgrade.**

This script reads Coolify's **internal** tables. They have no public stability
contract, so a Coolify upgrade may rename or remove a column at any time.

Required tables and columns (verified against **Coolify v4.3.19**):

| Table | Columns |
| --- | --- |
| `scheduled_database_backup_executions` | `status`, `finished_at`, `local_storage_deleted`, `filename`, `s3_uploaded` |
| `scheduled_volume_backup_executions` | `status`, `finished_at`, `local_storage_deleted`, `filename`, `s3_uploaded` |

Value dependency: only rows with `status = 'success'` are picked up.

**Safety net.** Before touching a single file the script verifies those columns
against `information_schema` and exits **non-zero**, naming the missing columns.
`--check-schema` does exactly that and nothing else.

```bash
coolify-backup-encrypt.sh --check-schema || echo "SCHEMA CHANGED - do not trust your backups"
```

Because the timer runs every minute, a changed schema shows up in the journal
immediately and `OnFailure=` fires.

If it fails, the fix is usually a one-line change to the query in
`fetch_filenames()` plus `SCHEMA_TABLES` / `SCHEMA_COLUMNS` — and the matching
update in `coolify-backup-encrypt.selftest.sh`, whose fake `docker` returns a
fixed column list.

### Tested with

- Coolify **v4.3.19** (2026-09) — schema verified against this version.
- Other versions: run `--check-schema` first. Nothing else is guaranteed.

## Configuration

`/etc/coolify-backup-encrypt.conf`. Optional, except `AGE_RECIPIENT`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `AGE_RECIPIENT` | – | **Required.** The public key (`age1...`) backups are encrypted to. |
| `AGE_IDENTITY` | `/etc/coolify-backup-encrypt/age/identity.txt` | Private key path, only used by `--decrypt` / `--verify`. |
| `GRAB_IDENTITY` | `/root/GRAB-ME-BEFORE-DELETE-identity.txt` | Where `install.sh` leaves the bootstrapped key. |
| `BACKUP_ROOT` | `/data/coolify/backups` | Files outside this root are never touched. |
| `COOLIFY_ENV_FILE` | `/data/coolify/source/.env` | Source of DB credentials and Coolify version. |
| `DB_CONTAINER` | `coolify-db` | Database container name. |
| `GRACE_SECONDS` | `5` | Wait this long after `finished_at` before encrypting. |
| `MAX_LOAD` | `0` | `>0`: skip a run when load1 > `MAX_LOAD * cpus`. |
| `LOCK_FILE` | `/run/coolify-backup-encrypt.lock` | Prevents concurrent runs. |
| `STATE_DIR` | `/run` | Where the "not on this host" state file is kept. |
| `TMP_MAX_AGE_MINUTES` | `60` | `--cleanup-tmp` age threshold. |
| `MAGIC` | `COOLIFYENC1` | Idempotency header. **Never change it** once you have encrypted backups. |

To change how often it runs, edit `OnUnitActiveSec=` in
`/etc/systemd/system/coolify-backup-encrypt.timer`, then:

```bash
systemctl daemon-reload && systemctl restart coolify-backup-encrypt.timer
```

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Couldn't create temporary file /tmp/apt.conf.XXXX` during install | A problem with **your host's `/tmp`**, not with the installer. Check `df -h /tmp /`, `df -i /tmp /`, `ls -ld /tmp` (must be `drwxrwxrwt`). apt falls back to the old index, so the install usually still succeeds. |
| `pg_restore: command not found` | You do not need it. `head -c 5 restore.dmp` must print `PGDMP`, or use `--verify`. For the strong check: `cat restore.dmp \| docker exec -i coolify-db pg_restore --list`. |
| `journalctl` shows nothing for the service | Normal. A pass with nothing to do is silent on purpose. Use `--status`. |
| `NOT ON THIS HOST` lines | Those backups live on another server or are S3-only. See [Multiple servers](#multiple-coolify-servers). |
| `--status` says `key on host YES` | The bootstrap key is still there. Copy it away, verify it, then run `--finalize`. |
| `systemctl --failed` lists the unit | You got an alert. Look at `journalctl -u coolify-backup-encrypt.service -n 50`. |

## Self-test

```bash
bash coolify-backup-encrypt.selftest.sh
```

Needs no Coolify, no docker and no root: `docker` and `flock` are faked, the
systemd paths are redirected, and an isolated age key pair is generated per case.
It covers dry-run, in-place encryption, idempotency, the decrypt roundtrip,
`--decrypt-to`, the overwrite guard, the magic header guard, the
**schema-changed failure path**, `--cleanup-tmp`, `--finalize`, `--verify`, the
**non-zero exit on real failures**, and the **silence of a no-op pass**.

If `age` is missing on the test machine, the crypto cases fall back to a base64
stub and say so:

```
[stub] age not installed here - plumbing only, no real crypto
```

That still proves all of the file handling, but not the cryptography itself — so
run the test once on a host that has `age` before you trust a release.

## Uninstall

```bash
sudo coolify-backup-encrypt.sh --uninstall          # keeps config and /etc/.../
sudo coolify-backup-encrypt.sh --uninstall --purge  # removes config too
```

Backup files are never deleted. They stay encrypted — decrypt them before you
delete the private key, or keep the key.

## Security notes

- `age` provides authenticated encryption. There is no symmetric fallback and no
  `gpg` mode: the host only ever gets a public key, which keeps the "encrypt
  only" guarantee simple to reason about.
- The script never writes to the Coolify database and never modifies Coolify.
- The installer prints your host name in the "copy the private key" hint, so that
  output ends up in scrollback and journals. Check it before pasting publicly.
- Never paste private keys, identities, or decrypted dumps into a public issue.

## Contributing

Small, focused changes with a test please: `bash coolify-backup-encrypt.selftest.sh`.
If you touch the SQL, also update the fake `docker` column list in the self-test
and the [Schema dependency](#schema-dependency) section.

## License

MIT — see [LICENSE](LICENSE). Provided as is, without warranty of any kind.




