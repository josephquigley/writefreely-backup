#!/bin/bash
# Health reporting: a local beacon the Docker HEALTHCHECK reads, and an
# optional outbound ping. Sourced, never executed.
#
# Everything here is best-effort. Monitoring must never break or fail the
# backup it is monitoring.

HEALTH_FILE="${HEALTH_FILE:-/tmp/backup-health}"
ALIVE_FILE="${ALIVE_FILE:-/tmp/backup-alive}"

# write_health <ok|fail>
# Rewritten every run, so its mtime is the time of the last run.
write_health() {
    echo "$1 $(date +%s)" > "$HEALTH_FILE" 2>/dev/null || true
}

touch_alive() {
    touch "$ALIVE_FILE" 2>/dev/null || true
}

# ping_healthcheck <success|fail>
# Never fails the run, but says so when the monitor did not accept the ping.
# Discarding the response hid a paused monitor once: it answered 410 to every
# ping, the backups kept succeeding, and the monitor stayed down for weeks with
# nothing in the log to explain it. The URL is never logged, because the token
# in it is a credential.
ping_healthcheck() {
    local status="$1" url="${BACKUP_HEALTHCHECK_URL:-}" code
    [[ -n "$url" ]] || return 0
    [[ "$status" == "fail" ]] && url="${url}/fail"
    code="$("${CURL:-curl}" -sS -o /dev/null -w '%{http_code}' -m 10 --retry 3 "$url" 2>/dev/null)" || true
    code="${code:-000}"
    if [[ "$code" != 2?? ]]; then
        if [[ "$code" == "000" ]]; then
            log_error "the healthcheck ping ($status) did not reach the monitor; the backup itself is unaffected"
        else
            log_error "the monitor rejected the healthcheck ping ($status) with HTTP $code; it may be paused, deleted, or the URL wrong. The backup itself is unaffected"
        fi
    fi
    return 0
}

# seed_health_from_repository
# The beacon lives in /tmp, so a recreated container starts with none and
# reads unhealthy until its first scheduled run, which for a daily schedule
# can be most of a day of false alarm. A snapshot in the repository is proof
# that a backup completed, so when there is no beacon, write one dated at the
# newest snapshot for this deployment. Best-effort: no repository, no
# snapshot, or an unparseable time all leave things as they were.
seed_health_from_repository() {
    [[ -e "$HEALTH_FILE" ]] && return 0
    resolve_identity
    local json newest=0 t epoch
    json="$(restic snapshots --json --host "$HOST_TAG" --tag "$SITE" 2>/dev/null)" || return 0
    while read -r t; do
        epoch="$(date -d "$t" +%s 2>/dev/null)" || continue
        (( epoch > newest )) && newest="$epoch"
    done < <(grep -o '"time":"[^"]*"' <<< "$json" | cut -d'"' -f4)
    (( newest > 0 )) || return 0
    echo "ok $newest" > "$HEALTH_FILE" 2>/dev/null || return 0
    touch -d "@$newest" "$HEALTH_FILE" 2>/dev/null || true
    log "no local health record; seeded it from the newest snapshot, taken $(date -d "@$newest" '+%Y-%m-%d %H:%M:%S')"
}
