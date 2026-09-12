#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
EXPECTED_SHA=4ce13988639aba6ba591b5025023ef13b8db23490bbfcd96167e492a7f8e1f9d

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

assert_contains_file() {
    local file=$1 needle=$2 label=$3
    if ! grep -Fq -- "$needle" "$file"; then
        fail "$label (missing '$needle')"
        return 1
    fi
}

assert_not_contains_file() {
    local file=$1 needle=$2 label=$3
    if grep -Fq -- "$needle" "$file"; then
        fail "$label (unexpected '$needle')"
        return 1
    fi
}

assert_line_exactly_once() {
    local file=$1 needle=$2 label=$3 count
    count=$(grep -Fxc -- "$needle" "$file")
    if [ "$count" != 1 ]; then
        fail "$label (expected exactly one line, got $count)"
        return 1
    fi
}

if [ ! -x "$ROOT/patch-entrypoint.sh" ]; then
    fail "patch-entrypoint.sh is missing or not executable"
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT
SYNTHETIC_FIXTURE=$TMP_DIR/upstream-entrypoint.sh
cat >"$SYNTHETIC_FIXTURE" <<'EOF'
#!/bin/bash

: "${WAIT_TIME:=21600}"
: "${PROXY_CONFIG:=socks5 127.0.0.1 9100}"
: "${TEST_DURATION:=10}"
: "${DOWNLOAD_THREADS:=4}"
: "${UPLOAD_THREADS:=4}"
: "${SPEEDTEST_DOWNLOAD_BYTES:=10485760}"
: "${SPEEDTEST_UPLOAD_BYTES:=10485760}"
: "${SPEEDTEST_DOWNLOAD_ONLY:=false}"
: "${RUN_SPEEDTEST_DIRECT:=true}"
: "${RUN_SPEEDTEST_PROXY:=true}"
: "${URL_DDL:=}"

# Gestion des signaux d'arrêt
trap "echo -e '\e[1;31mArrêt du script demandé. Nettoyage et sortie...\e[0m'; exit 0" SIGTERM SIGINT

# Définir les couleurs avec tput
printf "strict_chain\nquiet_mode\nproxy_dns\nremote_dns_subnet 224\ntcp_read_time_out 15000\ntcp_connect_time_out 8000\n\n[ProxyList]\n%s\n" "$PROXY_CONFIG" > /etc/proxychains4.conf
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4)
CYAN=$(tput setaf 6)
MAGENTA=$(tput setaf 5)
BOLD=$(tput bold)
RESET=$(tput sgr0)

run_speedtest_direct() {
    if [ "$RUN_SPEEDTEST_DIRECT" = "true" ]; then
        echo -e "${GREEN}${BOLD}Lancement du test de vitesse en direct... ($((TEST_DURATION * 2)) sec)${RESET}"
        if ! cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"; then
            echo -e "${RED}${BOLD}Erreur : Échec du test de vitesse en direct${RESET}"
        fi
    else
        echo -e "${YELLOW}${BOLD}Test de vitesse en direct désactivé.${RESET}"
    fi
}

run_speedtest_proxy() {
    if [ "$RUN_SPEEDTEST_PROXY" = "true" ]; then
        echo -e "${BLUE}${BOLD}Lancement du test de vitesse via proxychains4... ($((TEST_DURATION * 2)) sec)${RESET}"
        if ! proxychains4 cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"; then
            echo -e "${RED}${BOLD}Erreur : Échec du test de vitesse via proxychains${RESET}"
        fi
    else
        echo -e "${YELLOW}${BOLD}Test de vitesse via proxychains désactivé.${RESET}"
    fi
}

run_ddl() {
    if [ -n "$URL_DDL" ]; then
        echo -e "\n${BLUE}${BOLD}Lancement du téléchargement depuis : $URL_DDL${RESET}\n"
        proxychains4 wget -O /dev/null --progress=dot:giga --no-check-certificate "$URL_DDL" 2>&1 | awk '/saved/ {print $0}'
    else
        echo -e "\n${YELLOW}${BOLD}La variable URL_DDL est vide. Téléchargement annulé.${RESET}\n"
    fi
}

echo -e "${CYAN}${BOLD}Démarrage dans 5 secondes...${RESET}"
sleep 5

while true; do
    echo -e "${CYAN}${BOLD}Attente de $((WAIT_TIME / 3600)) heures avant de relancer les tests...${RESET}"
    sleep "$WAIT_TIME" &
    wait -n
    run_speedtest_direct
    run_speedtest_proxy
    run_ddl
done
EOF
chmod 755 "$SYNTHETIC_FIXTURE"

