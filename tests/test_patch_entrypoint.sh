#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
EXPECTED_SHA=4ce13988639aba6ba591b5025023ef13b8db23490bbfcd96167e492a7f8e1f9d

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

assert_contains_file() {
    local file=$1 needle=$2 label=$3
    if ! grep -Fq -- "$needle" "$file"; then
        fail "$label (missing '$needle')"
        return 1
    fi
}

assert_line_exactly_once() {
    local file=$1 needle=$2 label=$3 count
    count=$(grep -Fxc -- "$needle" "$file")
    if [ "$count" != 1 ]; then
        fail "$label (expected exactly one line, got $count)"
        return 1
    fi
}

if [ ! -x "$ROOT/patch-entrypoint.sh" ]; then
    fail "patch-entrypoint.sh is missing or not executable"
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT
SYNTHETIC_FIXTURE=$TMP_DIR/upstream-entrypoint.sh
cat >"$SYNTHETIC_FIXTURE" <<'EOF'
#!/bin/bash

: "${WAIT_TIME:=21600}"
: "${TEST_DURATION:=10}"
: "${DOWNLOAD_THREADS:=4}"
: "${UPLOAD_THREADS:=4}"

# Définir les couleurs avec tput
RED=$(tput setaf 1)
CYAN=$(tput setaf 6)
BOLD=$(tput bold)
RESET=$(tput sgr0)

run_speedtest_direct() {
        if ! cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"; then
            :
        fi
}

run_speedtest_proxy() {
        if ! proxychains4 cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"; then
            :
        fi
}

run_ddl() {
        proxychains4 wget -O /dev/null --progress=dot:giga --no-check-certificate "$URL_DDL" 2>&1 | awk '/saved/ {print $0}'
}

echo -e "${CYAN}${BOLD}Démarrage dans 5 secondes...${RESET}"
sleep 5

while true; do
    echo -e "${CYAN}${BOLD}Attente de $((WAIT_TIME / 3600)) heures avant de relancer les tests...${RESET}"
    sleep "$WAIT_TIME" &
    wait -n
    run_speedtest_direct
    run_speedtest_proxy
    run_ddl
done
EOF
chmod 755 "$SYNTHETIC_FIXTURE"

OLD_WAIT_DEFAULT=': "${WAIT_TIME:=21600}"'
OLD_COLORS_LINE='# Définir les couleurs avec tput'
OLD_INITIAL_SLEEP='sleep 5'
OLD_DIRECT_SPEEDTEST='        if ! cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"; then'
OLD_PROXY_SPEEDTEST='        if ! proxychains4 cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"; then'
OLD_URL_DDL='        proxychains4 wget -O /dev/null --progress=dot:giga --no-check-certificate "$URL_DDL" 2>&1 | awk '\''/saved/ {print $0}'\'''
OLD_WAIT_MESSAGE='    echo -e "${CYAN}${BOLD}Attente de $((WAIT_TIME / 3600)) heures avant de relancer les tests...${RESET}"'
OLD_WAIT_SLEEP='    sleep "$WAIT_TIME" &'
OLD_WAIT_WAIT='    wait -n'

assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_WAIT_DEFAULT" 'synthetic WAIT_TIME default' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_COLORS_LINE" 'synthetic color anchor' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_INITIAL_SLEEP" 'synthetic initial delay' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_DIRECT_SPEEDTEST" 'synthetic direct speedtest' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_PROXY_SPEEDTEST" 'synthetic proxy speedtest' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_URL_DDL" 'synthetic URL_DDL download' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_WAIT_MESSAGE" 'synthetic wait message' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_WAIT_SLEEP" 'synthetic wait sleep' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_WAIT_WAIT" 'synthetic wait wait' || exit 1

SYNTHETIC_SHA=$(sha256sum -- "$SYNTHETIC_FIXTURE" | awk '{print $1}')
TARGET=$TMP_DIR/entrypoint.sh
cp -- "$SYNTHETIC_FIXTURE" "$TARGET"
chmod 755 "$TARGET"

if ! patch_output=$(EXPECTED_UPSTREAM_SHA256="$SYNTHETIC_SHA" /bin/bash "$ROOT/patch-entrypoint.sh" "$TARGET" 2>&1); then
    fail "synthetic fixture was rejected: $patch_output"
    exit 1
fi

if [ "$(stat -c '%a' "$TARGET")" != 755 ]; then
    fail "patched entrypoint did not retain mode 0755"
    exit 1
fi
assert_contains_file "$TARGET" 'RANDOM_WAIT_PATCH_MARKER' 'patched marker' || exit 1
assert_contains_file "$TARGET" '. /usr/local/bin/random-wait.sh' 'random helper source' || exit 1
assert_contains_file "$TARGET" 'if ! validate_wait_config; then' 'preflight validation' || exit 1
assert_contains_file "$TARGET" ': "${WAIT_TIME:=}"' 'legacy default removal' || exit 1
if grep -Fq -- ': "${WAIT_TIME:=21600}"' "$TARGET"; then
    fail "upstream fixed WAIT_TIME default remains"
    exit 1
