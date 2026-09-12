# Changelog

Not a formal standard, just a short history.

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
