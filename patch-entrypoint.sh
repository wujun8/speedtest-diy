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
OLD_PROXY_DEFAULT=': "${PROXY_CONFIG:=socks5 127.0.0.1 9100}"'
OLD_PROXY_CONFIG_LINE='printf "strict_chain\nquiet_mode\nproxy_dns\nremote_dns_subnet 224\ntcp_read_time_out 15000\ntcp_connect_time_out 8000\n\n[ProxyList]\n%s\n" "$PROXY_CONFIG" > /etc/proxychains4.conf'
OLD_COLORS_LINE='# Définir les couleurs avec tput'
OLD_WAIT_MESSAGE='    echo -e "${CYAN}${BOLD}Attente de $((WAIT_TIME / 3600)) heures avant de relancer les tests...${RESET}"'
OLD_WAIT_SLEEP='    sleep "$WAIT_TIME" &'
OLD_WAIT_WAIT='    wait -n'
OLD_SIGNAL_LINE="trap \"echo -e '\\e[1;31mArrêt du script demandé. Nettoyage et sortie...\\e[0m'; exit 0\" SIGTERM SIGINT"
OLD_DIRECT_START='        echo -e "${GREEN}${BOLD}Lancement du test de vitesse en direct... ($((TEST_DURATION * 2)) sec)${RESET}"'
OLD_DIRECT_ERROR='            echo -e "${RED}${BOLD}Erreur : Échec du test de vitesse en direct${RESET}"'
OLD_DIRECT_DISABLED='        echo -e "${YELLOW}${BOLD}Test de vitesse en direct désactivé.${RESET}"'
OLD_PROXY_START='        echo -e "${BLUE}${BOLD}Lancement du test de vitesse via proxychains4... ($((TEST_DURATION * 2)) sec)${RESET}"'
OLD_PROXY_ERROR='            echo -e "${RED}${BOLD}Erreur : Échec du test de vitesse via proxychains${RESET}"'
OLD_PROXY_DISABLED='        echo -e "${YELLOW}${BOLD}Test de vitesse via proxychains désactivé.${RESET}"'
OLD_DOWNLOAD_START_LINE='        echo -e "\n${BLUE}${BOLD}Lancement du téléchargement depuis : $URL_DDL${RESET}\n"'
OLD_EMPTY_URL_LINE='        echo -e "\n${YELLOW}${BOLD}La variable URL_DDL est vide. Téléchargement annulé.${RESET}\n"'
OLD_DIRECT_COMMAND='        if ! cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"; then'
OLD_PROXY_COMMAND='        if ! proxychains4 cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"; then'
OLD_URL_COMMAND='        proxychains4 wget -O /dev/null --progress=dot:giga --no-check-certificate "$URL_DDL" 2>&1 | awk '\''/saved/ {print $0}'\'''
OLD_INITIAL='echo -e "${CYAN}${BOLD}Démarrage dans 5 secondes...${RESET}"'

