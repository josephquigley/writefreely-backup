#!/bin/bash
# MySQL/MariaDB driver. Sourced when config.ini says `type = mysql`.
#
# The client is MariaDB's, because that is what the WriteFreely compose
# stacks actually run (lscr.io/linuxserver/mariadb). The commands are
# mariadb-dump and mariadb.

# The client programs, overridable so the missing-client path is testable.
MARIADB_BIN="${MARIADB_BIN:-mariadb}"
MARIADB_DUMP_BIN="${MARIADB_DUMP_BIN:-mariadb-dump}"

db_staged_name() {
    printf 'writefreely.sql'
}

# Both image variants ship both drivers and differ only in which client is
# installed, so running the wrong one fails here. Say which image would work
# rather than reporting it as a connection failure, which sends you looking
# at the database instead of at the image.
db_client_check() {
    local missing=""
    command -v "$MARIADB_BIN" >/dev/null 2>&1 || missing="$MARIADB_BIN"
    command -v "$MARIADB_DUMP_BIN" >/dev/null 2>&1 || missing="${missing:+$missing and }$MARIADB_DUMP_BIN"
    if [[ -n "$missing" ]]; then
        log_error "no $missing in this image, but config.ini says type = mysql"
        log_error "use the writefreely-backup-mysql image"
        return 1
    fi
    return 0
}

# The password goes through the environment, never the command line: an
# argument is visible to every process on the host in /proc/<pid>/cmdline.
_mysql_env() {
    MYSQL_PWD="$DB_PASSWORD"
    export MYSQL_PWD
}

db_check() {
    db_client_check || return 1
    if [[ -z "$DB_NAME" ]]; then
        log_error "config.ini has no [database] database"
        return 1
    fi
    _mysql_env
    if ! "$MARIADB_BIN" -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" \
        -e 'SELECT 1' >/dev/null 2>&1; then
        log_error "cannot connect to $DB_HOST:$DB_PORT/$DB_NAME as $DB_USER"
        return 1
    fi
    return 0
}

# db_dump <outfile>
db_dump() {
    local out="$1"
    _mysql_env
    if ! "$MARIADB_DUMP_BIN" -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" \
        --single-transaction --quick --routines --triggers \
        "$DB_NAME" > "$out"; then
        log_error "mariadb-dump failed"
        return 1
    fi
    return 0
}

# db_restore <infile>
db_restore() {
    local in="$1"
    _mysql_env
    if ! "$MARIADB_BIN" -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" < "$in"; then
        log_error "restore into $DB_HOST:$DB_PORT/$DB_NAME failed"
        return 1
    fi
    return 0
}
