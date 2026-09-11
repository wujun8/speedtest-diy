#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
RUNTIME="$REPO_ROOT/network-runtime.sh"

if [[ ! -f "$RUNTIME" ]]; then
  printf 'FAIL: network-runtime.sh is missing (RED: helper has not been implemented)\n' >&2
  exit 1
fi

STATE=$(mktemp -d "${TMPDIR:-/tmp}/network-runtime-test.XXXXXX")
FAKE_BIN="$STATE/bin"
mkdir -p "$FAKE_BIN"

cleanup() {
  rm -rf "$STATE"
}
trap cleanup EXIT HUP INT TERM

cat > "$FAKE_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -u

: "${FAKE_STATE:?FAKE_STATE is required}"
log="$FAKE_STATE/curl.calls"
output=''
range=''
header_file=''
write_out=''
previous=''
for arg in "$@"; do
  if [[ "$previous" == '--output' || "$previous" == '-o' ]]; then
    output=$arg
  elif [[ "$previous" == '--range' || "$previous" == '-r' ]]; then
    range=$arg
  elif [[ "$previous" == '--dump-header' || "$previous" == '-D' ]]; then
    header_file=$arg
  elif [[ "$previous" == '--write-out' || "$previous" == '-w' ]]; then
    write_out=$arg
  fi
  case "$arg" in
    --output|-o) previous="$arg" ;;
    --range|-r) previous="$arg" ;;
    --dump-header|-D) previous="$arg" ;;
    --write-out|-w) previous="$arg" ;;
    --output=*) output=${arg#*=}; previous='' ;;
    --range=*) range=${arg#*=}; previous='' ;;
    --dump-header=*) header_file=${arg#*=}; previous='' ;;
    --write-out=*) write_out=${arg#*=}; previous='' ;;
    *) previous='' ;;
  esac
done

kind='full'
start=''
end=''
if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
  kind='range'
  start=${BASH_REMATCH[1]}
  end=${BASH_REMATCH[2]}
fi

via=${FAKE_VIA_PROXY:-0}
printf 'pid=%s kind=%s start=%s end=%s output=%s via=%s header=%s write=%s args=%s\n' \
  "$$" "$kind" "$start" "$end" "$output" "$via" "$header_file" "$write_out" "$*" >> "$log"

if [[ "$output" != '/dev/null' ]]; then
  printf 'fake curl refused non-/dev/null output\n' >&2
  exit 90
fi
if [[ -z "$header_file" || -z "$write_out" ]]; then
  printf 'fake curl requires --dump-header and --write-out metadata\n' >&2
  exit 91
fi

total=${FAKE_TOTAL:-101}
mode=${FAKE_WGET_MODE:-normal}
status=200
response_start=''
response_end=''
downloaded=$total

if [[ "$kind" == 'range' ]]; then
  status=206
  response_start=$start
  response_end=$end
  downloaded=$((end - start + 1))
  if [[ "$mode" == 'unsupported' && "$start" == '0' && "$end" == '0' ]]; then
    status=200
    response_start=''
    response_end=''
    downloaded=$total
  elif [[ "$mode" == 'malformed' && "$start" == '0' && "$end" == '0' ]]; then
    response_start=0
    response_end=1
    downloaded=2
  fi
fi

if [[ "$kind" == 'range' && "$start" != '0' && "${FAKE_BARRIER:-false}" == 'true' ]]; then
  marker="$FAKE_STATE/started.${start}-${end}"
  if (set -C; : > "$marker") 2>/dev/null; then
    :
  fi
  count=0
  for attempt in $(seq 1 400); do
    count=0
    for candidate in "$FAKE_STATE"/started.*; do
      if [[ -e "$candidate" ]]; then
        count=$((count + 1))
      fi
    done
    if (( count >= ${FAKE_EXPECT_SEGMENTS:-1} )); then
      break
    fi
    sleep 0.01
