#!/usr/bin/env bash
set -euo pipefail

EXPECTED_UPSTREAM_SHA256=${EXPECTED_UPSTREAM_SHA256:-4ce13988639aba6ba591b5025023ef13b8db23490bbfcd96167e492a7f8e1f9d}

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
OLD_SIGNAL_TEXT='Arrêt du script demandé. Nettoyage et sortie...'
OLD_DIRECT_START='        echo -e "${GREEN}${BOLD}Lancement du test de vitesse en direct... ($((TEST_DURATION * 2)) sec)${RESET}"'
OLD_DIRECT_ERROR='            echo -e "${RED}${BOLD}Erreur : Échec du test de vitesse en direct${RESET}"'
OLD_DIRECT_DISABLED='        echo -e "${YELLOW}${BOLD}Test de vitesse en direct désactivé.${RESET}"'
OLD_PROXY_START='        echo -e "${BLUE}${BOLD}Lancement du test de vitesse via proxychains4... ($((TEST_DURATION * 2)) sec)${RESET}"'
OLD_PROXY_ERROR='            echo -e "${RED}${BOLD}Erreur : Échec du test de vitesse via proxychains${RESET}"'
OLD_PROXY_DISABLED='        echo -e "${YELLOW}${BOLD}Test de vitesse via proxychains désactivé.${RESET}"'
OLD_DOWNLOAD_START_TEXT='Lancement du téléchargement depuis : $URL_DDL'
OLD_EMPTY_URL_TEXT='La variable URL_DDL est vide. Téléchargement annulé.'
OLD_INITIAL='echo -e "${CYAN}${BOLD}Démarrage dans 5 secondes...${RESET}"'

NEW_DIRECT_START='        echo -e "${GREEN}${BOLD}Starting direct speed test... ($((TEST_DURATION * 2)) sec)${RESET}"'
NEW_DIRECT_ERROR='            echo -e "${RED}${BOLD}Error: direct speed test failed${RESET}"'
NEW_DIRECT_DISABLED='        echo -e "${YELLOW}${BOLD}Direct speed test disabled.${RESET}"'
NEW_PROXY_START='        echo -e "${BLUE}${BOLD}Starting speed test through proxychains4... ($((TEST_DURATION * 2)) sec)${RESET}"'
NEW_PROXY_ERROR='            echo -e "${RED}${BOLD}Error: proxy speed test failed${RESET}"'
NEW_PROXY_DISABLED='        echo -e "${YELLOW}${BOLD}Proxy speed test disabled.${RESET}"'

if ! awk \
    -v old_wait_default="$OLD_WAIT_DEFAULT" \
    -v old_colors_line="$OLD_COLORS_LINE" \
    -v old_wait_message="$OLD_WAIT_MESSAGE" \
    -v old_wait_sleep="$OLD_WAIT_SLEEP" \
    -v old_wait_wait="$OLD_WAIT_WAIT" \
    -v old_signal_text="$OLD_SIGNAL_TEXT" \
    -v old_direct_start="$OLD_DIRECT_START" \
    -v old_direct_error="$OLD_DIRECT_ERROR" \
    -v old_direct_disabled="$OLD_DIRECT_DISABLED" \
    -v old_proxy_start="$OLD_PROXY_START" \
    -v old_proxy_error="$OLD_PROXY_ERROR" \
    -v old_proxy_disabled="$OLD_PROXY_DISABLED" \
    -v old_download_start_text="$OLD_DOWNLOAD_START_TEXT" \
    -v old_empty_url_text="$OLD_EMPTY_URL_TEXT" \
    -v old_initial="$OLD_INITIAL" \
    -v new_direct_start="$NEW_DIRECT_START" \
    -v new_direct_error="$NEW_DIRECT_ERROR" \
    -v new_direct_disabled="$NEW_DIRECT_DISABLED" \
    -v new_proxy_start="$NEW_PROXY_START" \
    -v new_proxy_error="$NEW_PROXY_ERROR" \
    -v new_proxy_disabled="$NEW_PROXY_DISABLED" '
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
index($0, old_signal_text) > 0 {
    print "trap " sprintf("%c", 34) "echo -e " sprintf("%c", 39) sprintf("%c", 92) "e[1;31mStop requested. Cleaning up and exiting..." sprintf("%c", 92) "e[0m" sprintf("%c", 39) "; exit 0" sprintf("%c", 34) " SIGTERM SIGINT"
    signal_count++
    next
}
$0 == old_direct_start {
    print new_direct_start
    direct_start_count++
    next
}
$0 == old_direct_error {
    print new_direct_error
    direct_error_count++
    next
}
$0 == old_direct_disabled {
    print new_direct_disabled
    direct_disabled_count++
    next
}
$0 == old_proxy_start {
    print new_proxy_start
    proxy_start_count++
    next
}
$0 == old_proxy_error {
    print new_proxy_error
    proxy_error_count++
    next
}
$0 == old_proxy_disabled {
    print new_proxy_disabled
    proxy_disabled_count++
    next
}
index($0, old_download_start_text) > 0 {
    print "        echo -e \"\\n${BLUE}${BOLD}Starting download from: $URL_DDL${RESET}\\n\""
    download_start_count++
    next
}
index($0, old_empty_url_text) > 0 {
    print "        echo -e \"\\n${YELLOW}${BOLD}URL_DDL is empty. Download skipped.${RESET}\\n\""
    empty_url_count++
    next
}
$0 == old_initial {
    print "echo -e \"${CYAN}${BOLD}Starting in 5 seconds...${RESET}\""
    initial_count++
    next
}
{ print }
END {
    if (wait_default_count != 1 || source_count != 1 || loop_echo_count != 1 ||
        loop_sleep_count != 1 || loop_wait_count != 1 || signal_count != 1 ||
        direct_start_count != 1 || direct_error_count != 1 ||
        direct_disabled_count != 1 || proxy_start_count != 1 ||
        proxy_error_count != 1 || proxy_disabled_count != 1 ||
        download_start_count != 1 || empty_url_count != 1 || initial_count != 1) {
        exit 17
    }
}
' "$TARGET" >"$TEMP_FILE"; then
    printf 'patch-entrypoint: expected upstream log and WAIT_TIME seams were not found exactly once\n' >&2
    exit 1
fi

chmod "$MODE" -- "$TEMP_FILE"
mv -f -- "$TEMP_FILE" "$TARGET"
trap - EXIT HUP INT TERM
printf 'patch-entrypoint: patched %s\n' "$TARGET"