fi
assert_contains_file "$TARGET" 'sleep 5' 'fixed initial delay' || exit 1
assert_contains_file "$TARGET" 'wait_for_next_run' 'random wait seam' || exit 1
if grep -Fq -- 'sleep "$WAIT_TIME"' "$TARGET" || grep -Fq -- 'wait -n' "$TARGET"; then
    fail "old fixed wait loop remains"
    exit 1
fi
assert_contains_file "$TARGET" 'proxychains4 wget -O /dev/null --progress=dot:giga --no-check-certificate "$URL_DDL"' 'URL_DDL /dev/null behavior' || exit 1
assert_contains_file "$TARGET" 'cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"' 'direct speedtest behavior' || exit 1
assert_contains_file "$TARGET" 'proxychains4 cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"' 'proxy speedtest behavior' || exit 1

if [ "$(grep -Fxc -- '# RANDOM_WAIT_PATCH_MARKER: validated random interval seam' "$TARGET")" != 1 ]; then
    fail "patched marker count is not exactly one"
    exit 1
fi
if grep -nE '(^|[^[:alnum:]_])eval([[:space:]]|$)' "$ROOT/patch-entrypoint.sh" "$TARGET"; then
    fail "patch or patched entrypoint contains eval"
    exit 1
fi

# Reject a changed synthetic entrypoint before any write and leave it byte-for-byte intact.
BAD=$TMP_DIR/bad-entrypoint.sh
cp -- "$SYNTHETIC_FIXTURE" "$BAD"
printf '\n# fixture mutation\n' >>"$BAD"
before=$(sha256sum -- "$BAD" | awk '{print $1}')
if bad_output=$(EXPECTED_UPSTREAM_SHA256="$SYNTHETIC_SHA" /bin/bash "$ROOT/patch-entrypoint.sh" "$BAD" 2>&1); then
    fail "changed upstream entrypoint was accepted"
    exit 1
fi
assert_contains_file <(printf '%s\n' "$bad_output") 'SHA256 mismatch' 'wrong-SHA diagnostic' || exit 1
after=$(sha256sum -- "$BAD" | awk '{print $1}')
if [ "$before" != "$after" ]; then
    fail "wrong-SHA rejection modified its input"
    exit 1
fi

if [ "$(sha256sum -- "$SYNTHETIC_FIXTURE" | awk '{print $1}')" != "$SYNTHETIC_SHA" ]; then
    fail "synthetic fixture changed"
    exit 1
fi

if [ "${UPSTREAM_ENTRYPOINT_FIXTURE+x}" = x ]; then
    if [ ! -f "$UPSTREAM_ENTRYPOINT_FIXTURE" ] || [ ! -r "$UPSTREAM_ENTRYPOINT_FIXTURE" ]; then
        fail "UPSTREAM_ENTRYPOINT_FIXTURE is missing or unreadable"
        exit 1
    fi
    actual_sha=$(sha256sum -- "$UPSTREAM_ENTRYPOINT_FIXTURE" | awk '{print $1}')
    if [ "$actual_sha" != "$EXPECTED_SHA" ]; then
        fail "UPSTREAM_ENTRYPOINT_FIXTURE SHA256 mismatch (expected $EXPECTED_SHA, got $actual_sha)"
        exit 1
    fi

    REAL_TARGET=$TMP_DIR/real-entrypoint.sh
    cp -- "$UPSTREAM_ENTRYPOINT_FIXTURE" "$REAL_TARGET"
    REAL_MODE=$(stat -c '%a' -- "$REAL_TARGET")
    if real_output=$(env -u EXPECTED_UPSTREAM_SHA256 /bin/bash "$ROOT/patch-entrypoint.sh" "$REAL_TARGET" 2>&1); then
        :
    else
        fail "frozen fixture was rejected: $real_output"
        exit 1
    fi
    if [ "$(stat -c '%a' -- "$REAL_TARGET")" != "$REAL_MODE" ]; then
        fail "patched frozen fixture did not retain its mode"
        exit 1
    fi
    assert_contains_file "$REAL_TARGET" 'RANDOM_WAIT_PATCH_MARKER' 'frozen fixture patched marker' || exit 1
    if [ "$(grep -Fxc -- '# RANDOM_WAIT_PATCH_MARKER: validated random interval seam' "$REAL_TARGET")" != 1 ]; then
        fail "frozen fixture patched marker count is not exactly one"
        exit 1
    fi
fi

printf 'PASS: patch-entrypoint.sh\n'
