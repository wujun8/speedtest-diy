#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

assert_eq() {
    local expected=$1 actual=$2 label=$3
    if [ "$actual" != "$expected" ]; then
        fail "$label (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local haystack=$1 needle=$2 label=$3
    case "$haystack" in
        *"$needle"*) ;;
        *) fail "$label (missing '$needle')" ;;
    esac
}

assert_not_contains() {
    local haystack=$1 needle=$2 label=$3
    case "$haystack" in
        *"$needle"*) fail "$label (unexpected '$needle')" ;;
    esac
}

assert_timestamped_file() {
    local file=$1 expected_lines=$2 label=$3
    local line count=0
    if [ ! -f "$file" ]; then
        fail "$label output file is missing"
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        count=$((count + 1))
        if [[ ! $line =~ ^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\]\ .* ]]; then
            fail "$label line is not a UTC RFC3339-millisecond log: [$line]"
            return 1
        fi
    done <"$file"
    assert_eq "$expected_lines" "$count" "$label line count"
}

read_pid_marker() {
    local pid_file=$1 pid_line='' pid_extra='' pid_fd
    if [ ! -s "$pid_file" ]; then
        return 1
    fi
    if ! exec {pid_fd}<"$pid_file"; then
        return 1
    fi
    if ! IFS= read -r pid_line <&"$pid_fd"; then
        exec {pid_fd}<&-
        return 1
    fi
    case "$pid_line" in
        ''|*[!0-9]*|0*)
            exec {pid_fd}<&-
            return 1
            ;;
    esac
    if IFS= read -r pid_extra <&"$pid_fd"; then
        exec {pid_fd}<&-
        return 1
    fi
    exec {pid_fd}<&-
    [ -z "$pid_extra" ] || return 1
    printf '%s\n' "$pid_line"
}

LOGGER=$ROOT/runtime-log.sh
SCRIPT=$ROOT/random-wait.sh
if [ ! -f "$LOGGER" ]; then
    fail "runtime-log.sh is missing (RED: logger has not been implemented)"
    exit 1
fi
if [ ! -f "$SCRIPT" ]; then
    fail "random-wait.sh is missing"
    exit 1
fi

# shellcheck source=/dev/null
. "$LOGGER" || {
    fail "runtime-log.sh could not be sourced"
    exit 1
}
# shellcheck source=/dev/null
. "$SCRIPT" || {
    fail "random-wait.sh could not be sourced"
    exit 1
}
random_source_text=$(<"$SCRIPT")
if grep -nE 'printf[[:space:]].*(random-wait:|Waiting .+ seconds)' <<<"$random_source_text"; then
    fail 'random-wait.sh still prints a user-visible message directly'
    exit 1
fi

