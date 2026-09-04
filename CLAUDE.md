# writefreely-backup

A restic backup side-container for WriteFreely deployments. Extracted from the
`writefreely-wisp` fork on 2026-09-04, with its history, because it has an
independent lifecycle: an application release should not republish this image,
and a change here should not need an application version bump. It mirrors how
`ghost-backup` sits beside Ghost rather than inside it.

`README.md` is the operator-facing documentation. Read it first.

## Shape

```
entrypoint.sh     command dispatch + the scheduler loop (the default mode)
scripts/
  common.sh       log / log_error / log_success
  config.sh       parse /data/config.ini -> DB_TYPE and connection vars
  lock.sh         PID lock shared by backup and restore
  health.sh       beacon file + outbound healthcheck ping
  healthcheck.sh  the Docker HEALTHCHECK
  validate.sh     pre-flight checks
  verify.sh       is the staged database copy usable
  backup.sh       stage -> verify -> restic backup -> forget --prune
  restore.sh      extract -> confirm -> install -> roll back on failure
drivers/
  sqlite3.sh      db_check / db_dump / db_restore / db_staged_name
  mysql.sh        the same four, via mariadb-dump
test/             plain bash, no bats
```

**A driver is four functions and nothing else.** `db_check`, `db_dump <outfile>`,
`db_restore <infile>`, `db_staged_name`. `backup.sh` and `restore.sh` never learn
which one they sourced, and the filename matches the `[database] type` value
verbatim (`sqlite3`, not `sqlite`).

## Rules

- **No new dependencies.** Bash plus what the base images already ship. No bats,
  no jq, no yq. Inherited from the WriteFreely fork's guidelines and worth keeping.
- Every script: `#!/bin/bash`, `set -euo pipefail` (or `set -uo pipefail` where a
  non-zero return is handled), and clean under `shellcheck -x`.
- Present-imperative commit summaries. No conventional-commit prefixes.
- No em dashes in commit messages, comments or documentation. A colon, a
  parenthesis, or two sentences.
- Markdown prose is not hard-wrapped: one line per paragraph. Commit messages
  are the exception and wrap at 72 columns.
- **Never commit a real credential**, including in a test fixture.

## Things that will bite

- **`test/fixtures/*.ini` were lost once already.** The fork's `.gitignore` has a
  blanket `*.ini`, so they were silently never committed and the suite only passed
  because the files sat untracked on disk. Do not add such a rule here.
- **The live database file is excluded from every snapshot on purpose.** The
  staged copy is the only database in it, so no snapshot can hold a torn one.
  `test/backup-cases.sh` asserts both halves of that; it is the whole consistency
  argument, so it is asserted rather than assumed.
- **Verify before trusting a staged copy.** Checking only that a dump is non-empty
  passes happily on one truncated halfway through. `verify.sh` has a test per branch.
- **Tests run as root in CI**, so permission-based failure injection proves
  nothing. Make a file absent rather than unreadable.
- **`touch -d "10 minutes ago"` is GNU-only.** The tests age files with `utime`
  through perl so they also run on macOS.
- **The restore will not mount the Docker socket** to stop the application. That
  is root on the host handed to a backup script. It probes `APP_URL` and refuses.