AWK_OLD_SIGNAL_LINE=${OLD_SIGNAL_LINE//\\/\\\\}
AWK_OLD_DOWNLOAD_START_LINE=${OLD_DOWNLOAD_START_LINE//\\/\\\\}
AWK_OLD_EMPTY_URL_LINE=${OLD_EMPTY_URL_LINE//\\/\\\\}
AWK_OLD_PROXY_CONFIG_LINE=${OLD_PROXY_CONFIG_LINE//\\/\\\\}

NEW_DIRECT_ERROR='            echo -e "${RED}${BOLD}Error: direct speed test failed${RESET}"'
NEW_DIRECT_DISABLED='        echo -e "${YELLOW}${BOLD}Direct speed test disabled.${RESET}"'
NEW_PROXY_ERROR='            echo -e "${RED}${BOLD}Error: proxy speed test failed${RESET}"'
NEW_PROXY_DISABLED='        echo -e "${YELLOW}${BOLD}Proxy speed test disabled.${RESET}"'

if ! awk \
    -v old_wait_default="$OLD_WAIT_DEFAULT" \
    -v old_proxy_default="$OLD_PROXY_DEFAULT" \
    -v old_proxy_config="$AWK_OLD_PROXY_CONFIG_LINE" \
    -v old_colors_line="$OLD_COLORS_LINE" \
    -v old_wait_message="$OLD_WAIT_MESSAGE" \
    -v old_wait_sleep="$OLD_WAIT_SLEEP" \
    -v old_wait_wait="$OLD_WAIT_WAIT" \
    -v old_signal_line="$AWK_OLD_SIGNAL_LINE" \
    -v old_direct_start="$OLD_DIRECT_START" \
    -v old_direct_error="$OLD_DIRECT_ERROR" \
    -v old_direct_disabled="$OLD_DIRECT_DISABLED" \
    -v old_proxy_start="$OLD_PROXY_START" \
    -v old_proxy_error="$OLD_PROXY_ERROR" \
    -v old_proxy_disabled="$OLD_PROXY_DISABLED" \
    -v old_download_start_line="$AWK_OLD_DOWNLOAD_START_LINE" \
    -v old_empty_url_line="$AWK_OLD_EMPTY_URL_LINE" \
    -v old_direct_command="$OLD_DIRECT_COMMAND" \
    -v old_proxy_command="$OLD_PROXY_COMMAND" \
    -v old_url_command="$OLD_URL_COMMAND" \
    -v old_initial="$OLD_INITIAL" \
    -v new_direct_error="$NEW_DIRECT_ERROR" \
    -v new_direct_disabled="$NEW_DIRECT_DISABLED" \
    -v new_proxy_error="$NEW_PROXY_ERROR" \
    -v new_proxy_disabled="$NEW_PROXY_DISABLED" '
$0 == old_wait_default {
    print ": \"${WAIT_TIME:=}\""
    wait_default_count++
    next
}
$0 == old_proxy_default {
    print ": \"${PROXY_CONFIG:=}\""
    proxy_default_count++
    next
}
$0 == old_proxy_config {
    print "if [[ -n ${PROXY_CONFIG:-} ]]; then"
    print "    printf \"strict_chain\\nquiet_mode\\nproxy_dns\\nremote_dns_subnet 224\\ntcp_read_time_out 15000\\ntcp_connect_time_out 8000\\n\\n[ProxyList]\\n%s\\n\" \"$PROXY_CONFIG\" > /etc/proxychains4.conf"
    print "    chmod 0600 -- /etc/proxychains4.conf"
    print "fi"
    proxy_config_count++
    next
}
$0 == old_colors_line {
    print "# RANDOM_WAIT_PATCH_MARKER: validated random interval seam"
    print ". /usr/local/bin/random-wait.sh"
    print ". /usr/local/bin/network-runtime.sh"
    print "if ! validate_wait_config; then"
    print "    exit 1"
    print "fi"
    print "if ! validate_network_runtime_config; then"
    print "    exit 1"
    print "fi"
    print ""
    print
    source_count++
    network_source_count++
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
$0 == old_signal_line {
    print "trap " sprintf("%c", 34) "cancel_network_runtime; echo " sprintf("%c", 39) "Stop requested. Cleaning up and exiting..." sprintf("%c", 39) "; exit 0" sprintf("%c", 34) " SIGTERM SIGINT"
    signal_count++
    next
}
$0 == old_direct_start {
    print "        if [ \"$SPEEDTEST_DOWNLOAD_ONLY\" = \"true\" ]; then"
    print "            echo -e \"${GREEN}${BOLD}Starting direct speed test (download-only, ${TEST_DURATION} sec)${RESET}\""
    print "        else"
    print "            echo -e \"${GREEN}${BOLD}Starting direct speed test (download and upload, ${TEST_DURATION} sec per direction)${RESET}\""
    print "        fi"
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
    print "        if [ -n \"${PROXY_CONFIG:-}\" ]; then"
    print "            if [ \"$SPEEDTEST_DOWNLOAD_ONLY\" = \"true\" ]; then"
    print "                echo -e \"${BLUE}${BOLD}Starting speed test through proxychains4 (download-only, ${TEST_DURATION} sec)${RESET}\""
    print "            else"
    print "                echo -e \"${BLUE}${BOLD}Starting speed test through proxychains4 (download and upload, ${TEST_DURATION} sec per direction)${RESET}\""
    print "            fi"
    print "        fi"
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
$0 == old_download_start_line {
    print "        echo -e \"${BLUE}${BOLD}Starting URL download...${RESET}\""
    download_start_count++
    next
}
$0 == old_empty_url_line {
    print "        echo -e \"${YELLOW}${BOLD}URL_DDL is empty. Download skipped.${RESET}\""
    empty_url_count++
    next
}
$0 == old_direct_command {
    print "        if ! run_cf_speedtest_direct --test-duration-seconds \"$TEST_DURATION\" --download-threads \"$DOWNLOAD_THREADS\" --upload-threads \"$UPLOAD_THREADS\"; then"
    direct_command_count++
    next
}
$0 == old_proxy_command {
    print "        if ! run_cf_speedtest_proxy --test-duration-seconds \"$TEST_DURATION\" --download-threads \"$DOWNLOAD_THREADS\" --upload-threads \"$UPLOAD_THREADS\"; then"
    proxy_command_count++
    next
}
$0 == old_url_command {
    print "        if ! run_url_download \"$URL_DDL\"; then"
    print "            echo -e \"${RED}${BOLD}Error: URL download failed; continuing.${RESET}\""
    print "        fi"
    url_command_count++
    next
}
$0 == old_initial {
    print "echo -e \"${CYAN}${BOLD}Starting in 5 seconds...${RESET}\""
    initial_count++
    next
}
{ print }
END {
    if (wait_default_count != 1 || proxy_default_count != 1 ||
        proxy_config_count != 1 || source_count != 1 ||
        network_source_count != 1 || loop_echo_count != 1 ||
        loop_sleep_count != 1 || loop_wait_count != 1 || signal_count != 1 ||
        direct_start_count != 1 || direct_error_count != 1 ||
        direct_disabled_count != 1 || proxy_start_count != 1 ||
        proxy_error_count != 1 || proxy_disabled_count != 1 ||
        download_start_count != 1 || empty_url_count != 1 ||
        direct_command_count != 1 || proxy_command_count != 1 ||
        url_command_count != 1 || initial_count != 1) {
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
