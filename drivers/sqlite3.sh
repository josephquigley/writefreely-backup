#!/bin/bash
# SQLite driver. Sourced by backup.sh and restore.sh when config.ini says
# `type = sqlite3`. Provides db_check, db_dump, db_restore, db_staged_name.

# The client program, overridable so the missing-client path is testable.
SQLITE_BIN="${SQLITE_BIN:-sqlite3}"

db_staged_name() {
    printf 'writefreely.db'
}

# Both image variants ship both drivers and differ only in which client is
# installed, so running the wrong one fails here. Say which image would work
# rather than reporting it as a problem with the database.
db_client_check() {
    if ! command -v "$SQLITE_BIN" >/dev/null 2>&1; then
        log_error "no $SQLITE_BIN in this image, but config.ini says type = sqlite3"
        log_error "use the writefreely-backup-sqlite image"
        return 1
    fi
    return 0
}

db_check() {
    db_client_check || return 1
    if [[ -z "$DB_FILENAME" ]]; then
        log_error "config.ini has no [database] filename"
        return 1
    fi
    if [[ ! -f "$DB_FILENAME" ]]; then
        log_error "database file not found: $DB_FILENAME"
        return 1
    fi
    if ! "$SQLITE_BIN" "$DB_FILENAME" 'SELECT 1' >/dev/null 2>&1; then
        log_error "cannot read $DB_FILENAME"
        return 1
    fi
    return 0
}

# db_dump <outfile>
#
# Uses SQLite's online backup API through the .backup dot-command, which is
# consistent against a live writer without quiescing the application and
# without holding a read lock for the duration. Copying the file with cp is
# not equivalent: it can capture a torn page mid-transaction.
db_dump() {
    local out="$1"
    if ! "$SQLITE_BIN" "$DB_FILENAME" ".backup '$out'"; then
        log_error "sqlite3 .backup failed"
        return 1
    fi
    return 0
}

# db_restore <infile>
#
# Removes the previous database's journal siblings first. Installing a new
# file while the old journal is still present hands SQLite a rollback journal
# describing a database that no longer exists.
db_restore() {
    local in="$1"
    rm -f "$DB_FILENAME-journal" "$DB_FILENAME-wal" "$DB_FILENAME-shm"
    if ! cp "$in" "$DB_FILENAME"; then
        log_error "could not install $in at $DB_FILENAME"
        return 1
    fi
    return 0
}