OLD_WAIT_DEFAULT=': "${WAIT_TIME:=21600}"'
OLD_PROXY_DEFAULT=': "${PROXY_CONFIG:=socks5 127.0.0.1 9100}"'
OLD_PROXY_CONFIG='printf "strict_chain\nquiet_mode\nproxy_dns\nremote_dns_subnet 224\ntcp_read_time_out 15000\ntcp_connect_time_out 8000\n\n[ProxyList]\n%s\n" "$PROXY_CONFIG" > /etc/proxychains4.conf'
OLD_COLORS_LINE='# Définir les couleurs avec tput'
OLD_INITIAL_SLEEP='sleep 5'
OLD_DIRECT_SPEEDTEST='        if ! cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"; then'
OLD_PROXY_SPEEDTEST='        if ! proxychains4 cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"; then'
OLD_URL_DDL='        proxychains4 wget -O /dev/null --progress=dot:giga --no-check-certificate "$URL_DDL" 2>&1 | awk '\''/saved/ {print $0}'\'''
OLD_DIRECT_COMMAND="$OLD_DIRECT_SPEEDTEST"
OLD_PROXY_COMMAND="$OLD_PROXY_SPEEDTEST"
OLD_URL_COMMAND="$OLD_URL_DDL"
OLD_DIRECT_TOGGLE_DEFAULT=': "${RUN_SPEEDTEST_DIRECT:=true}"'
OLD_PROXY_TOGGLE_DEFAULT=': "${RUN_SPEEDTEST_PROXY:=true}"'
OLD_WAIT_MESSAGE='    echo -e "${CYAN}${BOLD}Attente de $((WAIT_TIME / 3600)) heures avant de relancer les tests...${RESET}"'
OLD_WAIT_SLEEP='    sleep "$WAIT_TIME" &'
OLD_WAIT_WAIT='    wait -n'

OLD_SIGNAL_TEXT='Arrêt du script demandé. Nettoyage et sortie...'
OLD_DIRECT_START_TEXT='Lancement du test de vitesse en direct...'
OLD_DIRECT_ERROR_TEXT='Erreur : Échec du test de vitesse en direct'
OLD_DIRECT_DISABLED_TEXT='Test de vitesse en direct désactivé.'
OLD_PROXY_START_TEXT='Lancement du test de vitesse via proxychains4...'
OLD_PROXY_ERROR_TEXT='Erreur : Échec du test de vitesse via proxychains'
OLD_PROXY_DISABLED_TEXT='Test de vitesse via proxychains désactivé.'
OLD_DOWNLOAD_START_TEXT='Lancement du téléchargement depuis : $URL_DDL'
OLD_EMPTY_URL_TEXT='La variable URL_DDL est vide. Téléchargement annulé.'
OLD_INITIAL_TEXT='Démarrage dans 5 secondes...'

OLD_SIGNAL="trap \"echo -e '\\e[1;31m${OLD_SIGNAL_TEXT}\\e[0m'; exit 0\" SIGTERM SIGINT"
OLD_SIGNAL_LINE=$OLD_SIGNAL
OLD_DOWNLOAD_START_LINE="        echo -e \"\\n\${BLUE}\${BOLD}${OLD_DOWNLOAD_START_TEXT}\${RESET}\\n\""
OLD_EMPTY_URL_LINE="        echo -e \"\\n\${YELLOW}\${BOLD}${OLD_EMPTY_URL_TEXT}\${RESET}\\n\""
NEW_LOGGER_SOURCE='. /usr/local/bin/runtime-log.sh'
NEW_SIGNAL_TEXT='Stop requested. Cleaning up and exiting...'
NEW_DIRECT_ERROR_TEXT='Error: direct speed test failed'
NEW_DIRECT_DISABLED_TEXT='Direct speed test disabled.'
NEW_PROXY_ERROR_TEXT='Error: proxy speed test failed'
NEW_PROXY_DISABLED_TEXT='Proxy speed test disabled.'
NEW_DOWNLOAD_START_TEXT='Starting URL download...'
NEW_EMPTY_URL_TEXT='URL_DDL is empty. Download skipped.'
NEW_INITIAL_TEXT='Starting in 5 seconds...'
NEW_DIRECT_DOWNLOAD_ONLY='Starting direct speed test (download-only, ${TEST_DURATION} sec)'
NEW_DIRECT_BOTH='Starting direct speed test (download and upload, ${TEST_DURATION} sec per direction)'
NEW_PROXY_DOWNLOAD_ONLY='Starting speed test through proxychains4 (download-only, ${TEST_DURATION} sec)'
NEW_PROXY_BOTH='Starting speed test through proxychains4 (download and upload, ${TEST_DURATION} sec per direction)'
NEW_DIRECT_COMMAND='        if ! run_cf_speedtest_direct --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS" --bytes-to-download "$SPEEDTEST_DOWNLOAD_BYTES" --bytes-to-upload "$SPEEDTEST_UPLOAD_BYTES"; then'
NEW_PROXY_COMMAND='        if ! run_cf_speedtest_proxy --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS" --bytes-to-download "$SPEEDTEST_DOWNLOAD_BYTES" --bytes-to-upload "$SPEEDTEST_UPLOAD_BYTES"; then'
NEW_URL_COMMAND='        if ! run_url_download "$URL_DDL"; then'
NEW_DIRECT_TOGGLE_DEFAULT=': "${RUN_SPEEDTEST_DIRECT:=false}"'
NEW_PROXY_TOGGLE_DEFAULT=': "${RUN_SPEEDTEST_PROXY:=false}"'
NEW_INITIAL='runtime_log_info "${CYAN}${BOLD}Starting in 5 seconds...${RESET}"'

