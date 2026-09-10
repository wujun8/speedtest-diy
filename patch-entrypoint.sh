#!/usr/bin/env bash
set -euo pipefail

EXPECTED_UPSTREAM_SHA256=4ce13988639aba6ba591b5025023ef13b8db23490bbfcd96167e492a7f8e1f9d

if [ "$#" -ne 1 ]; then
    printf 'usage: %s /path/to/upstream-entrypoint.sh\n' "$0" >&2
    exit 2
fi

TARGET=$1
if [ ! -f "$TARGET" ]; then
    printf 'patch-entrypoint: entrypoint is not a regular file: %s\n' "$TARGET" >&2
    exit 1
fi

ACTUAL_UPSTREAM_SHA256=$(sha256sum -- "$TARGET" | awk '{print $1}')
if [ "$ACTUAL_UPSTREAM_SHA256" != "$EXPECTED_UPSTREAM_SHA256" ]; then
    printf 'patch-entrypoint: SHA256 mismatch (expected %s, got %s)\n' \
        "$EXPECTED_UPSTREAM_SHA256" "$ACTUAL_UPSTREAM_SHA256" >&2
    exit 1
fi

MODE=$(stat -c '%a' -- "$TARGET")
TARGET_DIR=${TARGET%/*}
if [ "$TARGET_DIR" = "$TARGET" ]; then
    TARGET_DIR=.
fi
TARGET_NAME=${TARGET##*/}
TEMP_FILE=$(mktemp "${TARGET_DIR}/.${TARGET_NAME}.patch.XXXXXX")
cleanup() {
    rm -f -- "$TEMP_FILE"
}
trap cleanup EXIT HUP INT TERM

OLD_WAIT_DEFAULT=': "${WAIT_TIME:=21600}"'
OLD_COLORS_LINE='# Définir les couleurs avec tput'
OLD_WAIT_MESSAGE='    echo -e "${CYAN}${BOLD}Attente de $((WAIT_TIME / 3600)) heures avant de relancer les tests...${RESET}"'
OLD_WAIT_SLEEP='    sleep "$WAIT_TIME" &'
OLD_WAIT_WAIT='    wait -n'

if ! awk \
    -v old_wait_default="$OLD_WAIT_DEFAULT" \
    -v old_colors_line="$OLD_COLORS_LINE" \
    -v old_wait_message="$OLD_WAIT_MESSAGE" \
    -v old_wait_sleep="$OLD_WAIT_SLEEP" \
    -v old_wait_wait="$OLD_WAIT_WAIT" '
$0 == old_wait_default {
    print ": \"${WAIT_TIME:=}\""
    wait_default_count++
    next
}
$0 == old_colors_line {
    print "# RANDOM_WAIT_PATCH_MARKER: validated random interval seam"
    print ". /usr/local/bin/random-wait.sh"
    print "if ! validate_wait_config; then"
    print "    exit 1"
    print "fi"
    print ""
    print
    source_count++
    next
}
$0 == old_wait_message {
    print "    wait_for_next_run"
    loop_echo_count++
    next
}
$0 == old_wait_sleep {
    loop_sleep_count++
    next
}
$0 == old_wait_wait {
    loop_wait_count++
    next
}
{ print }
END {
    if (wait_default_count != 1 || source_count != 1 || loop_echo_count != 1 ||
        loop_sleep_count != 1 || loop_wait_count != 1) {
        exit 17
    }
}
' "$TARGET" >"$TEMP_FILE"; then
    printf 'patch-entrypoint: expected WAIT_TIME seam was not found exactly once\n' >&2
    exit 1
fi

chmod "$MODE" -- "$TEMP_FILE"
mv -f -- "$TEMP_FILE" "$TARGET"
trap - EXIT HUP INT TERM
printf 'patch-entrypoint: patched %s\n' "$TARGET"
