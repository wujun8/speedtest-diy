#!/usr/bin/env bash

# Sourceable UTC runtime logger. Sourcing this file performs no output.

_runtime_log_emit() {
    local stream=$1
    local message=${2-}
    local line timestamp remaining=$message

    [[ -n $message ]] || return 0

    while [[ $remaining == *$'\n'* ]]; do
        line=${remaining%%$'\n'*}
        remaining=${remaining#*$'\n'}
        if ! timestamp=$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ'); then
            return 1
        fi
        if [[ $stream == 2 ]]; then
            printf '[%s] %s\n' "$timestamp" "$line" >&2 || return 1
        else
            printf '[%s] %s\n' "$timestamp" "$line" || return 1
        fi
    done

    if [[ -n $remaining ]]; then
        if ! timestamp=$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ'); then
            return 1
        fi
        if [[ $stream == 2 ]]; then
            printf '[%s] %s\n' "$timestamp" "$remaining" >&2 || return 1
        else
            printf '[%s] %s\n' "$timestamp" "$remaining" || return 1
        fi
    fi
}

runtime_log_info() {
    _runtime_log_emit 1 "${1-}"
}

runtime_log_warning() {
    _runtime_log_emit 2 "${1-}"
}

runtime_log_error() {
    _runtime_log_emit 2 "${1-}"
}