assert_logger_message() {
    local file=$1 symbol=$2 message=$3 label=$4 matches count
    matches=$(grep -F -- "$message" "$file" || true)
    count=$(printf '%s\n' "$matches" | grep -Fc -- "$message" || true)
    if [ "$count" -ne 1 ]; then
        fail "$label (expected one message line, got $count)"
        return 1
    fi
    if ! printf '%s\n' "$matches" | grep -Fq -- "$symbol"; then
        fail "$label is not emitted through $symbol"
        return 1
    fi
}

assert_colored_logger_message() {
    local file=$1 symbol=$2 color=$3 message=$4 label=$5 line matches
    matches=$(grep -F -- "$message" "$file" || true)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            *"$symbol"*"$color"*) return 0 ;;
        esac
    done <<<"$matches"
    fail "$label does not place its color after $symbol"
    return 1
}

assert_translated_messages() {
    local file=$1 label=$2 forbidden direct_printf line
    assert_logger_message "$file" runtime_log_info "$NEW_SIGNAL_TEXT" "$label signal log" || return 1
    assert_logger_message "$file" runtime_log_error "$NEW_DIRECT_ERROR_TEXT" "$label direct-error log" || return 1
    assert_logger_message "$file" runtime_log_warning "$NEW_DIRECT_DISABLED_TEXT" "$label direct-disabled log" || return 1
    assert_logger_message "$file" runtime_log_error "$NEW_PROXY_ERROR_TEXT" "$label proxy-error log" || return 1
    assert_logger_message "$file" runtime_log_warning "$NEW_PROXY_DISABLED_TEXT" "$label proxy-disabled log" || return 1
    assert_logger_message "$file" runtime_log_info "$NEW_DOWNLOAD_START_TEXT" "$label download-start log" || return 1
    assert_logger_message "$file" runtime_log_warning "$NEW_EMPTY_URL_TEXT" "$label empty-URL log" || return 1
    assert_logger_message "$file" runtime_log_info "$NEW_INITIAL_TEXT" "$label initial log" || return 1
    assert_logger_message "$file" runtime_log_error 'Error: URL download failed; continuing.' "$label URL-error log" || return 1
    assert_logger_message "$file" runtime_log_error 'Error: failed to write proxy configuration.' "$label proxy-config-error log" || return 1

    for message in "$NEW_DIRECT_DOWNLOAD_ONLY" "$NEW_DIRECT_BOTH"; do
        assert_logger_message "$file" runtime_log_info "$message" "$label direct start log" || return 1
    done
    for message in "$NEW_PROXY_DOWNLOAD_ONLY" "$NEW_PROXY_BOTH"; do
        assert_logger_message "$file" runtime_log_info "$message" "$label proxy start log" || return 1
    done

    assert_colored_logger_message "$file" runtime_log_info '${GREEN}' "$NEW_DIRECT_DOWNLOAD_ONLY" "$label direct download-only color order" || return 1
    assert_colored_logger_message "$file" runtime_log_info '${GREEN}' "$NEW_DIRECT_BOTH" "$label direct both-direction color order" || return 1
    assert_colored_logger_message "$file" runtime_log_error '${RED}' "$NEW_DIRECT_ERROR_TEXT" "$label direct error color order" || return 1
    assert_colored_logger_message "$file" runtime_log_warning '${YELLOW}' "$NEW_DIRECT_DISABLED_TEXT" "$label direct disabled color order" || return 1
    assert_colored_logger_message "$file" runtime_log_info '${BLUE}' "$NEW_PROXY_DOWNLOAD_ONLY" "$label proxy download-only color order" || return 1
    assert_colored_logger_message "$file" runtime_log_info '${BLUE}' "$NEW_PROXY_BOTH" "$label proxy both-direction color order" || return 1
    assert_colored_logger_message "$file" runtime_log_error '${RED}' "$NEW_PROXY_ERROR_TEXT" "$label proxy error color order" || return 1
    assert_colored_logger_message "$file" runtime_log_warning '${YELLOW}' "$NEW_PROXY_DISABLED_TEXT" "$label proxy disabled color order" || return 1
    assert_colored_logger_message "$file" runtime_log_info '${BLUE}' "$NEW_DOWNLOAD_START_TEXT" "$label URL start color order" || return 1
    assert_colored_logger_message "$file" runtime_log_warning '${YELLOW}' "$NEW_EMPTY_URL_TEXT" "$label empty URL color order" || return 1
    assert_colored_logger_message "$file" runtime_log_info '${CYAN}' "$NEW_INITIAL_TEXT" "$label initial color order" || return 1

    if grep -nF -- 'echo -e' "$file"; then
        fail "$label still contains a direct generated echo"
        return 1
    fi
    if grep -nE 'runtime_log_(info|warning|error).*cf_speedtest|cf_speedtest.*runtime_log_(info|warning|error)' "$file"; then
        fail "$label wraps cf_speedtest child output in the runtime logger"
        return 1
    fi
    direct_printf=$(grep -nE '^[[:space:]]*printf[[:space:]]' "$file" || true)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            *'/etc/proxychains4.conf'*) ;;
            *)
                fail "$label contains a direct generated printf: $line"
                return 1
                ;;
        esac
    done <<<"$direct_printf"

    for forbidden in \
        "$OLD_SIGNAL_TEXT" \
        "$OLD_DIRECT_START_TEXT" \
        "$OLD_DIRECT_ERROR_TEXT" \
        "$OLD_DIRECT_DISABLED_TEXT" \
        "$OLD_PROXY_START_TEXT" \
        "$OLD_PROXY_ERROR_TEXT" \
        "$OLD_PROXY_DISABLED_TEXT" \
        "$OLD_DOWNLOAD_START_TEXT" \
        "$OLD_EMPTY_URL_TEXT" \
        "$OLD_INITIAL_TEXT" \
        'Attente de'; do
        assert_not_contains_file "$file" "$forbidden" "$label French user-visible log" || return 1
    done
}


