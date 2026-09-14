#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
LOGGER=$ROOT/runtime-log.sh

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 label=$3
    if [[ $actual != "$expected" ]]; then
        fail "$label (expected '$expected', got '$actual')"
    fi
}

assert_timestamped_file() {
    local file=$1 expected_lines=$2 label=$3
    local line count=0
    [[ -f $file ]] || fail "$label output file is missing"
    while IFS= read -r line || [[ -n $line ]]; do
        count=$((count + 1))
        if [[ ! $line =~ ^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\]\ .* ]]; then
            fail "$label line is not a UTC RFC3339-millisecond log: [$line]"
        fi
    done <"$file"
    assert_eq "$expected_lines" "$count" "$label line count"
}

assert_bodies() {
    local file=$1 label=$2
    shift 2
    local -a expected=("$@") actual=()
    local line body

    mapfile -t actual <"$file"
    assert_eq "${#expected[@]}" "${#actual[@]}" "$label body count"
    for ((i = 0; i < ${#expected[@]}; i++)); do
        line=${actual[i]}
        body=${line#*] }
        assert_eq "${expected[i]}" "$body" "$label body $((i + 1))"
    done
}

[[ -f $LOGGER ]] || fail 'runtime-log.sh is missing (RED: logger has not been implemented)'

SOURCE_STDOUT=$(mktemp)
SOURCE_STDERR=$(mktemp)
trap 'rm -f -- "$SOURCE_STDOUT" "$SOURCE_STDERR"' EXIT
if ! env -i PATH="$PATH" bash -c '. "$1"' _ "$LOGGER" >"$SOURCE_STDOUT" 2>"$SOURCE_STDERR"; then
    fail 'runtime-log.sh could not be sourced'
fi
assert_eq '' "$(<"$SOURCE_STDOUT")" 'sourcing runtime-log.sh produced stdout'
assert_eq '' "$(<"$SOURCE_STDERR")" 'sourcing runtime-log.sh produced stderr'

# shellcheck source=/dev/null
. "$LOGGER"

TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"; rm -f -- "$SOURCE_STDOUT" "$SOURCE_STDERR"' EXIT

literal='percent=100% backslash=C:\tmp format=%s'
runtime_log_info "$literal" >"$TMP_DIR/info.out" 2>"$TMP_DIR/info.err"
assert_timestamped_file "$TMP_DIR/info.out" 1 'info output'
assert_bodies "$TMP_DIR/info.out" 'info output' "$literal"
assert_eq '' "$(<"$TMP_DIR/info.err")" 'info unexpectedly wrote stderr'
assert_eq '1' "$(wc -l <"$TMP_DIR/info.out")" 'info did not terminate a no-final-newline input'

runtime_log_warning "$literal" >"$TMP_DIR/warning.out" 2>"$TMP_DIR/warning.err"
assert_eq '' "$(<"$TMP_DIR/warning.out")" 'warning unexpectedly wrote stdout'
assert_timestamped_file "$TMP_DIR/warning.err" 1 'warning output'
assert_bodies "$TMP_DIR/warning.err" 'warning output' "$literal"

runtime_log_error "$literal" >"$TMP_DIR/error.out" 2>"$TMP_DIR/error.err"
assert_eq '' "$(<"$TMP_DIR/error.out")" 'error unexpectedly wrote stdout'
assert_timestamped_file "$TMP_DIR/error.err" 1 'error output'
assert_bodies "$TMP_DIR/error.err" 'error output' "$literal"

# A blank physical line is still a line and must receive its own prefix.
multiline=$'first line\n\nthird line'
runtime_log_info "$multiline" >"$TMP_DIR/multiline.out" 2>"$TMP_DIR/multiline.err"
assert_timestamped_file "$TMP_DIR/multiline.out" 3 'multiline info output'
assert_bodies "$TMP_DIR/multiline.out" 'multiline info output' \
    'first line' '' 'third line'
assert_eq '' "$(<"$TMP_DIR/multiline.err")" 'multiline info unexpectedly wrote stderr'

multiline_warning=$'warning one\n\nwarning three'
runtime_log_warning "$multiline_warning" >"$TMP_DIR/multiline-warning.out" 2>"$TMP_DIR/multiline-warning.err"
assert_eq '' "$(<"$TMP_DIR/multiline-warning.out")" 'multiline warning unexpectedly wrote stdout'
assert_timestamped_file "$TMP_DIR/multiline-warning.err" 3 'multiline warning output'
assert_bodies "$TMP_DIR/multiline-warning.err" 'multiline warning output' \
    'warning one' '' 'warning three'

printf 'PASS: runtime-log.sh\n'
