#!/bin/bash
# Shared helpers. Sourced, never executed.

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $*"
}

# resolve_identity: sets SITE and HOST_TAG, the restic tag and host every
# snapshot is filed under. One definition, because the backup run and the
# startup health seed must agree on which snapshots belong to this deployment.
# The host defaults to the site rather than the container hostname, which
# Docker changes on every recreate and would leave each run in a retention
# group of its own.
resolve_identity() {
    SITE="${BACKUP_SITE:-writefreely}"
    # shellcheck disable=SC2034 # read by backup.sh and health.sh, which source this
    HOST_TAG="${BACKUP_HOST:-$SITE}"
}