assert_generated_runtime_anchors() {
    local file=$1 label=$2 config_guard_line direct_function_line proxy_function_line download_function_line logger_source_line random_source_line network_source_line
    assert_line_exactly_once "$file" "$NEW_LOGGER_SOURCE" "$label runtime logger source count" || return 1
    assert_line_exactly_once "$file" '. /usr/local/bin/random-wait.sh' "$label random helper source count" || return 1
    assert_line_exactly_once "$file" '. /usr/local/bin/network-runtime.sh' "$label network helper source count" || return 1
    assert_line_exactly_once "$file" 'if ! validate_wait_config; then' "$label wait preflight count" || return 1
    assert_line_exactly_once "$file" 'if ! validate_network_runtime_config; then' "$label network preflight count" || return 1
    assert_line_exactly_once "$file" 'if [[ -n ${PROXY_CONFIG:-} ]]; then' "$label config conditional count" || return 1
    assert_line_exactly_once "$file" '    if ! (' "$label config write failure guard" || return 1
    assert_line_exactly_once "$file" '        umask 077 &&' "$label private config umask" || return 1
    assert_line_exactly_once "$file" '        printf "strict_chain\nquiet_mode\nproxy_dns\nremote_dns_subnet 224\ntcp_read_time_out 15000\ntcp_connect_time_out 8000\n\n[ProxyList]\n%s\n" "$PROXY_CONFIG" > /etc/proxychains4.conf &&' "$label literal config write guard" || return 1
    assert_line_exactly_once "$file" '            chmod 0600 -- /etc/proxychains4.conf' "$label config mode count" || return 1
    assert_line_exactly_once "$file" '    ); then' "$label config failure branch" || return 1
    assert_logger_message "$file" runtime_log_error 'Error: failed to write proxy configuration.' "$label config failure diagnostic" || return 1
    logger_source_line=$(grep -nF -- "$NEW_LOGGER_SOURCE" "$file" | cut -d: -f1)
    random_source_line=$(grep -nF -- '. /usr/local/bin/random-wait.sh' "$file" | cut -d: -f1)
    network_source_line=$(grep -nF -- '. /usr/local/bin/network-runtime.sh' "$file" | cut -d: -f1)
    config_guard_line=$(grep -nF -- 'if [[ -n ${PROXY_CONFIG:-} ]]; then' "$file" | cut -d: -f1)
    direct_function_line=$(grep -nF -- 'run_speedtest_direct() {' "$file" | cut -d: -f1)
    proxy_function_line=$(grep -nF -- 'run_speedtest_proxy() {' "$file" | cut -d: -f1)
    download_function_line=$(grep -nF -- 'run_ddl() {' "$file" | cut -d: -f1)
    if [ -z "$config_guard_line" ] || [ -z "$direct_function_line" ] ||
        [ -z "$proxy_function_line" ] || [ -z "$download_function_line" ] ||
        [ "$config_guard_line" -ge "$direct_function_line" ] ||
        [ "$config_guard_line" -ge "$proxy_function_line" ] ||
        [ "$config_guard_line" -ge "$download_function_line" ]; then
        fail "$label proxy config failure gate is not before speedtest/download code"
        return 1
    fi
    if [ -z "$logger_source_line" ] || [ -z "$random_source_line" ] ||
        [ -z "$network_source_line" ] ||
        [ "$logger_source_line" -ge "$random_source_line" ] ||
        [ "$random_source_line" -ge "$network_source_line" ]; then
        fail "$label runtime logger was not sourced before both helpers"
        return 1
    fi
    assert_line_exactly_once "$file" 'wait_for_initial_start' "$label initial wait helper count" || return 1
    assert_logger_message "$file" runtime_log_info "$NEW_SIGNAL_TEXT" "$label signal trap count" || return 1
    assert_line_exactly_once "$file" "$NEW_DIRECT_COMMAND" "$label direct helper command count" || return 1
    assert_line_exactly_once "$file" "$NEW_PROXY_COMMAND" "$label proxy helper command count" || return 1
    assert_line_exactly_once "$file" "$NEW_URL_COMMAND" "$label URL helper command count" || return 1
}

make_comment_anchor_fixture() {
    local source=$1 dest=$2 old=$3 line count=0
    : >"$dest"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$old" ]; then
            printf '# %s\n' "$old" >>"$dest"
            count=$((count + 1))
        else
            printf '%s\n' "$line" >>"$dest"
        fi
    done <"$source"
    if [ "$count" -ne 1 ]; then
        fail "could not replace exactly one anchor in $dest (got $count)"
        return 1
    fi
    chmod 755 "$dest"
}

