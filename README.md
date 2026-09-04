# writefreely-backup

A restic backup side-container for a [WriteFreely](https://writefreely.org) deployment running under Docker Compose. It takes a consistent snapshot of the database, hands it to [restic](https://restic.net) along with the state directory, encrypts everything, and uploads it to whatever storage you point it at.

It works against stock WriteFreely and against the [Wisp Edition](https://github.com/josephquigley/writefreely-wisp) fork. All it needs is a state directory containing `config.ini`.

## Which image

Two variants, matching the two databases WriteFreely supports. Pick the one your `config.ini` says.

| `[database] type` | Image |
|---|---|
| `sqlite3` | `ghcr.io/josephquigley/writefreely-backup:main-sqlite` |
| `mysql` | `ghcr.io/josephquigley/writefreely-backup:main-mysql` |

Tags are branch names and short commit shas. There is no semver, on purpose: pin by digest, so an upgrade is a deliberate edit rather than a tag moving underneath a running container.

```sh
docker inspect -f '{{index .RepoDigests 0}}' ghcr.io/josephquigley/writefreely-backup:main-sqlite
```

## Adding it to your stack

Drop this into your compose file. Nothing runs until you ask for the profile.

```yaml
  backup:
    image: ghcr.io/josephquigley/writefreely-backup:main-sqlite
    restart: unless-stopped
    # Match the user your WriteFreely container runs as, so a restore writes
    # files it can read.
    user: "1000:1000"
    environment:
      RESTIC_REPOSITORY: ${RESTIC_REPOSITORY:-}
      RESTIC_PASSWORD: ${RESTIC_PASSWORD:-}
      RESTIC_CACHE_DIR: /cache
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:-}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY:-}
      BACKUP_SCHEDULE: 0 3 * * *
      BACKUP_KEEP_DAILY: 7
      BACKUP_KEEP_WEEKLY: 4
      BACKUP_KEEP_MONTHLY: 6
      BACKUP_HEALTHCHECK_URL: ${BACKUP_HEALTHCHECK_URL:-}
      # Size to BACKUP_SCHEDULE plus grace. 2880 is two days, for a daily
      # schedule. The 11520 default suits a weekly one.
      BACKUP_HEALTH_MAX_AGE: 2880
      BACKUP_SITE: my-blog
      # Where the restore checks whether WriteFreely is still running.
      APP_URL: http://app:8080/
      PUID: 1000
      PGID: 1000
    volumes:
      # The state directory, read-write because restore installs into it.
      - ./data:/data
      # A snapshot is extracted here first, so nothing lands on top of live
      # data before you have looked at it.
      - ./data-restore:/restore
      # Without this, restic's cache is rebuilt every run and every prune
      # re-downloads the repository index.
      - backup_cache:/cache
    profiles: [backup]

volumes:
  backup_cache:
```

On a MySQL/MariaDB stack, use the `-mysql` image and add `depends_on: db: condition: service_healthy`.

Then:

```sh
mkdir -p data-restore
docker compose --profile backup run --rm backup verify
docker compose --profile backup up -d
```

`verify` checks the environment, reads `config.ini`, connects to the database, checks there is room in `/tmp` for the staged copy, and reaches the repository, initialising it if it does not exist. It reports every problem it finds rather than stopping at the first.

## Database credentials come from config.ini

There are no database variables. The container reads `[database]` out of `config.ini` in the state directory it already mounts, because a second copy of a password is a second thing to leak and a second thing to drift out of step with the first.

Values are never echoed. Logs print `host:port/database` and never the password. A whole-value `${VAR}` reference in `config.ini` is resolved from the environment, and fails loudly when the variable is unset rather than authenticating with an empty string.

## What gets backed up

Everything under the state directory: `config.ini`, `keys/`, `uploads/`, anything else you keep there, and the database. Exclusions are opt-in, and the only ones are the live database file and its journal siblings, which are replaced in the snapshot by a copy taken consistently.

`keys/` is the reason this matters more than it looks. It holds the instance's federation keypair. Posts can be re-imported from an export and images can be re-uploaded, but the keypair cannot be regenerated: every remote server that already knows this actor holds its public key, and a new one means every signature it sends is rejected from then on. Losing that directory costs the instance its identity on the network, whatever else survives.

The database is never copied out from under a running writer. SQLite goes through the online backup API; MySQL dumps with `--single-transaction`. Either way the staged copy is verified before it is trusted, with an integrity check or a completion marker, because a backup nobody verifies is a backup you find out about during a restore.

## RESTIC_PASSWORD is the secret that matters

Snapshots contain `config.ini`, and `config.ini` can contain mail credentials. They are encrypted, so whoever holds `RESTIC_PASSWORD` plus read access to the storage holds those credentials too.

Store it somewhere that survives the server. A password that exists only in the `.env` on the machine being backed up is not a backup password, it is a coincidence: the disaster that makes you need the backup is the one that takes the password with it. A backup you cannot decrypt is not a backup.

## Restoring

Stop WriteFreely first. The container refuses while the application answers on the network, because writing a database out from under a running process corrupts it. It will not stop the container for you: that would mean mounting the Docker socket, which is root on the host handed to a backup script, and that is a bad trade for saving one command.

```sh
docker compose stop app
docker compose --profile backup run --rm backup restore latest
```

The snapshot is extracted into the staging mount first, then you are asked about each component separately: the database, `keys/`, `uploads/`, `legacy-images/` and `config.ini`. Whatever a component replaces is kept as `<name>.bak-<timestamp>` rather than deleted, and a component that fails to install is rolled back. Remove the `.bak-*` copies by hand once you are satisfied.

`config.ini` defaults to no and is skipped entirely by `--yes`. An older config can point at paths a newer image no longer uses, and dropping one onto a current install produces a container that crash-loops on a config it cannot find. Restore it only when you mean to, with `--components=config`.

For scripted restores, `--yes` answers the prompts and `--components=database,keys` chooses exactly what to install.

**Rehearse a restore before you need one**, against a scratch copy. An untested backup is a hypothesis.

## Commands

| Command | Does |
|---|---|
| (none) | run the scheduler, backing up on `BACKUP_SCHEDULE` |
| `backup` | back up now |
| `restore <id>` | restore a snapshot (`latest` or a snapshot id) |
| `snapshots` | list what is in the repository |
| `verify` | run the validation checks |
| `stats` | repository statistics |
| `unlock` | clear a stale repository lock |
| `help` | usage |

## Monitoring

The container reports unhealthy unless the scheduler is alive, the last run succeeded, and that run was recent. A container that is up but has silently stopped backing anything up is the failure worth catching, and Docker's own "up" status does not catch it.

Set `BACKUP_HEALTHCHECK_URL` to be told from outside. It is pinged after a successful run, and with `/fail` appended after a failed one, which is what [healthchecks.io](https://healthchecks.io) and Uptime Kuma expect. Monitoring is best-effort throughout: an unreachable endpoint never fails the backup it is monitoring.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `RESTIC_REPOSITORY` | required | where snapshots go |
| `RESTIC_PASSWORD` | required | the encryption password |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | | S3 and S3-compatible storage |
| `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY` | | Backblaze B2 |
| `BACKUP_SCHEDULE` | `0 3 * * *` | cron expression |
| `BACKUP_KEEP_DAILY` | `7` | retention |
| `BACKUP_KEEP_WEEKLY` | `4` | retention |
| `BACKUP_KEEP_MONTHLY` | `6` | retention |
| `BACKUP_KEEP_YEARLY` | `2` | retention |
| `BACKUP_HEALTHCHECK_URL` | unset | pinged on success, `/fail` on failure |
| `BACKUP_ALIVE_MAX_AGE` | `2` | minutes without a scheduler heartbeat before unhealthy |
| `BACKUP_HEALTH_MAX_AGE` | `11520` | minutes since the last successful run before unhealthy |
| `BACKUP_SITE` | `writefreely` | a restic tag, so one repository can hold several sites |
| `BACKUP_HOST` | container hostname | the restic host, used for retention grouping |
| `RESTIC_CACHE_DIR` | restic's default | point at a volume, or every prune re-downloads the index |
| `APP_URL` | `http://app:8080/` | where the restore checks whether the application is running |
| `PUID`, `PGID` | `1000` | ownership of everything a restore writes |

## Development

```sh
shellcheck -x entrypoint.sh scripts/*.sh drivers/*.sh test/*.sh
bash test/run.sh                    # units, needs restic and sqlite3

docker build -f Dockerfile.sqlite -t wf-backup:sqlite .
bash test/roundtrip-sqlite.sh       # end to end through the built image

docker build -f Dockerfile.mysql -t wf-backup:mysql .
bash test/roundtrip-mysql.sh        # end to end against a real MariaDB
```

Adding another database engine is one file in `drivers/`, named for the `[database] type` value verbatim, providing `db_check`, `db_dump <outfile>`, `db_restore <infile>` and `db_staged_name`. Nothing else changes: `backup.sh` and `restore.sh` never learn which driver they sourced.