TMP_DIR=$(mktemp -d)
cleanup() {
    local pid_file sleep_pid
    if [ -n "${WAIT_LIFECYCLE_PID:-}" ]; then
        kill -KILL "$WAIT_LIFECYCLE_PID" 2>/dev/null || :
        wait "$WAIT_LIFECYCLE_PID" 2>/dev/null || :
    fi
    for pid_file in "$TMP_DIR"/*.sleep.pid; do
        if [ -f "$pid_file" ]; then
            if sleep_pid=$(read_pid_marker "$pid_file"); then
                kill -KILL "$sleep_pid" 2>/dev/null || :
                wait "$sleep_pid" 2>/dev/null || :
            fi
        fi
    done
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT
FAKE_BIN=$TMP_DIR/bin
mkdir -p -- "$FAKE_BIN"
SHUF_LOG=$TMP_DIR/shuf.log
SLEEP_LOG=$TMP_DIR/sleep.log
: >"$SHUF_LOG"
: >"$SLEEP_LOG"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\\n" "$*" >>"${SHUF_LOG:?}"' \
    'case "$*" in' \
    '    *"7-7"*) printf "7\\n" ;;' \
    '    *"8-9"*) printf "8\\n" ;;' \
    '    *) printf "17\\n" ;;' \
    'esac' >"$FAKE_BIN/shuf"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "${FAKE_SLEEP_HOLD:-false}" = true ] && [ "${1:-}" != "0.01" ]; then' \
    '    : >"${SLEEP_PID_FILE:?}"' \
    '    /bin/sleep 0.05' \
    '    printf "%s\\n" "$$" >"${SLEEP_PID_FILE:?}"' \
    '    exec /bin/sleep 60' \
    'fi' \
    'printf "%s\\n" "$*" >>"${SLEEP_LOG:?}"' >"$FAKE_BIN/sleep"
chmod 755 "$FAKE_BIN/shuf" "$FAKE_BIN/sleep"

# Defaults use an inclusive 5..50 interval and invoke shuf.
(
    unset WAIT_TIME WAIT_TIME_MIN WAIT_TIME_MAX
    PATH="$FAKE_BIN:$PATH"
    export PATH SHUF_LOG SLEEP_LOG
    sampled=$(sample_wait_seconds) || exit 1
    assert_eq 17 "$sampled" "default sample"
    case "$sampled" in
        *'['*|*$'\n'*)
            fail "sample_wait_seconds returned a decorated machine-readable value"
            exit 1
            ;;
    esac
    assert_eq '-i 5-50 -n 1' "$(<"$SHUF_LOG")" "default shuf range"
    wait_for_next_run >"$TMP_DIR/default-wait.out" || exit 1
    wait_output=$(<"$TMP_DIR/default-wait.out")
    assert_timestamped_file "$TMP_DIR/default-wait.out" 1 'default wait log' || exit 1
    assert_contains "$wait_output" 'Waiting 17 seconds before running the tests again...' \
        'English wait message' || exit 1
    assert_not_contains "$wait_output" 'Attente de' 'French wait message' || exit 1
    assert_eq 17 "$(<"$SLEEP_LOG")" "default sleep seconds"
    if [ "${WAIT_TIME+x}" = x ]; then
        fail "random sampling assigned the legacy WAIT_TIME variable"
        exit 1
    fi
) || exit 1

# Equal bounds are accepted and remain inclusive.
: >"$SHUF_LOG"
: >"$SLEEP_LOG"
(
    unset WAIT_TIME
    WAIT_TIME_MIN=7
    WAIT_TIME_MAX=7
    PATH="$FAKE_BIN:$PATH"
    export PATH SHUF_LOG SLEEP_LOG WAIT_TIME_MIN WAIT_TIME_MAX
    sampled=$(sample_wait_seconds) || exit 1
    assert_eq 7 "$sampled" "equal-bound sample"
    assert_eq '-i 7-7 -n 1' "$(<"$SHUF_LOG")" "equal-bound shuf range"
) || exit 1

# A non-empty legacy WAIT_TIME wins and must not call shuf.
: >"$SHUF_LOG"
: >"$SLEEP_LOG"
(
    WAIT_TIME=23
    WAIT_TIME_MIN=50
    WAIT_TIME_MAX=5
    PATH="$FAKE_BIN:$PATH"
    export PATH SHUF_LOG SLEEP_LOG WAIT_TIME WAIT_TIME_MIN WAIT_TIME_MAX
    sampled=$(sample_wait_seconds) || exit 1
    assert_eq 23 "$sampled" "legacy sample"
    if [ -s "$SHUF_LOG" ]; then
        fail "legacy WAIT_TIME unexpectedly called shuf"
        exit 1
    fi
    wait_for_next_run >/dev/null || exit 1
    assert_eq 23 "$(<"$SLEEP_LOG")" "legacy sleep seconds"
) || exit 1

# An explicitly empty legacy variable is the same as unset.
: >"$SHUF_LOG"
(
    WAIT_TIME=
    WAIT_TIME_MIN=8
    WAIT_TIME_MAX=9
    PATH="$FAKE_BIN:$PATH"
    export PATH SHUF_LOG SLEEP_LOG WAIT_TIME WAIT_TIME_MIN WAIT_TIME_MAX
    sampled=$(sample_wait_seconds) || exit 1
    assert_eq 8 "$sampled" "empty legacy sample"
    assert_eq '-i 8-9 -n 1' "$(<"$SHUF_LOG")" "empty legacy shuf range"
) || exit 1

# An entrypoint-owned TERM must interrupt both the initial and recurring waits.
run_wait_lifecycle_case() {
    local label=$1 wait_command=$2
    local pid_file="$TMP_DIR/$label.sleep.pid"
    local trap_file="$TMP_DIR/$label.trap"
    local output_file="$TMP_DIR/$label.out"
    local error_file="$TMP_DIR/$label.err"
    local sleep_pid lifecycle_live lifecycle_rc sleep_live
    local lifecycle_poll_attempts=1000

    rm -f -- "$pid_file" "$trap_file"
    SLEEP_PID_FILE="$pid_file"
    TRAP_FILE="$trap_file"
    FAKE_SLEEP_HOLD=true
    PATH="$FAKE_BIN:$PATH"
    export PATH SHUF_LOG SLEEP_LOG SLEEP_PID_FILE TRAP_FILE FAKE_SLEEP_HOLD
    (
        . "$LOGGER"
        . "$SCRIPT"
        . "$ROOT/network-runtime.sh"
        trap 'cancel_network_runtime; printf "%s\n" done >"$TRAP_FILE"; exit 143' TERM INT
        unset WAIT_TIME WAIT_TIME_MIN WAIT_TIME_MAX
        "$wait_command"
    ) >"$output_file" 2>"$error_file" &
    WAIT_LIFECYCLE_PID=$!

    sleep_pid=''
    for attempt in $(seq 1 "$lifecycle_poll_attempts"); do
        if [ -s "$pid_file" ] && sleep_pid=$(read_pid_marker "$pid_file"); then
            break
        fi
        /bin/sleep 0.01
    done
    if [ -z "$sleep_pid" ]; then
        fail "$label wait did not publish a valid held sleep PID"
        return 1
    fi
    kill -TERM "$WAIT_LIFECYCLE_PID"
    lifecycle_live=1
    for attempt in $(seq 1 "$lifecycle_poll_attempts"); do
        if [ ! -e "/proc/$WAIT_LIFECYCLE_PID/stat" ] ||
            [ "$(awk '{ print $3 }' "/proc/$WAIT_LIFECYCLE_PID/stat" 2>/dev/null)" = Z ]; then
            lifecycle_live=0
            break
        fi
        /bin/sleep 0.01
    done
    if [ "$lifecycle_live" -ne 0 ]; then
        fail "$label wait did not exit after TERM"
        return 1
    fi
    lifecycle_rc=0
    wait "$WAIT_LIFECYCLE_PID" || lifecycle_rc=$?
    assert_eq 143 "$lifecycle_rc" "$label TERM exit status" || return 1
    assert_eq 1 "$(wc -l <"$trap_file")" "$label TERM trap completion" || return 1
    sleep_live=0
    if [ -e "/proc/$sleep_pid/stat" ] &&
        [ "$(awk '{ print $3 }' "/proc/$sleep_pid/stat" 2>/dev/null)" != Z ]; then
        sleep_live=1
    fi
    assert_eq 0 "$sleep_live" "$label held sleep still exists" || return 1
    WAIT_LIFECYCLE_PID=''
}

run_wait_lifecycle_case initial wait_for_initial_start || exit 1
run_wait_lifecycle_case loop wait_for_next_run || exit 1

validate_default() {
    env -i PATH="$PATH" bash -c 'set -u; . "$1"; . "$2"; unset WAIT_TIME WAIT_TIME_MIN WAIT_TIME_MAX; validate_wait_config' _ "$LOGGER" "$SCRIPT"
}

validate_case() {
    local wait=$1 min=$2 max=$3
    env -i PATH="$PATH" WAIT_TIME="$wait" WAIT_TIME_MIN="$min" WAIT_TIME_MAX="$max" \
        bash -c 'set -u; . "$1"; . "$2"; validate_wait_config' _ "$LOGGER" "$SCRIPT"
}

assert_invalid_case() {
    local label=$1 wait=$2 min=$3 max=$4 output error_file
    error_file="$TMP_DIR/invalid-${label//[^[:alnum:]_.-]/_}.err"
    if output=$(env -i PATH="$PATH" WAIT_TIME="$wait" WAIT_TIME_MIN="$min" WAIT_TIME_MAX="$max" \
        bash -c 'set -u; . "$1"; . "$2"; validate_wait_config' _ "$LOGGER" "$SCRIPT" 2>&1); then
        fail "$label unexpectedly passed"
        return 1
    fi
    printf '%s\n' "$output" >"$error_file"
    assert_contains "$output" 'random-wait:' "$label error"
    assert_timestamped_file "$error_file" 1 "$label error log"
}

validate_default || exit 1
validate_case '' 1 2147483647 || exit 1
validate_case 2147483647 999 1 || exit 1
assert_invalid_case 'legacy zero' 0 5 50 || exit 1
assert_invalid_case 'legacy non-integer' 1.5 5 50 || exit 1
assert_invalid_case 'legacy negative' -1 5 50 || exit 1
assert_invalid_case 'legacy over limit' 2147483648 5 50 || exit 1
assert_invalid_case 'random empty minimum' '' '' 50 || exit 1
assert_invalid_case 'random zero minimum' '' 0 50 || exit 1
assert_invalid_case 'random over-limit maximum' '' 5 2147483648 || exit 1
assert_invalid_case 'random reversed bounds' '' 50 5 || exit 1

# The implementation must use coreutils shuf, not shell eval or an ad-hoc PRNG.
if grep -nE '(^|[^[:alnum:]_])eval([[:space:]]|$)' "$SCRIPT"; then
    fail "random-wait.sh contains eval"
    exit 1
fi
if ! grep -Fq -- 'shuf -i' "$SCRIPT"; then
    fail "random-wait.sh does not use shuf -i"
    exit 1
fi
if ! grep -Fq -- 'sleep "$seconds" &' "$SCRIPT" || ! grep -Fq -- 'wait "$sleep_pid"' "$SCRIPT"; then
    fail "random-wait.sh does not use an interruptible background sleep"
    exit 1
fi

printf 'PASS: random-wait.sh\n'