make_missing_anchor_fixture() {
    local source=$1 dest=$2 old=$3 line count=0
    : >"$dest"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$old" ]; then
            count=$((count + 1))
        else
            printf '%s\n' "$line" >>"$dest"
        fi
    done <"$source"
    if [ "$count" -ne 1 ]; then
        fail "could not remove exactly one anchor in $dest (got $count)"
        return 1
    fi
    chmod 755 "$dest"
}

make_duplicate_anchor_fixture() {
    local source=$1 dest=$2 old=$3 line count=0
    : >"$dest"
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line" >>"$dest"
        if [ "$line" = "$old" ]; then
            printf '%s\n' "$line" >>"$dest"
            count=$((count + 1))
        fi
    done <"$source"
    if [ "$count" -ne 1 ]; then
        fail "could not duplicate exactly one anchor in $dest (got $count)"
        return 1
    fi
    chmod 755 "$dest"
}

assert_replacement_count_rejection() {
    local label=$1 fixture=$2 fixture_sha before_copy output
    before_copy=$TMP_DIR/$label.before
    cp -- "$fixture" "$before_copy"
    fixture_sha=$(sha256sum -- "$fixture" | awk '{print $1}')
    if output=$(EXPECTED_UPSTREAM_SHA256="$fixture_sha" /bin/bash "$ROOT/patch-entrypoint.sh" "$fixture" 2>&1); then
        fail "$label was accepted despite its missing exact anchor"
        return 1
    fi
    assert_contains_file <(printf '%s\n' "$output") \
        'expected upstream log and WAIT_TIME seams were not found exactly once' \
        "$label replacement-count diagnostic" || return 1
    assert_not_contains_file <(printf '%s\n' "$output") 'SHA256 mismatch' \
        "$label reached replacement-count gate" || return 1
    if ! cmp -s -- "$before_copy" "$fixture"; then
        fail "$label rejection modified its input"
        return 1
    fi
}

assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_WAIT_DEFAULT" 'synthetic WAIT_TIME default' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_PROXY_DEFAULT" 'synthetic PROXY_CONFIG default' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_PROXY_CONFIG" 'synthetic proxy config writer' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_COLORS_LINE" 'synthetic color anchor' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_INITIAL_SLEEP" 'synthetic initial delay' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_DIRECT_SPEEDTEST" 'synthetic direct speedtest' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_PROXY_SPEEDTEST" 'synthetic proxy speedtest' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_DIRECT_TOGGLE_DEFAULT" 'synthetic direct toggle default' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_PROXY_TOGGLE_DEFAULT" 'synthetic proxy toggle default' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_URL_DDL" 'synthetic URL_DDL download' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_WAIT_MESSAGE" 'synthetic wait message' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_WAIT_SLEEP" 'synthetic wait sleep' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_WAIT_WAIT" 'synthetic wait wait' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_SIGNAL_LINE" 'synthetic signal log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "        echo -e \"\${GREEN}\${BOLD}${OLD_DIRECT_START_TEXT} (\$((TEST_DURATION * 2)) sec)\${RESET}\"" 'synthetic direct-start log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "            echo -e \"\${RED}\${BOLD}${OLD_DIRECT_ERROR_TEXT}\${RESET}\"" 'synthetic direct-error log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "        echo -e \"\${YELLOW}\${BOLD}${OLD_DIRECT_DISABLED_TEXT}\${RESET}\"" 'synthetic direct-disabled log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "        echo -e \"\${BLUE}\${BOLD}${OLD_PROXY_START_TEXT} (\$((TEST_DURATION * 2)) sec)\${RESET}\"" 'synthetic proxy-start log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "            echo -e \"\${RED}\${BOLD}${OLD_PROXY_ERROR_TEXT}\${RESET}\"" 'synthetic proxy-error log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "        echo -e \"\${YELLOW}\${BOLD}${OLD_PROXY_DISABLED_TEXT}\${RESET}\"" 'synthetic proxy-disabled log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_DOWNLOAD_START_LINE" 'synthetic download-start log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_EMPTY_URL_LINE" 'synthetic empty-URL log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "echo -e \"\${CYAN}\${BOLD}${OLD_INITIAL_TEXT}\${RESET}\"" 'synthetic initial log' || exit 1

SYNTHETIC_SHA=$(sha256sum -- "$SYNTHETIC_FIXTURE" | awk '{print $1}')
TARGET=$TMP_DIR/entrypoint.sh
cp -- "$SYNTHETIC_FIXTURE" "$TARGET"
chmod 755 "$TARGET"

if ! patch_output=$(EXPECTED_UPSTREAM_SHA256="$SYNTHETIC_SHA" /bin/bash "$ROOT/patch-entrypoint.sh" "$TARGET" 2>&1); then
    fail "synthetic fixture was rejected: $patch_output"
    exit 1
fi

if [ "$(stat -c '%a' "$TARGET")" != 755 ]; then
    fail "patched entrypoint did not retain mode 0755"
    exit 1
