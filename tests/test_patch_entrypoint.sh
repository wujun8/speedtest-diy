#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURE=/workspace/workspaces/speedtest-diy/.git/hermes-inputs/upstream-entrypoint.sh
EXPECTED_SHA=4ce13988639aba6ba591b5025023ef13b8db23490bbfcd96167e492a7f8e1f9d

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

assert_contains_file() {
    local file=$1 needle=$2 label=$3
    if ! grep -Fq -- "$needle" "$file"; then
        fail "$label (missing '$needle')"
    fi
}

if [ ! -x "$ROOT/patch-entrypoint.sh" ]; then
    fail "patch-entrypoint.sh is missing or not executable"
    exit 1
fi
if [ ! -r "$FIXTURE" ]; then
    fail "frozen upstream fixture is missing"
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT
TARGET=$TMP_DIR/entrypoint.sh
cp -- "$FIXTURE" "$TARGET"
chmod 755 "$TARGET"

if ! patch_output=$(/bin/bash "$ROOT/patch-entrypoint.sh" "$TARGET" 2>&1); then
    fail "frozen fixture was rejected: $patch_output"
    exit 1
fi

if [ "$(stat -c '%a' "$TARGET")" != 755 ]; then
    fail "patched entrypoint did not retain mode 0755"
    exit 1
fi
assert_contains_file "$TARGET" 'RANDOM_WAIT_PATCH_MARKER' 'patched marker'
assert_contains_file "$TARGET" '. /usr/local/bin/random-wait.sh' 'random helper source'
assert_contains_file "$TARGET" 'if ! validate_wait_config; then' 'preflight validation'
assert_contains_file "$TARGET" ': "${WAIT_TIME:=}"' 'legacy default removal'
if grep -Fq -- ': "${WAIT_TIME:=21600}"' "$TARGET"; then
    fail "upstream fixed WAIT_TIME default remains"
    exit 1
fi
assert_contains_file "$TARGET" 'sleep 5' 'fixed initial delay'
assert_contains_file "$TARGET" 'wait_for_next_run' 'random wait seam'
if grep -Fq -- 'sleep "$WAIT_TIME"' "$TARGET" || grep -Fq -- 'wait -n' "$TARGET"; then
    fail "old fixed wait loop remains"
    exit 1
fi
assert_contains_file "$TARGET" 'proxychains4 wget -O /dev/null --progress=dot:giga --no-check-certificate "$URL_DDL"' 'URL_DDL /dev/null behavior'
assert_contains_file "$TARGET" 'cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"' 'direct speedtest behavior'
assert_contains_file "$TARGET" 'proxychains4 cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"' 'proxy speedtest behavior'

if [ "$(grep -Fxc -- '# RANDOM_WAIT_PATCH_MARKER: validated random interval seam' "$TARGET")" != 1 ]; then
    fail "patched marker count is not exactly one"
    exit 1
fi
if grep -nE '(^|[^[:alnum:]_])eval([[:space:]]|$)' "$ROOT/patch-entrypoint.sh" "$TARGET"; then
    fail "patch or patched entrypoint contains eval"
    exit 1
fi

# Reject a changed upstream entrypoint before any write and leave it byte-for-byte intact.
BAD=$TMP_DIR/bad-entrypoint.sh
cp -- "$FIXTURE" "$BAD"
printf '\n# fixture mutation\n' >>"$BAD"
before=$(sha256sum "$BAD" | awk '{print $1}')
if bad_output=$(/bin/bash "$ROOT/patch-entrypoint.sh" "$BAD" 2>&1); then
    fail "changed upstream entrypoint was accepted"
    exit 1
fi
assert_contains_file <(printf '%s\n' "$bad_output") 'SHA256 mismatch' 'wrong-SHA diagnostic'
after=$(sha256sum "$BAD" | awk '{print $1}')
if [ "$before" != "$after" ]; then
    fail "wrong-SHA rejection modified its input"
    exit 1
fi

if [ "$(sha256sum "$FIXTURE" | awk '{print $1}')" != "$EXPECTED_SHA" ]; then
    fail "frozen fixture changed"
    exit 1
fi

printf 'PASS: patch-entrypoint.sh\n'
