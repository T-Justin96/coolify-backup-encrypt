# Changelog

Not a formal standard, just a short history.

## 1.2.0 - 2026-09

Added day-2 management and two correctness fixes that came out of a real
install on a live Coolify host.

- **`--status`**: version, config, recipient, whether a private key is still on
  the host, container and Coolify version, timer state, and counters
  (referenced / encrypted / pending / not on this host / uploaded to S3).
- **`--verify FILE [--identity K]`**: checks the magic header, recognises the
  payload (`PGDMP`, gzip) and, with a private key, really decrypts. Removes the
  need for `pg_restore` on the host.
- **`--update [--ref REF]`**: installs a newer script and the systemd units and
  re-runs `--check-schema`. Config and keys are deliberately never touched.
- **`--uninstall [--purge]`**: stops and removes the timer, units and script.
  Backup files are never deleted.
- Fixed: a failed encryption (or a path outside `BACKUP_ROOT`) exited `0`, so
  `OnFailure=` never fired and a silently broken install looked healthy.
- Fixed: every pass logged a start line, a summary and one line per missing
  backup. With a 60 s timer that is tens of thousands of journal lines per day
  and it buried real errors. Passes are now silent when there is nothing to do,
  and "not on this host" is reported once per change (state in `STATE_DIR`).
- Warns when Coolify uploaded a backup to S3: that copy is plaintext, because
  Coolify uploads before this script runs.
- `install.sh` refuses to generate a second key pair when the existing config
  already pins a different `AGE_RECIPIENT`. That combination silently produced a
  key that did not match the backups.
- `install.sh` no longer aborts when `apt-get update` fails, and points at the
  `/tmp` problem when that is the cause.
- Timer interval 10 s -> 60 s.

## 1.1.1 - 2026-09

- Fixed: `install.sh` wrote a comment containing backticks into the generated
  config. Inside an unquoted heredoc those ran as command substitution, which
  printed a confusing `--finalize: command not found` in the middle of the
  install output.
- The post-install summary is now English, shorter and says where the files
  ended up and how to look at them.
- The copy-the-key hint uses the short host name instead of the fully qualified
  one, so the installer output no longer carries your domain.

## 1.1.0 - 2026-09

- `install.sh` works standalone now: `curl ... | sudo bash`. It downloads the
  script and the systemd units from the repository, so no git checkout is needed.
  `--ref <branch|tag|commit>` pins a version instead of following `main`.
- `install.sh --help` no longer depends on reading its own file, so it works when
  piped into bash.

## 1.0.0 - 2026-09

- Initial release.
- Encrypts Coolify backup files in place (same path/filename), so Coolify's own
  retention keeps deleting them.
- Asymmetric (public key) encryption with `age`. The host is only ever given the
  public recipient, so it can encrypt but never decrypt. No `gpg`, no symmetric
  mode.
- Idempotent via a `COOLIFYENC1` magic header.
- Reads finished backups (`scheduled_database_backup_executions` and
  `scheduled_volume_backup_executions`) from the Coolify database, read-only.
- `--check-schema` guards against Coolify schema changes.
- `--decrypt` / `--decrypt-to` for manual restores.
- `--finalize` deletes the temporary private key left behind by `install.sh`.
- `install.sh`: one-command setup (deps, key pair, config, systemd, warning).
- `install.sh` also works standalone via `curl | sudo bash`: it downloads the
  script and the systemd units from the repository (`--ref` to pin a version).
- Verified against Coolify v4.3.19.