fi
assert_contains_file "$TARGET" 'RANDOM_WAIT_PATCH_MARKER' 'patched marker' || exit 1
assert_contains_file "$TARGET" '. /usr/local/bin/random-wait.sh' 'random helper source' || exit 1
assert_contains_file "$TARGET" '. /usr/local/bin/network-runtime.sh' 'network helper source' || exit 1
assert_contains_file "$TARGET" 'if ! validate_wait_config; then' 'preflight validation' || exit 1
assert_contains_file "$TARGET" 'if ! validate_network_runtime_config; then' 'network preflight validation' || exit 1
assert_contains_file "$TARGET" ': "${WAIT_TIME:=}"' 'legacy default removal' || exit 1
assert_line_exactly_once "$TARGET" ': "${PROXY_CONFIG:=}"' 'empty proxy default' || exit 1
assert_line_exactly_once "$TARGET" "$NEW_DIRECT_TOGGLE_DEFAULT" 'direct speedtest disabled default' || exit 1
assert_line_exactly_once "$TARGET" "$NEW_PROXY_TOGGLE_DEFAULT" 'proxy speedtest disabled default' || exit 1
assert_not_contains_file "$TARGET" "$OLD_DIRECT_TOGGLE_DEFAULT" 'upstream direct speedtest default removal' || exit 1
assert_not_contains_file "$TARGET" "$OLD_PROXY_TOGGLE_DEFAULT" 'upstream proxy speedtest default removal' || exit 1
assert_not_contains_file "$TARGET" ': "${PROXY_CONFIG:=socks5 127.0.0.1 9100}"' 'localhost proxy default removal' || exit 1
assert_contains_file "$TARGET" 'if [[ -n ${PROXY_CONFIG:-} ]]; then' 'conditional proxy config writer' || exit 1
assert_contains_file "$TARGET" 'chmod 0600 -- /etc/proxychains4.conf' 'private proxy config mode' || exit 1
assert_contains_file "$TARGET" 'strict_chain\nquiet_mode\nproxy_dns' 'strict proxy config body' || exit 1
assert_contains_file "$TARGET" 'cancel_network_runtime' 'signal runtime cleanup' || exit 1
if grep -Fq -- ': "${WAIT_TIME:=21600}"' "$TARGET"; then
    fail "upstream fixed WAIT_TIME default remains"
    exit 1
fi
assert_contains_file "$TARGET" 'wait_for_initial_start' 'interruptible initial delay' || exit 1
assert_contains_file "$TARGET" 'wait_for_next_run' 'random wait seam' || exit 1
if grep -Fq -- 'sleep "$WAIT_TIME"' "$TARGET" || grep -Fq -- 'wait -n' "$TARGET"; then
    fail "old fixed wait loop remains"
    exit 1
fi
assert_contains_file "$TARGET" 'run_url_download "$URL_DDL"' 'URL_DDL runtime helper behavior' || exit 1
assert_contains_file "$TARGET" 'run_cf_speedtest_direct --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"' 'direct speedtest runtime helper behavior' || exit 1
assert_contains_file "$TARGET" 'run_cf_speedtest_proxy --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"' 'proxy speedtest runtime helper behavior' || exit 1
assert_not_contains_file "$TARGET" 'proxychains4 wget' 'old URL wget command removal' || exit 1
assert_not_contains_file "$TARGET" 'if ! cf_speedtest --test-duration-seconds' 'old direct command removal' || exit 1
assert_not_contains_file "$TARGET" 'if ! proxychains4 cf_speedtest --test-duration-seconds' 'old proxy command removal' || exit 1
assert_not_contains_file "$TARGET" 'Starting download from: $URL_DDL' 'URL redaction in start log' || exit 1
assert_not_contains_file "$TARGET" 'TEST_DURATION * 2' 'false two-times duration wording' || exit 1
if grep -nE '(^|[^[:alnum:]_])eval([[:space:]]|$)' "$TARGET"; then
    fail "patched entrypoint contains eval"
    exit 1
fi
if ! bash -n "$TARGET"; then
    fail "patched synthetic entrypoint is not valid shell"
    exit 1
fi
assert_generated_runtime_anchors "$TARGET" 'synthetic patched entrypoint' || exit 1
assert_translated_messages "$TARGET" 'synthetic patched entrypoint' || exit 1

if [ "$(grep -Fxc -- '# RANDOM_WAIT_PATCH_MARKER: validated random interval seam' "$TARGET")" != 1 ]; then
    fail "patched marker count is not exactly one"
    exit 1
fi
if grep -nE '(^|[^[:alnum:]_])eval([[:space:]]|$)' "$ROOT/patch-entrypoint.sh" "$TARGET"; then
    fail "patch or patched entrypoint contains eval"
    exit 1
fi