done
  if (( count < ${FAKE_EXPECT_SEGMENTS:-1} )); then
    printf 'barrier_failed start=%s end=%s count=%s\n' "$start" "$end" "$count" >> "$FAKE_STATE/barrier.calls"
    exit 88
  fi
  printf 'barrier_released start=%s end=%s\n' "$start" "$end" >> "$FAKE_STATE/barrier.calls"
fi

if [[ "$kind" == 'range' && "$start" != '0' ]]; then
  if [[ "$mode" == 'bad_range' && "${FAKE_BAD_RANGE:-}" == "$start-$end" ]]; then
    response_end=$((end - 1))
    downloaded=$((response_end - start + 1))
  elif [[ "$mode" == 'bad_size' && "${FAKE_BAD_RANGE:-}" == "$start-$end" ]]; then
    downloaded=$((downloaded - 1))
  elif [[ "$mode" == 'bad_status' && "${FAKE_BAD_RANGE:-}" == "$start-$end" ]]; then
    status=200
  fi
fi

: > "$header_file"
printf 'HTTP/1.1 %s\n' "$status" >> "$header_file"
if [[ -n "$response_start" ]]; then
  printf 'Content-Range: bytes %s-%s/%s\n' \
    "$response_start" "$response_end" "$total" >> "$header_file"
fi
printf '\n' >> "$header_file"
printf '%s\t%s\n' "$status" "$downloaded"

if [[ "$mode" == 'fail_range' && "$kind" == 'range' && "${FAKE_FAIL_RANGE:-}" == "$start-$end" ]]; then
  printf 'fake curl worker failure start=%s end=%s\n' "$start" "$end" >&2
  exit 17
fi
exit 0
FAKE_CURL
chmod +x "$FAKE_BIN/curl"

cat > "$FAKE_BIN/wget" <<'FAKE_WGET'
#!/usr/bin/env bash
set -u
: "${FAKE_STATE:?FAKE_STATE is required}"
printf 'wget-called args=%s\n' "$*" >> "$FAKE_STATE/wget.calls"
exit 99
FAKE_WGET
chmod +x "$FAKE_BIN/wget"

cat > "$FAKE_BIN/proxychains4" <<'FAKE_PROXY'
#!/usr/bin/env bash
set -u

: "${FAKE_STATE:?FAKE_STATE is required}"
printf 'pid=%s args=%s\n' "$$" "$*" >> "$FAKE_STATE/proxy.calls"
if [[ "${1:-}" == '-f' ]]; then
  shift 2
