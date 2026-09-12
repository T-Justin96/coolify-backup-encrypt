# Changelog

Not a formal standard, just a short history.

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
- Verified against Coolify v4.3.19.