# Similar-looking comments must not satisfy the complete shell-line anchors.
SIGNAL_COMMENT_FIXTURE=$TMP_DIR/signal-comment.sh
DOWNLOAD_COMMENT_FIXTURE=$TMP_DIR/download-comment.sh
EMPTY_COMMENT_FIXTURE=$TMP_DIR/empty-comment.sh
PROXY_DEFAULT_COMMENT_FIXTURE=$TMP_DIR/proxy-default-comment.sh
DIRECT_COMMAND_COMMENT_FIXTURE=$TMP_DIR/direct-command-comment.sh
DIRECT_TOGGLE_COMMENT_FIXTURE=$TMP_DIR/direct-toggle-comment.sh
make_comment_anchor_fixture "$SYNTHETIC_FIXTURE" "$SIGNAL_COMMENT_FIXTURE" "$OLD_SIGNAL_LINE" || exit 1
make_comment_anchor_fixture "$SYNTHETIC_FIXTURE" "$DOWNLOAD_COMMENT_FIXTURE" "$OLD_DOWNLOAD_START_LINE" || exit 1
make_comment_anchor_fixture "$SYNTHETIC_FIXTURE" "$EMPTY_COMMENT_FIXTURE" "$OLD_EMPTY_URL_LINE" || exit 1
make_comment_anchor_fixture "$SYNTHETIC_FIXTURE" "$PROXY_DEFAULT_COMMENT_FIXTURE" "$OLD_PROXY_DEFAULT" || exit 1
make_comment_anchor_fixture "$SYNTHETIC_FIXTURE" "$DIRECT_COMMAND_COMMENT_FIXTURE" "$OLD_DIRECT_COMMAND" || exit 1
make_comment_anchor_fixture "$SYNTHETIC_FIXTURE" "$DIRECT_TOGGLE_COMMENT_FIXTURE" "$OLD_DIRECT_TOGGLE_DEFAULT" || exit 1
assert_replacement_count_rejection 'signal-comment' "$SIGNAL_COMMENT_FIXTURE" || exit 1
assert_replacement_count_rejection 'download-comment' "$DOWNLOAD_COMMENT_FIXTURE" || exit 1
assert_replacement_count_rejection 'empty-comment' "$EMPTY_COMMENT_FIXTURE" || exit 1
assert_replacement_count_rejection 'proxy-default-comment' "$PROXY_DEFAULT_COMMENT_FIXTURE" || exit 1
assert_replacement_count_rejection 'direct-command-comment' "$DIRECT_COMMAND_COMMENT_FIXTURE" || exit 1
assert_replacement_count_rejection 'direct-toggle-comment' "$DIRECT_TOGGLE_COMMENT_FIXTURE" || exit 1

# Removing each complete old shell line must fail closed without writing.
SIGNAL_MISSING_FIXTURE=$TMP_DIR/signal-missing.sh
DOWNLOAD_MISSING_FIXTURE=$TMP_DIR/download-missing.sh
EMPTY_MISSING_FIXTURE=$TMP_DIR/empty-missing.sh
PROXY_DEFAULT_MISSING_FIXTURE=$TMP_DIR/proxy-default-missing.sh
DIRECT_COMMAND_MISSING_FIXTURE=$TMP_DIR/direct-command-missing.sh
DIRECT_TOGGLE_MISSING_FIXTURE=$TMP_DIR/direct-toggle-missing.sh
make_missing_anchor_fixture "$SYNTHETIC_FIXTURE" "$SIGNAL_MISSING_FIXTURE" "$OLD_SIGNAL_LINE" || exit 1
make_missing_anchor_fixture "$SYNTHETIC_FIXTURE" "$DOWNLOAD_MISSING_FIXTURE" "$OLD_DOWNLOAD_START_LINE" || exit 1
make_missing_anchor_fixture "$SYNTHETIC_FIXTURE" "$EMPTY_MISSING_FIXTURE" "$OLD_EMPTY_URL_LINE" || exit 1
make_missing_anchor_fixture "$SYNTHETIC_FIXTURE" "$PROXY_DEFAULT_MISSING_FIXTURE" "$OLD_PROXY_DEFAULT" || exit 1
make_missing_anchor_fixture "$SYNTHETIC_FIXTURE" "$DIRECT_COMMAND_MISSING_FIXTURE" "$OLD_DIRECT_COMMAND" || exit 1
make_missing_anchor_fixture "$SYNTHETIC_FIXTURE" "$DIRECT_TOGGLE_MISSING_FIXTURE" "$OLD_DIRECT_TOGGLE_DEFAULT" || exit 1
assert_replacement_count_rejection 'signal-missing' "$SIGNAL_MISSING_FIXTURE" || exit 1
assert_replacement_count_rejection 'download-missing' "$DOWNLOAD_MISSING_FIXTURE" || exit 1
assert_replacement_count_rejection 'empty-missing' "$EMPTY_MISSING_FIXTURE" || exit 1
assert_replacement_count_rejection 'proxy-default-missing' "$PROXY_DEFAULT_MISSING_FIXTURE" || exit 1
assert_replacement_count_rejection 'direct-command-missing' "$DIRECT_COMMAND_MISSING_FIXTURE" || exit 1
assert_replacement_count_rejection 'direct-toggle-missing' "$DIRECT_TOGGLE_MISSING_FIXTURE" || exit 1