fi
if [[ $# -eq 0 ]]; then
  exit 64
fi
FAKE_VIA_PROXY=1
export FAKE_VIA_PROXY
exec "$@"
FAKE_PROXY
chmod +x "$FAKE_BIN/proxychains4"

cat > "$FAKE_BIN/cf_speedtest" <<'FAKE_CF'
#!/usr/bin/env bash
set -u

: "${FAKE_STATE:?FAKE_STATE is required}"
printf 'pid=%s via=%s args=%s\n' "$$" "${FAKE_VIA_PROXY:-0}" "$*" >> "$FAKE_STATE/cf.calls"
if [[ "${FAKE_CF_FAIL:-false}" == 'true' ]]; then
  exit 19
fi
exit 0
FAKE_CF
chmod +x "$FAKE_BIN/cf_speedtest"

export PATH="$FAKE_BIN:$PATH"
export FAKE_STATE="$STATE"
: > "$STATE/curl.calls"
: > "$STATE/wget.calls"
: > "$STATE/proxy.calls"
: > "$STATE/cf.calls"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

assert_eq() {
  local expected=$1
  local actual=$2
  local message=$3
  [[ "$expected" == "$actual" ]] || fail "$message (expected [$expected], got [$actual])"
}

assert_contains() {
  local haystack=$1
  local needle=$2
  local message=$3
  [[ "$haystack" == *"$needle"* ]] || fail "$message (missing [$needle])"
}

assert_not_contains() {
  local haystack=$1
  local needle=$2
  local message=$3
  [[ "$haystack" != *"$needle"* ]] || fail "$message (unexpected [$needle])"
}

reset_fake_state() {
  : > "$STATE/curl.calls"
  : > "$STATE/wget.calls"
  : > "$STATE/proxy.calls"
  : > "$STATE/cf.calls"
  rm -f "$STATE"/started.* "$STATE"/barrier.calls
  unset FAKE_WGET_MODE FAKE_TOTAL FAKE_BARRIER FAKE_EXPECT_SEGMENTS
  unset FAKE_BAD_RANGE FAKE_FAIL_RANGE FAKE_CF_FAIL FAKE_VIA_PROXY
}

run_capture() {
  local output_file=$1
  local error_file=$2
  shift 2
  if "$@" >"$output_file" 2>"$error_file"; then
    CALL_RC=0
  else
    CALL_RC=$?
  fi
}

count_lines() {
  local file=$1
  awk 'END { print NR + 0 }' "$file"
}

assert_all_curl_outputs_are_dev_null() {
  local bad
  bad=$(awk '$5 != "output=/dev/null" { print }' "$STATE/curl.calls")
  [[ -z "$bad" ]] || fail "a curl invocation did not write /dev/null: $bad"
}

assert_all_curl_calls_have_metadata() {
  local bad
  bad=$(awk '$7 == "header=" || $8 == "write=" { print }' "$STATE/curl.calls")
  [[ -z "$bad" ]] || fail "a curl invocation lacked header/write-out metadata: $bad"
}

assert_no_worktree_response_files() {
  local candidate
  for candidate in "$REPO_ROOT"/response* "$REPO_ROOT"/download*; do
    if [[ -e "$candidate" ]]; then
      fail "response artifact appeared in worktree: $candidate"
    fi
  done
}

# Source must be inert, preserve caller shell options, and contain no wget path.
opts_before=$(set +o)
source "$RUNTIME"
opts_after=$(set +o)
assert_eq "$opts_before" "$opts_after" 'sourcing helper changed caller shell options'
assert_eq '0' "$(count_lines "$STATE/curl.calls")" 'source performed a curl call'
assert_eq '0' "$(count_lines "$STATE/wget.calls")" 'source performed a wget call'
assert_eq '0' "$(count_lines "$STATE/proxy.calls")" 'source performed a proxychains call'
assert_eq '0' "$(count_lines "$STATE/cf.calls")" 'source performed a cf_speedtest call'
runtime_text=$(<"$RUNTIME")
assert_not_contains "$runtime_text" 'wget' 'production helper still references wget'
pass 'source is inert, preserves shell options, and is curl-only'

# Configuration validation: defaults, normalization, accepted modes, and rejects.
unset DOWNLOAD_THREADS SPEEDTEST_DOWNLOAD_ONLY PROXY_CONFIG
validate_network_runtime_config
assert_eq '4' "$DOWNLOAD_THREADS" 'unset DOWNLOAD_THREADS did not default to 4'
assert_eq 'false' "$SPEEDTEST_DOWNLOAD_ONLY" 'unset SPEEDTEST_DOWNLOAD_ONLY did not default to false'
DOWNLOAD_THREADS=004
SPEEDTEST_DOWNLOAD_ONLY=true
validate_network_runtime_config
assert_eq '4' "$DOWNLOAD_THREADS" 'leading-zero DOWNLOAD_THREADS was not normalized'
assert_eq 'true' "$SPEEDTEST_DOWNLOAD_ONLY" 'true download-only mode was not accepted'
SPEEDTEST_DOWNLOAD_ONLY=false
validate_network_runtime_config
assert_eq 'false' "$SPEEDTEST_DOWNLOAD_ONLY" 'false download-only mode was not accepted'
pass 'configuration defaults, normalization, and accepted values'

for invalid_threads in 0 00 65 999 abc 4.0 +4 ''; do
  reset_fake_state
  if (DOWNLOAD_THREADS="$invalid_threads"; SPEEDTEST_DOWNLOAD_ONLY=false; run_url_download 'http://example.test/file') \
      >"$STATE/invalid-thread.out" 2>"$STATE/invalid-thread.err"; then
    fail "invalid DOWNLOAD_THREADS [$invalid_threads] was accepted"
  fi
  assert_eq '0' "$(count_lines "$STATE/curl.calls")" "invalid DOWNLOAD_THREADS [$invalid_threads] invoked curl"
  assert_eq '0' "$(count_lines "$STATE/wget.calls")" "invalid DOWNLOAD_THREADS [$invalid_threads] invoked wget"
done
pass 'invalid DOWNLOAD_THREADS values fail before network calls'

for invalid_mode in TRUE False 1 0 yes ''; do
  reset_fake_state
  if (DOWNLOAD_THREADS=4; SPEEDTEST_DOWNLOAD_ONLY="$invalid_mode"; run_cf_speedtest_direct) \
      >"$STATE/invalid-mode.out" 2>"$STATE/invalid-mode.err"; then
    fail "invalid SPEEDTEST_DOWNLOAD_ONLY [$invalid_mode] was accepted"
  fi
  assert_eq '0' "$(count_lines "$STATE/cf.calls")" "invalid mode [$invalid_mode] invoked cf_speedtest"
done
pass 'invalid SPEEDTEST_DOWNLOAD_ONLY values fail before speed tests'

# Direct URL download: one probe plus four concurrent, exact contiguous ranges.
reset_fake_state
export FAKE_TOTAL=101 FAKE_BARRIER=true FAKE_EXPECT_SEGMENTS=4
unset PROXY_CONFIG
DOWNLOAD_THREADS=4
SPEEDTEST_DOWNLOAD_ONLY=false
run_capture "$STATE/direct.out" "$STATE/direct.err" run_url_download 'http://example.test/file'
assert_eq '0' "$CALL_RC" 'direct segmented download failed'
assert_eq '5' "$(count_lines "$STATE/curl.calls")" 'direct segmented download did not make probe + 4 requests'
assert_eq '0' "$(count_lines "$STATE/wget.calls")" 'direct segmented download invoked wget'
assert_eq '0' "$(count_lines "$STATE/proxy.calls")" 'direct segmented download used proxychains4'
assert_eq '0' "$(awk '$6 != "via=0" { n++ } END { print n + 0 }' "$STATE/curl.calls")" 'direct segmented curl was not direct'
assert_eq '1' "$(awk '$2 == "kind=range" && $3 == "start=0" && $4 == "end=0" { n++ } END { print n + 0 }' "$STATE/curl.calls")" 'probe range was not exactly bytes 0-0'
assert_eq '0' "$(awk '$2 == "kind=full" { n++ } END { print n + 0 }' "$STATE/curl.calls")" 'segmented mode issued a complete download'
assert_eq $'1-25\n26-50\n51-75\n76-100' "$(awk '$2 == "kind=range" && $3 != "start=0" { sub("start=", "", $3); sub("end=", "", $4); print $3 "-" $4 }' "$STATE/curl.calls" | sort)" 'segment ranges were not exact'
awk '
  $2 == "kind=range" {
    sub("start=", "", $3); sub("end=", "", $4)
    for (i = ($3 + 0); i <= ($4 + 0); i++) seen[i]++
  }
  END {
    for (i = 0; i <= 100; i++) if (seen[i] != 1) exit 1
    for (i = 101; i <= 200; i++) if (seen[i]) exit 1
  }
' "$STATE/curl.calls" || fail 'probe + segments did not cover exactly bytes 0..100'
assert_eq '4' "$(count_lines "$STATE/barrier.calls" | awk '{ print $1 }')" 'four segment workers did not reach the barrier'
assert_not_contains "$(<"$STATE/barrier.calls")" 'barrier_failed' 'segment workers were not concurrent'
assert_contains "$(<"$STATE/direct.out")" 'total bytes=101' 'direct summary omitted total bytes'
assert_contains "$(<"$STATE/direct.out")" 'concurrent segments=4' 'direct summary omitted effective segment count'
assert_contains "$(<"$STATE/direct.out")" 'transport=direct' 'direct summary omitted transport'
assert_all_curl_outputs_are_dev_null
assert_all_curl_calls_have_metadata
assert_no_worktree_response_files
pass 'direct segmented download has exact coverage and real concurrency'

# Proxy URL download: probe and every segment must pass through proxychains4.
reset_fake_state
export FAKE_TOTAL=101 FAKE_BARRIER=true FAKE_EXPECT_SEGMENTS=4
PROXY_CONFIG="$STATE/proxy.conf"
DOWNLOAD_THREADS=4
run_capture "$STATE/proxy-url.out" "$STATE/proxy-url.err" run_url_download 'http://example.test/file'
assert_eq '0' "$CALL_RC" 'proxy segmented download failed'
assert_eq '5' "$(count_lines "$STATE/curl.calls")" 'proxy segmented download did not make probe + 4 requests'
assert_eq '0' "$(count_lines "$STATE/wget.calls")" 'proxy segmented download invoked wget'
assert_eq '5' "$(count_lines "$STATE/proxy.calls")" 'proxy segmented download did not wrap every curl'
assert_eq '0' "$(awk '$6 != "via=1" { n++ } END { print n + 0 }' "$STATE/curl.calls")" 'a proxy-mode curl was not run via proxychains4'
assert_eq '0' "$(awk '$2 == "kind=full" { n++ } END { print n + 0 }' "$STATE/curl.calls")" 'proxy segmented mode issued a complete download'
assert_contains "$(<"$STATE/proxy-url.out")" 'transport=proxy' 'proxy summary omitted transport'
assert_all_curl_outputs_are_dev_null
assert_all_curl_calls_have_metadata
assert_no_worktree_response_files
pass 'proxy segmented download wraps probe and all segments'

# DOWNLOAD_THREADS=1: exactly one complete request and no probe/range header.
reset_fake_state
unset PROXY_CONFIG
export FAKE_TOTAL=101
DOWNLOAD_THREADS=1
run_capture "$STATE/one.out" "$STATE/one.err" run_url_download 'http://example.test/file'
assert_eq '0' "$CALL_RC" 'single-thread download failed'
assert_eq '1' "$(count_lines "$STATE/curl.calls")" 'single-thread download did not issue exactly one curl'
assert_eq '0' "$(count_lines "$STATE/wget.calls")" 'single-thread download invoked wget'
assert_eq '1' "$(awk '$2 == "kind=full" { n++ } END { print n + 0 }' "$STATE/curl.calls")" 'single-thread download was not complete'
assert_eq '0' "$(awk '$2 == "kind=range" { n++ } END { print n + 0 }' "$STATE/curl.calls")" 'single-thread download issued a Range probe'
assert_contains "$(<"$STATE/one.out")" 'concurrent segments=1' 'single-thread summary omitted effective segment count'
assert_all_curl_outputs_are_dev_null
assert_all_curl_calls_have_metadata
pass 'single-thread download is one complete /dev/null request'

# Range unsupported, malformed probe, and total <= 1 are fail-closed.
reset_fake_state
export FAKE_TOTAL=101 FAKE_WGET_MODE=unsupported
DOWNLOAD_THREADS=4
unset PROXY_CONFIG
if run_url_download 'http://example.test/file' >"$STATE/unsupported.out" 2>"$STATE/unsupported.err"; then
  fail 'unsupported Range response was accepted'
fi
assert_eq '1' "$(count_lines "$STATE/curl.calls")" 'unsupported Range did not stop after probe'
assert_eq '0' "$(awk '$2 == "kind=full" { n++ } END { print n + 0 }' "$STATE/curl.calls")" 'unsupported Range triggered a complete download'

reset_fake_state
export FAKE_TOTAL=101 FAKE_WGET_MODE=malformed
if run_url_download 'http://example.test/file' >"$STATE/malformed.out" 2>"$STATE/malformed.err"; then
  fail 'malformed Content-Range response was accepted'
fi
assert_eq '1' "$(count_lines "$STATE/curl.calls")" 'malformed probe did not fail before segments'

reset_fake_state
export FAKE_TOTAL=1 FAKE_WGET_MODE=normal
if run_url_download 'http://example.test/file' >"$STATE/short.out" 2>"$STATE/short.err"; then
  fail 'total <= 1 was accepted for segmented mode'
fi
assert_eq '1' "$(count_lines "$STATE/curl.calls")" 'total <= 1 did not fail after probe'
assert_eq '0' "$(awk '$2 == "kind=full" { n++ } END { print n + 0 }' "$STATE/curl.calls")" 'total <= 1 triggered a complete download'
pass 'unsupported, malformed, and short responses fail closed'

# A worker command failure and final status/size/Content-Range mismatches fail overall.
reset_fake_state
export FAKE_TOTAL=101 FAKE_WGET_MODE=fail_range FAKE_FAIL_RANGE=51-75
if run_url_download 'http://example.test/file' >"$STATE/fail-worker.out" 2>"$STATE/fail-worker.err"; then
  fail 'segment command failure was accepted'
fi
assert_eq '5' "$(count_lines "$STATE/curl.calls")" 'segment command failure did not harvest all workers'
assert_eq '0' "$(awk '$2 == "kind=full" { n++ } END { print n + 0 }' "$STATE/curl.calls")" 'segment command failure triggered a complete download'

reset_fake_state
export FAKE_TOTAL=101 FAKE_WGET_MODE=bad_range FAKE_BAD_RANGE=26-50
if run_url_download 'http://example.test/file' >"$STATE/bad-range.out" 2>"$STATE/bad-range.err"; then
  fail 'segment Content-Range mismatch was accepted'
fi
assert_eq '5' "$(count_lines "$STATE/curl.calls")" 'Content-Range mismatch did not harvest all workers'

reset_fake_state
export FAKE_TOTAL=101 FAKE_WGET_MODE=bad_size FAKE_BAD_RANGE=26-50
if run_url_download 'http://example.test/file' >"$STATE/bad-size.out" 2>"$STATE/bad-size.err"; then
  fail 'segment size_download mismatch was accepted'
fi
assert_eq '5' "$(count_lines "$STATE/curl.calls")" 'size_download mismatch did not harvest all workers'

reset_fake_state
export FAKE_TOTAL=101 FAKE_WGET_MODE=bad_status FAKE_BAD_RANGE=26-50
if run_url_download 'http://example.test/file' >"$STATE/bad-status.out" 2>"$STATE/bad-status.err"; then
  fail 'segment HTTP status mismatch was accepted'
fi
assert_eq '5' "$(count_lines "$STATE/curl.calls")" 'status mismatch did not harvest all workers'
assert_eq '0' "$(awk '$2 == "kind=full" { n++ } END { print n + 0 }' "$STATE/curl.calls")" 'response mismatches triggered a complete download'
pass 'worker failures and response status/size/range mismatches fail overall'

# Empty URL skips without any command invocation.
reset_fake_state
export FAKE_TOTAL=101
unset PROXY_CONFIG
DOWNLOAD_THREADS=4
run_capture "$STATE/empty.out" "$STATE/empty.err" run_url_download ''
assert_eq '0' "$CALL_RC" 'empty URL was not skipped successfully'
assert_eq '0' "$(count_lines "$STATE/curl.calls")" 'empty URL invoked curl'
assert_eq '0' "$(count_lines "$STATE/wget.calls")" 'empty URL invoked wget'
assert_eq '0' "$(count_lines "$STATE/proxy.calls")" 'empty URL invoked proxychains4'
assert_contains "$(<"$STATE/empty.out")" 'skipped' 'empty URL did not emit an English skip log'
pass 'empty URL skips with zero network calls'

# Speed tests: direct both/down-only; direct never uses proxychains4.
reset_fake_state
unset PROXY_CONFIG
SPEEDTEST_DOWNLOAD_ONLY=false
run_capture "$STATE/cf-direct-both.out" "$STATE/cf-direct-both.err" run_cf_speedtest_direct --alpha beta
assert_eq '0' "$CALL_RC" 'direct both-direction cf_speedtest failed'
assert_eq '1' "$(count_lines "$STATE/cf.calls")" 'direct both-direction cf_speedtest call count wrong'
assert_eq '0' "$(count_lines "$STATE/proxy.calls")" 'direct cf_speedtest used proxychains4'
assert_contains "$(<"$STATE/cf.calls")" '--alpha beta' 'direct cf_speedtest did not preserve arguments'
assert_not_contains "$(<"$STATE/cf.calls")" '--download-only' 'both-direction cf_speedtest unexpectedly used download-only'

reset_fake_state
export PROXY_CONFIG="$STATE/proxy.conf"
SPEEDTEST_DOWNLOAD_ONLY=true
run_capture "$STATE/cf-direct-down.out" "$STATE/cf-direct-down.err" run_cf_speedtest_direct --alpha beta
assert_eq '0' "$CALL_RC" 'direct download-only cf_speedtest failed'
assert_eq '1' "$(count_lines "$STATE/cf.calls")" 'direct download-only cf_speedtest call count wrong'
assert_eq '0' "$(count_lines "$STATE/proxy.calls")" 'direct download-only cf_speedtest used proxychains4'
assert_contains "$(<"$STATE/cf.calls")" '--download-only --alpha beta' 'direct download-only flag/arguments were wrong'
pass 'direct cf_speedtest preserves args and optional download-only mode'

# Proxy speed tests: configured uses proxychains; empty config warns and skips.
reset_fake_state
export PROXY_CONFIG="$STATE/proxy.conf"
SPEEDTEST_DOWNLOAD_ONLY=true
run_capture "$STATE/cf-proxy-down.out" "$STATE/cf-proxy-down.err" run_cf_speedtest_proxy --gamma delta
assert_eq '0' "$CALL_RC" 'proxy download-only cf_speedtest failed'
assert_eq '1' "$(count_lines "$STATE/cf.calls")" 'proxy cf_speedtest call count wrong'
assert_eq '1' "$(count_lines "$STATE/proxy.calls")" 'proxy cf_speedtest did not use proxychains4'
assert_contains "$(<"$STATE/cf.calls")" 'via=1' 'proxy cf_speedtest was not proxied'
assert_contains "$(<"$STATE/cf.calls")" '--download-only --gamma delta' 'proxy download-only flag/arguments were wrong'

reset_fake_state
unset PROXY_CONFIG
SPEEDTEST_DOWNLOAD_ONLY=false
run_capture "$STATE/cf-proxy-skip.out" "$STATE/cf-proxy-skip.err" run_cf_speedtest_proxy --gamma delta
assert_eq '0' "$CALL_RC" 'empty proxy config did not skip successfully'
assert_eq '0' "$(count_lines "$STATE/cf.calls")" 'empty proxy config called cf_speedtest'
assert_eq '0' "$(count_lines "$STATE/proxy.calls")" 'empty proxy config called proxychains4'
assert_contains "$(<"$STATE/cf-proxy-skip.err")" 'WARNING: proxy speed test skipped' 'proxy skip warning was not clear English'
pass 'proxy cf_speedtest uses configured proxy or skips safely when absent'

assert_no_worktree_response_files
assert_eq '0' "$(count_lines "$STATE/wget.calls")" 'test run made a wget call'
printf 'All network-runtime tests passed.\n'
