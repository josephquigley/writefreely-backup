#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=./assert.sh
source ./assert.sh
# shellcheck source=../scripts/common.sh
source ../scripts/common.sh
# shellcheck source=../scripts/health.sh
source ../scripts/health.sh

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A stand-in for curl that answers with whatever status the case asks for and
# records the URL it was called with, so no test needs a network or a server.
cat > "$work/curl" <<'SH'
#!/bin/bash
for arg in "$@"; do last="$arg"; done
echo "$last" > "$FAKE_CURL_LOG"
[[ "$FAKE_CURL_CODE" == "000" ]] && { printf '000'; exit 7; }
printf '%s' "$FAKE_CURL_CODE"
SH
chmod +x "$work/curl"
export CURL="$work/curl" FAKE_CURL_LOG="$work/url"

# ping <status> <code>: prints whatever ping_healthcheck logged.
ping() {
    FAKE_CURL_CODE="$2" BACKUP_HEALTHCHECK_URL="https://hc.example/ping/secret-token" \
        ping_healthcheck "$1" 2>&1
}

assert_eq "$(ping success 200)" "" "an accepted ping logs nothing"
assert_eq "$(cat "$work/url")" "https://hc.example/ping/secret-token" "success pings the bare URL"

ping fail 200 >/dev/null
assert_eq "$(cat "$work/url")" "https://hc.example/ping/secret-token/fail" "failure pings /fail"

out="$(ping success 410)"
assert_contains "$out" "HTTP 410" "a rejected ping is logged with its status"
assert_contains "$out" "paused" "the log suggests a paused monitor"
assert_not_contains "$out" "secret-token" "the token never reaches the log"

out="$(ping success 000)"
assert_contains "$out" "did not reach the monitor" "an unreachable monitor is logged"
assert_not_contains "$out" "secret-token" "the token stays out of that log too"

FAKE_CURL_CODE=410 BACKUP_HEALTHCHECK_URL="https://hc.example/ping/x" ping_healthcheck success >/dev/null 2>&1
assert_eq "$?" "0" "a rejected ping never fails the caller"

out="$(BACKUP_HEALTHCHECK_URL="" ping_healthcheck success 2>&1)"
assert_eq "$out" "" "no URL configured means no ping and no log"

finish