# Duplicating a new exact anchor must also fail closed without writing.
PROXY_CONFIG_DUPLICATE_FIXTURE=$TMP_DIR/proxy-config-duplicate.sh
URL_COMMAND_DUPLICATE_FIXTURE=$TMP_DIR/url-command-duplicate.sh
make_duplicate_anchor_fixture "$SYNTHETIC_FIXTURE" "$PROXY_CONFIG_DUPLICATE_FIXTURE" "$OLD_PROXY_CONFIG" || exit 1
make_duplicate_anchor_fixture "$SYNTHETIC_FIXTURE" "$URL_COMMAND_DUPLICATE_FIXTURE" "$OLD_URL_COMMAND" || exit 1
assert_replacement_count_rejection 'proxy-config-duplicate' "$PROXY_CONFIG_DUPLICATE_FIXTURE" || exit 1
assert_replacement_count_rejection 'url-command-duplicate' "$URL_COMMAND_DUPLICATE_FIXTURE" || exit 1

# Reject a changed synthetic entrypoint before any write and leave it byte-for-byte intact.
BAD=$TMP_DIR/bad-entrypoint.sh
cp -- "$SYNTHETIC_FIXTURE" "$BAD"
printf '\n# fixture mutation\n' >>"$BAD"
before=$(sha256sum -- "$BAD" | awk '{print $1}')
if bad_output=$(EXPECTED_UPSTREAM_SHA256="$SYNTHETIC_SHA" /bin/bash "$ROOT/patch-entrypoint.sh" "$BAD" 2>&1); then
    fail "changed upstream entrypoint was accepted"
    exit 1
fi
assert_contains_file <(printf '%s\n' "$bad_output") 'SHA256 mismatch' 'wrong-SHA diagnostic' || exit 1
after=$(sha256sum -- "$BAD" | awk '{print $1}')
if [ "$before" != "$after" ]; then
    fail "wrong-SHA rejection modified its input"
    exit 1
fi

if [ "$(sha256sum -- "$SYNTHETIC_FIXTURE" | awk '{print $1}')" != "$SYNTHETIC_SHA" ]; then
    fail "synthetic fixture changed"
    exit 1
fi

if [ "${UPSTREAM_ENTRYPOINT_FIXTURE+x}" = x ]; then
    if [ ! -f "$UPSTREAM_ENTRYPOINT_FIXTURE" ] || [ ! -r "$UPSTREAM_ENTRYPOINT_FIXTURE" ]; then
        fail "UPSTREAM_ENTRYPOINT_FIXTURE is missing or unreadable"
        exit 1
    fi
    actual_sha=$(sha256sum -- "$UPSTREAM_ENTRYPOINT_FIXTURE" | awk '{print $1}')
    if [ "$actual_sha" != "$EXPECTED_SHA" ]; then
        fail "UPSTREAM_ENTRYPOINT_FIXTURE SHA256 mismatch (expected $EXPECTED_SHA, got $actual_sha)"
        exit 1
    fi

    REAL_TARGET=$TMP_DIR/real-entrypoint.sh
    cp -- "$UPSTREAM_ENTRYPOINT_FIXTURE" "$REAL_TARGET"
    REAL_MODE=$(stat -c '%a' -- "$REAL_TARGET")
    if real_output=$(env -u EXPECTED_UPSTREAM_SHA256 /bin/bash "$ROOT/patch-entrypoint.sh" "$REAL_TARGET" 2>&1); then
        :
    else
        fail "frozen fixture was rejected: $real_output"
        exit 1
    fi
    if [ "$(stat -c '%a' -- "$REAL_TARGET")" != "$REAL_MODE" ]; then
        fail "patched frozen fixture did not retain its mode"
        exit 1
    fi
    assert_contains_file "$REAL_TARGET" 'RANDOM_WAIT_PATCH_MARKER' 'frozen fixture patched marker' || exit 1
    if [ "$(grep -Fxc -- '# RANDOM_WAIT_PATCH_MARKER: validated random interval seam' "$REAL_TARGET")" != 1 ]; then
        fail "frozen fixture patched marker count is not exactly one"
        exit 1
    fi
    assert_line_exactly_once "$REAL_TARGET" ': "${PROXY_CONFIG:=}"' 'frozen empty proxy default' || exit 1
    assert_not_contains_file "$REAL_TARGET" ': "${PROXY_CONFIG:=socks5 127.0.0.1 9100}"' 'frozen localhost proxy default removal' || exit 1
    assert_contains_file "$REAL_TARGET" '. /usr/local/bin/network-runtime.sh' 'frozen network helper source' || exit 1
    assert_contains_file "$REAL_TARGET" 'if ! validate_network_runtime_config; then' 'frozen network preflight validation' || exit 1
    assert_contains_file "$REAL_TARGET" 'cancel_network_runtime' 'frozen signal runtime cleanup' || exit 1
    assert_contains_file "$REAL_TARGET" 'run_url_download "$URL_DDL"' 'frozen URL runtime helper' || exit 1
    assert_not_contains_file "$REAL_TARGET" 'proxychains4 wget' 'frozen old URL wget removal' || exit 1
    assert_not_contains_file "$REAL_TARGET" 'TEST_DURATION * 2' 'frozen false two-times duration wording' || exit 1
    if ! bash -n "$REAL_TARGET"; then
        fail "patched frozen entrypoint is not valid shell"
        exit 1
    fi
    assert_generated_runtime_anchors "$REAL_TARGET" 'frozen patched entrypoint' || exit 1
    assert_translated_messages "$REAL_TARGET" 'frozen fixture patched entrypoint' || exit 1
fi

printf 'PASS: patch-entrypoint.sh\n'
