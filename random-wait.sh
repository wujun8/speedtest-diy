#!/usr/bin/env bash

# Runtime helper sourced by the patched upstream entrypoint.
# The upper bound keeps shell sleep/shuf inputs inside a signed 32-bit range.
RANDOM_WAIT_MAX_SECONDS=2147483647

_random_wait_error() {
    printf 'random-wait: %s\n' "$*" >&2
}

_random_wait_validate_positive_integer() {
    local name=$1
    local value=${2-}
    local normalized

    case "$value" in
        ''|*[!0-9]*)
            _random_wait_error "$name must be a positive integer"
            return 1
            ;;
    esac

    normalized=$value
    while [ "${normalized#0}" != "$normalized" ]; do
        normalized=${normalized#0}
    done
    if [ -z "$normalized" ]; then
        normalized=0
    fi

    if [ "$normalized" = 0 ]; then
        _random_wait_error "$name must be greater than zero"
        return 1
    fi
    if [ "${#normalized}" -gt "${#RANDOM_WAIT_MAX_SECONDS}" ] || {
        [ "${#normalized}" -eq "${#RANDOM_WAIT_MAX_SECONDS}" ] &&
        [[ "$normalized" > "$RANDOM_WAIT_MAX_SECONDS" ]]
    }; then
        _random_wait_error "$name exceeds maximum ${RANDOM_WAIT_MAX_SECONDS} seconds"
        return 1
    fi

    RANDOM_WAIT_NORMALIZED=$normalized
}

validate_wait_config() {
    local minimum maximum

    # A non-empty legacy value is authoritative; random bounds are not used.
    if [ -n "${WAIT_TIME-}" ]; then
        _random_wait_validate_positive_integer WAIT_TIME "$WAIT_TIME"
        return $?
    fi

    minimum=${WAIT_TIME_MIN-5}
    maximum=${WAIT_TIME_MAX-50}
    _random_wait_validate_positive_integer WAIT_TIME_MIN "$minimum" || return 1
    minimum=$RANDOM_WAIT_NORMALIZED
    _random_wait_validate_positive_integer WAIT_TIME_MAX "$maximum" || return 1
    maximum=$RANDOM_WAIT_NORMALIZED

    if [ "${#minimum}" -gt "${#maximum}" ] || {
        [ "${#minimum}" -eq "${#maximum}" ] &&
        [[ "$minimum" > "$maximum" ]]
    }; then
        _random_wait_error 'WAIT_TIME_MIN must not exceed WAIT_TIME_MAX'
        return 1
    fi

    return 0
}

sample_wait_seconds() {
    local minimum maximum sampled

    if [ -n "${WAIT_TIME-}" ]; then
        _random_wait_validate_positive_integer WAIT_TIME "$WAIT_TIME" || return 1
        printf '%s\n' "$RANDOM_WAIT_NORMALIZED"
        return 0
    fi

    validate_wait_config || return 1
    _random_wait_validate_positive_integer WAIT_TIME_MIN "${WAIT_TIME_MIN-5}" || return 1
    minimum=$RANDOM_WAIT_NORMALIZED
    _random_wait_validate_positive_integer WAIT_TIME_MAX "${WAIT_TIME_MAX-50}" || return 1
    maximum=$RANDOM_WAIT_NORMALIZED

    if ! sampled=$(shuf -i "${minimum}-${maximum}" -n 1); then
        _random_wait_error 'shuf failed while selecting the next interval'
        return 1
    fi
    _random_wait_validate_positive_integer 'shuf result' "$sampled" || return 1
    printf '%s\n' "$RANDOM_WAIT_NORMALIZED"
}

wait_for_next_run() {
    local seconds

    seconds=$(sample_wait_seconds) || return 1
    printf 'Attente de %s secondes avant de relancer les tests...\n' "$seconds"
    sleep "$seconds" &
    sleep_pid=$!
    wait "$sleep_pid"
}
