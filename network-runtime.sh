#!/usr/bin/env bash

# Sourceable network runtime helpers. Sourcing this file performs no network I/O.

_nr_normalize_decimal() {
  local value=${1-}

  if [[ ! $value =~ ^[0-9]+$ ]]; then
    return 1
  fi
  while [[ ${#value} -gt 1 && $value == 0* ]]; do
    value=${value#0}
  done
  printf '%s\n' "$value"
}

validate_network_runtime_config() {
  local raw canonical mode

  if [[ ${DOWNLOAD_THREADS+x} != x ]]; then
    DOWNLOAD_THREADS=4
  else
    raw=$DOWNLOAD_THREADS
    if [[ ! $raw =~ ^[0-9]+$ ]]; then
      printf 'ERROR: invalid DOWNLOAD_THREADS; expected a decimal integer from 1 to 64.\n' >&2
      return 2
    fi
    if ! canonical=$(_nr_normalize_decimal "$raw"); then
      printf 'ERROR: invalid DOWNLOAD_THREADS; expected a decimal integer from 1 to 64.\n' >&2
      return 2
    fi
    if [[ $canonical == 0 || ${#canonical} -gt 2 || \
          ( ${#canonical} -eq 2 && $canonical > 64 ) ]]; then
      printf 'ERROR: invalid DOWNLOAD_THREADS; expected a decimal integer from 1 to 64.\n' >&2
      return 2
    fi
    DOWNLOAD_THREADS=$((10#$canonical))
  fi

  if [[ ${SPEEDTEST_DOWNLOAD_ONLY+x} != x ]]; then
    SPEEDTEST_DOWNLOAD_ONLY=false
  else
    mode=$SPEEDTEST_DOWNLOAD_ONLY
    if [[ $mode != true && $mode != false ]]; then
      printf 'ERROR: invalid SPEEDTEST_DOWNLOAD_ONLY; expected exact true or false.\n' >&2
      return 2
    fi
  fi
  return 0
}

_nr_remove_files() {
  local file
  for file in "$@"; do
    if [[ -n $file ]]; then
      rm -f -- "$file" 2>/dev/null || :
    fi
  done
}

_nr_run_curl() {
  local header_file=$1
  local metadata_file=$2
  local url=$3
  local range=${4-}
  local -a curl_args

  curl_args=(--fail --location)
  if [[ -n $range ]]; then
    curl_args+=(--range "$range")
  fi
  curl_args+=(
    --output /dev/null
    --dump-header "$header_file"
    --write-out '%{http_code}\t%{size_download}\n'
    "$url"
  )

  if [[ -n ${PROXY_CONFIG:-} ]]; then
    PROXYCHAINS_CONF_FILE="$PROXY_CONFIG" proxychains4 curl "${curl_args[@]}" >"$metadata_file"
  else
    curl "${curl_args[@]}" >"$metadata_file"
  fi
}

_nr_parse_curl_metadata() {
  local metadata_file=$1
  local metadata

  if [[ ! -f $metadata_file ]]; then
    printf 'ERROR: curl did not produce HTTP metadata.\n' >&2
    return 1
  fi
  metadata=$(<"$metadata_file")
  if [[ ! $metadata =~ ^([0-9][0-9][0-9])$'\t'([0-9]+)$ ]]; then
    printf 'ERROR: curl produced malformed HTTP metadata.\n' >&2
    return 1
  fi
  printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

_nr_final_header_metadata() {
  local header_file=$1

  awk '
    function commit_response() {
      if (current_status != "") {
        final_status = current_status
        final_range = current_range
      }
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if ($1 ~ /^HTTP\/[0-9.]+$/ && $2 ~ /^[0-9][0-9][0-9]$/) {
        commit_response()
        current_status = $2
        current_range = ""
      } else if (tolower($1) == "content-range:") {
        value = line
        sub(/^[^:]*:[[:space:]]*/, "", value)
        current_range = value
      }
    }
    END {
      commit_response()
      if (final_status == "") {
        exit 1
      }
      printf "%s\t%s\n", final_status, final_range
    }
  ' "$header_file"
}

_nr_validate_probe_response() {
  local header_file=$1
  local metadata_file=$2
  local metadata meta_status meta_size header_metadata header_status content_range
  local raw_start raw_end raw_total total

  if ! metadata=$(_nr_parse_curl_metadata "$metadata_file"); then
    return 1
  fi
  meta_status=${metadata%%$'\t'*}
  meta_size=${metadata#*$'\t'}
  if [[ $meta_status != 206 || $meta_size != 1 ]]; then
    printf 'ERROR: Range probe requires final HTTP 206 with size_download 1.\n' >&2
    return 1
  fi

  if ! header_metadata=$(_nr_final_header_metadata "$header_file"); then
    printf 'ERROR: Range probe response headers are missing or malformed.\n' >&2
    return 1
  fi
  header_status=${header_metadata%%$'\t'*}
  content_range=${header_metadata#*$'\t'}
  if [[ $header_status != 206 ]]; then
    printf 'ERROR: Range probe final HTTP status was not 206.\n' >&2
    return 1
  fi
  if [[ ! $content_range =~ ^bytes[[:space:]]+([0-9]+)-([0-9]+)/([0-9]+)$ ]]; then
    printf 'ERROR: Range probe Content-Range is malformed.\n' >&2
    return 1
  fi
  raw_start=${BASH_REMATCH[1]}
  raw_end=${BASH_REMATCH[2]}
  raw_total=${BASH_REMATCH[3]}
  if ! raw_start=$(_nr_normalize_decimal "$raw_start") || \
     ! raw_end=$(_nr_normalize_decimal "$raw_end") || \
     ! total=$(_nr_normalize_decimal "$raw_total"); then
    printf 'ERROR: Range probe Content-Range contains an invalid decimal value.\n' >&2
    return 1
  fi
  if [[ $raw_start != 0 || $raw_end != 0 ]]; then
    printf 'ERROR: Range probe Content-Range was not exactly bytes 0-0/TOTAL.\n' >&2
    return 1
  fi
  if [[ $total == 0 || $total == 1 ]]; then
    printf 'ERROR: Range probe reported a total length of %s; segmented download requires more than 1 byte.\n' "$total" >&2
    return 1
  fi
  printf '%s\n' "$total"
}

_nr_validate_segment_response() {
  local header_file=$1
  local metadata_file=$2
  local expected_start=$3
  local expected_end=$4
  local expected_total=$5
  local metadata meta_status meta_size header_metadata header_status content_range
  local raw_start raw_end raw_total actual_start actual_end actual_total expected_size

  if ! metadata=$(_nr_parse_curl_metadata "$metadata_file"); then
    return 1
  fi
  meta_status=${metadata%%$'\t'*}
  meta_size=${metadata#*$'\t'}
  expected_size=$((expected_end - expected_start + 1))
  if [[ $meta_status != 206 || $meta_size != "$expected_size" ]]; then
    printf 'ERROR: segment bytes %s-%s requires final HTTP 206 and size_download %s.\n' \
      "$expected_start" "$expected_end" "$expected_size" >&2
    return 1
  fi

  if ! header_metadata=$(_nr_final_header_metadata "$header_file"); then
    printf 'ERROR: segment bytes %s-%s response headers are missing or malformed.\n' \
      "$expected_start" "$expected_end" >&2
    return 1
  fi
  header_status=${header_metadata%%$'\t'*}
  content_range=${header_metadata#*$'\t'}
  if [[ $header_status != 206 ]]; then
    printf 'ERROR: segment bytes %s-%s final HTTP status was not 206.\n' \
      "$expected_start" "$expected_end" >&2
    return 1
  fi
  if [[ ! $content_range =~ ^bytes[[:space:]]+([0-9]+)-([0-9]+)/([0-9]+)$ ]]; then
    printf 'ERROR: segment bytes %s-%s Content-Range is malformed.\n' \
      "$expected_start" "$expected_end" >&2
    return 1
  fi
  raw_start=${BASH_REMATCH[1]}
  raw_end=${BASH_REMATCH[2]}
  raw_total=${BASH_REMATCH[3]}
  if ! actual_start=$(_nr_normalize_decimal "$raw_start") || \
     ! actual_end=$(_nr_normalize_decimal "$raw_end") || \
     ! actual_total=$(_nr_normalize_decimal "$raw_total"); then
    printf 'ERROR: segment bytes %s-%s Content-Range contains an invalid decimal value.\n' \
      "$expected_start" "$expected_end" >&2
    return 1
  fi
  if [[ $actual_start != "$expected_start" || $actual_end != "$expected_end" || \
        $actual_total != "$expected_total" ]]; then
    printf 'ERROR: segment Content-Range mismatch; expected bytes %s-%s/%s.\n' \
      "$expected_start" "$expected_end" "$expected_total" >&2
    return 1
  fi
  return 0
}

_nr_download_segment() {
  local url=$1
  local start=$2
  local end=$3
  local total=$4
  local header_file=$5
  local metadata_file=$6

  if ! _nr_run_curl "$header_file" "$metadata_file" "$url" "$start-$end"; then
    printf 'ERROR: URL segment bytes %s-%s curl command failed.\n' "$start" "$end" >&2
    return 1
  fi
  if ! _nr_validate_segment_response "$header_file" "$metadata_file" "$start" "$end" "$total"; then
    return 1
  fi
  return 0
}

run_url_download() {
  local url=${1-}
  local transport=direct
  local temp_prefix
  local probe_header probe_metadata total
  local full_header full_metadata
  local remaining segment_count base extra cursor i length start end
  local overall=0 pid
  local -a pids=() segment_headers=() segment_metadata=()

  if [[ -z $url ]]; then
    printf 'URL download skipped: URL is empty.\n'
    return 0
  fi
  if ! validate_network_runtime_config; then
    return 2
  fi
  if [[ -n ${PROXY_CONFIG:-} ]]; then
    transport=proxy
  fi

  temp_prefix="${TMPDIR:-/tmp}/network-runtime.$$.$RANDOM"

  if (( DOWNLOAD_THREADS == 1 )); then
    full_header="$temp_prefix.full.headers"
    full_metadata="$temp_prefix.full.metadata"
    _nr_remove_files "$full_header" "$full_metadata"
    if ! _nr_run_curl "$full_header" "$full_metadata" "$url" ''; then
      _nr_remove_files "$full_header" "$full_metadata"
      printf 'ERROR: complete URL download failed.\n' >&2
      return 1
    fi
    if ! total=$(_nr_validate_full_response "$full_metadata"); then
      _nr_remove_files "$full_header" "$full_metadata"
      printf 'ERROR: complete URL download returned invalid HTTP metadata.\n' >&2
      return 1
    fi
    _nr_remove_files "$full_header" "$full_metadata"
    printf 'URL download complete: total bytes=%s, concurrent segments=1, transport=%s\n' \
      "$total" "$transport"
    return 0
  fi

  probe_header="$temp_prefix.probe.headers"
  probe_metadata="$temp_prefix.probe.metadata"
  _nr_remove_files "$probe_header" "$probe_metadata"
  if ! _nr_run_curl "$probe_header" "$probe_metadata" "$url" '0-0'; then
    _nr_remove_files "$probe_header" "$probe_metadata"
    printf 'ERROR: Range probe curl command failed; refusing segmented download.\n' >&2
    return 1
  fi
  if ! total=$(_nr_validate_probe_response "$probe_header" "$probe_metadata"); then
    _nr_remove_files "$probe_header" "$probe_metadata"
    printf 'ERROR: Range probe validation failed; refusing segmented download.\n' >&2
    return 1
  fi
  _nr_remove_files "$probe_header" "$probe_metadata"

  remaining=$((total - 1))
  segment_count=$DOWNLOAD_THREADS
  if (( segment_count > remaining )); then
    segment_count=$remaining
  fi
  base=$((remaining / segment_count))
  extra=$((remaining % segment_count))
  cursor=1

  for ((i = 0; i < segment_count; i++)); do
    length=$base
    if (( i < extra )); then
      length=$((length + 1))
    fi
    start=$cursor
    end=$((cursor + length - 1))
    segment_headers[i]="$temp_prefix.segment.$i.headers"
    segment_metadata[i]="$temp_prefix.segment.$i.metadata"
    _nr_remove_files "${segment_headers[i]}" "${segment_metadata[i]}"
    _nr_download_segment "$url" "$start" "$end" "$total" \
      "${segment_headers[i]}" "${segment_metadata[i]}" &
    pids[i]=$!
    cursor=$((end + 1))
  done

  for pid in "${pids[@]}"; do
    if wait "$pid"; then
      :
    else
      overall=1
    fi
  done

  _nr_remove_files "$probe_header" "$probe_metadata"
  for ((i = 0; i < segment_count; i++)); do
    _nr_remove_files "${segment_headers[i]}" "${segment_metadata[i]}"
  done

  if (( overall != 0 )); then
    printf 'ERROR: one or more URL range segments failed; download aborted.\n' >&2
    return 1
  fi
  printf 'URL download complete: total bytes=%s, concurrent segments=%s, transport=%s\n' \
    "$total" "$segment_count" "$transport"
  return 0
}

run_cf_speedtest_direct() {
  if ! validate_network_runtime_config; then
    return 2
  fi
  if [[ $SPEEDTEST_DOWNLOAD_ONLY == true ]]; then
    cf_speedtest --download-only "$@"
  else
    cf_speedtest "$@"
  fi
}

run_cf_speedtest_proxy() {
  if ! validate_network_runtime_config; then
    return 2
  fi
  if [[ -z ${PROXY_CONFIG:-} ]]; then
    printf 'WARNING: proxy speed test skipped: PROXY_CONFIG is empty or unset.\n' >&2
    return 0
  fi
  if [[ $SPEEDTEST_DOWNLOAD_ONLY == true ]]; then
    PROXYCHAINS_CONF_FILE="$PROXY_CONFIG" proxychains4 cf_speedtest --download-only "$@"
  else
    PROXYCHAINS_CONF_FILE="$PROXY_CONFIG" proxychains4 cf_speedtest "$@"
  fi
}

_nr_validate_full_response() {
  local metadata_file=$1
  local metadata status size

  if ! metadata=$(_nr_parse_curl_metadata "$metadata_file"); then
    return 1
  fi
  status=${metadata%%$'\t'*}
  size=${metadata#*$'\t'}
  if [[ $status != 2[0-9][0-9] ]]; then
    printf 'ERROR: complete URL download did not return a successful HTTP status.\n' >&2
    return 1
  fi
  printf '%s\n' "$size"
}
