# Changelog

All notable changes to `claude-intrupt-hook` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com); dates are ISO-8601.

## [0.0.3] - 2026-07-11

### Added
- `AEGMIS_PROTECTED_PATHS` now supports **`re:`-prefixed regex** entries, tested against
  the resolved absolute deletion target. Anchor with `^…$` to protect a dir *exactly*
  (not its contents), or use alternation / negative-lookahead to include or exempt
  subtrees. Literal paths keep working; invalid regexes are skipped with a stderr warning.

### Changed
- Installer defaults tuned for a quiet, safe local setup: local mode
  (`AEGMIS_FORWARD_ALL=false`), `AEGMIS_PROTECTED_PATHS=re:^$HOME$` (gate the home dir
  itself, not everything under it), and — where the hook reads it — `AEGMIS_GATED_TOOLS`
  scoped to the shell tool only.
- README gains an entry-format table and worked-examples for `AEGMIS_PROTECTED_PATHS`;
  `.env.example` updated to match.

## [0.0.2] - 2026-07-11

### Added
- `AEGMIS_APPROVAL` — master kill switch (default `true`; set `false` to disable the gate
  entirely and allow everything).
- `AEGMIS_PROTECTED_PATHS` — comma-separated dirs to also gate `rm` on (the dir and
  everything under it), with **cwd-aware resolution** so relative targets (`./ok`, `ok`,
  `../x`) are caught, not just absolute paths.

### Changed
- **Deletion gate is now catastrophic-only.** It gates `rm` targeting the home dir,
  filesystem root, a `/Users/<name>` or `/home/<name>` home, a system dir
  (`/etc`, `/usr`, `/var`, …), or a bare `*` / `.` / `..`. Routine and project-local
  deletes (`rm file`, `rm -rf node_modules`, `rm -rf build/`) now pass **without**
  approval — gating every `rm` was too noisy.
- Renamed all env vars `INTRUPT_*` → `AEGMIS_*` (**breaking** — update your
  `.env.intrupt`, or re-run `install.sh`).
- `policies.example.sh` now documents the engine's **start-anchored** regex matching
  (prefix patterns with `[\s\S]*`) and ships a destructive-action reference table.

### Fixed
- Relative deletion targets are resolved against the command's working directory before
  matching protected paths, so `rm -rf ./ok` is gated when it resolves under a protected
  dir (previously only exact absolute strings matched).

## [0.0.1] - 2026-07-03

Initial release.

### Added
- Claude Code `PreToolUse` hook (Python) that gates **Bash / Write / Edit** behind a
  human Slack approval via the Aegmis intrupt API. Forward-all and local modes,
  fail-closed on reject/timeout/error, `policies.example.sh`, one-line `install.sh`, and
  offline smoke tests. Block signal: exit 1 + `{"decision":"block"}`.
