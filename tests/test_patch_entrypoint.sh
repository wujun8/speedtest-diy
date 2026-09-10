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
: "${TEST_DURATION:=10}"
: "${DOWNLOAD_THREADS:=4}"
: "${UPLOAD_THREADS:=4}"

# Gestion des signaux d'arrêt
trap "echo -e '\e[1;31mArrêt du script demandé. Nettoyage et sortie...\e[0m'; exit 0" SIGTERM SIGINT

# Définir les couleurs avec tput
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
OLD_COLORS_LINE='# Définir les couleurs avec tput'
OLD_INITIAL_SLEEP='sleep 5'
OLD_DIRECT_SPEEDTEST='        if ! cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"; then'
OLD_PROXY_SPEEDTEST='        if ! proxychains4 cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"; then'
OLD_URL_DDL='        proxychains4 wget -O /dev/null --progress=dot:giga --no-check-certificate "$URL_DDL" 2>&1 | awk '\''/saved/ {print $0}'\'''
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
NEW_SIGNAL="trap \"echo -e '\\e[1;31mStop requested. Cleaning up and exiting...\\e[0m'; exit 0\" SIGTERM SIGINT"
NEW_DIRECT_START='        echo -e "${GREEN}${BOLD}Starting direct speed test... ($((TEST_DURATION * 2)) sec)${RESET}"'
NEW_DIRECT_ERROR='            echo -e "${RED}${BOLD}Error: direct speed test failed${RESET}"'
NEW_DIRECT_DISABLED='        echo -e "${YELLOW}${BOLD}Direct speed test disabled.${RESET}"'
NEW_PROXY_START='        echo -e "${BLUE}${BOLD}Starting speed test through proxychains4... ($((TEST_DURATION * 2)) sec)${RESET}"'
NEW_PROXY_ERROR='            echo -e "${RED}${BOLD}Error: proxy speed test failed${RESET}"'
NEW_PROXY_DISABLED='        echo -e "${YELLOW}${BOLD}Proxy speed test disabled.${RESET}"'
NEW_DOWNLOAD_START='        echo -e "\n${BLUE}${BOLD}Starting download from: $URL_DDL${RESET}\n"'
NEW_EMPTY_URL='        echo -e "\n${YELLOW}${BOLD}URL_DDL is empty. Download skipped.${RESET}\n"'
NEW_INITIAL='echo -e "${CYAN}${BOLD}Starting in 5 seconds...${RESET}"'

assert_translated_messages() {
    local file=$1 label=$2 forbidden
    assert_line_exactly_once "$file" "$NEW_SIGNAL" "$label English signal log" || return 1
    assert_line_exactly_once "$file" "$NEW_DIRECT_START" "$label English direct-start log" || return 1
    assert_line_exactly_once "$file" "$NEW_DIRECT_ERROR" "$label English direct-error log" || return 1
    assert_line_exactly_once "$file" "$NEW_DIRECT_DISABLED" "$label English direct-disabled log" || return 1
    assert_line_exactly_once "$file" "$NEW_PROXY_START" "$label English proxy-start log" || return 1
    assert_line_exactly_once "$file" "$NEW_PROXY_ERROR" "$label English proxy-error log" || return 1
    assert_line_exactly_once "$file" "$NEW_PROXY_DISABLED" "$label English proxy-disabled log" || return 1
    assert_line_exactly_once "$file" "$NEW_DOWNLOAD_START" "$label English download-start log" || return 1
    assert_line_exactly_once "$file" "$NEW_EMPTY_URL" "$label English empty-URL log" || return 1
    assert_line_exactly_once "$file" "$NEW_INITIAL" "$label English initial log" || return 1
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

assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_WAIT_DEFAULT" 'synthetic WAIT_TIME default' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_COLORS_LINE" 'synthetic color anchor' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_INITIAL_SLEEP" 'synthetic initial delay' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_DIRECT_SPEEDTEST" 'synthetic direct speedtest' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_PROXY_SPEEDTEST" 'synthetic proxy speedtest' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_URL_DDL" 'synthetic URL_DDL download' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_WAIT_MESSAGE" 'synthetic wait message' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_WAIT_SLEEP" 'synthetic wait sleep' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_WAIT_WAIT" 'synthetic wait wait' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "$OLD_SIGNAL" 'synthetic signal log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "        echo -e \"\${GREEN}\${BOLD}${OLD_DIRECT_START_TEXT} (\$((TEST_DURATION * 2)) sec)\${RESET}\"" 'synthetic direct-start log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "            echo -e \"\${RED}\${BOLD}${OLD_DIRECT_ERROR_TEXT}\${RESET}\"" 'synthetic direct-error log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "        echo -e \"\${YELLOW}\${BOLD}${OLD_DIRECT_DISABLED_TEXT}\${RESET}\"" 'synthetic direct-disabled log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "        echo -e \"\${BLUE}\${BOLD}${OLD_PROXY_START_TEXT} (\$((TEST_DURATION * 2)) sec)\${RESET}\"" 'synthetic proxy-start log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "            echo -e \"\${RED}\${BOLD}${OLD_PROXY_ERROR_TEXT}\${RESET}\"" 'synthetic proxy-error log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "        echo -e \"\${YELLOW}\${BOLD}${OLD_PROXY_DISABLED_TEXT}\${RESET}\"" 'synthetic proxy-disabled log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "        echo -e \"\\n\${BLUE}\${BOLD}${OLD_DOWNLOAD_START_TEXT}\${RESET}\\n\"" 'synthetic download-start log' || exit 1
assert_line_exactly_once "$SYNTHETIC_FIXTURE" "        echo -e \"\\n\${YELLOW}\${BOLD}${OLD_EMPTY_URL_TEXT}\${RESET}\\n\"" 'synthetic empty-URL log' || exit 1
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
assert_contains_file "$TARGET" 'if ! validate_wait_config; then' 'preflight validation' || exit 1
assert_contains_file "$TARGET" ': "${WAIT_TIME:=}"' 'legacy default removal' || exit 1
if grep -Fq -- ': "${WAIT_TIME:=21600}"' "$TARGET"; then
    fail "upstream fixed WAIT_TIME default remains"
    exit 1
fi
assert_contains_file "$TARGET" 'sleep 5' 'fixed initial delay' || exit 1
assert_contains_file "$TARGET" 'wait_for_next_run' 'random wait seam' || exit 1
if grep -Fq -- 'sleep "$WAIT_TIME"' "$TARGET" || grep -Fq -- 'wait -n' "$TARGET"; then
    fail "old fixed wait loop remains"
    exit 1
fi
assert_contains_file "$TARGET" 'proxychains4 wget -O /dev/null --progress=dot:giga --no-check-certificate "$URL_DDL"' 'URL_DDL /dev/null behavior' || exit 1
assert_contains_file "$TARGET" 'cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"' 'direct speedtest behavior' || exit 1
assert_contains_file "$TARGET" 'proxychains4 cf_speedtest --test-duration-seconds "$TEST_DURATION" --download-threads "$DOWNLOAD_THREADS" --upload-threads "$UPLOAD_THREADS"' 'proxy speedtest behavior' || exit 1
assert_translated_messages "$TARGET" 'synthetic patched entrypoint' || exit 1

if [ "$(grep -Fxc -- '# RANDOM_WAIT_PATCH_MARKER: validated random interval seam' "$TARGET")" != 1 ]; then
    fail "patched marker count is not exactly one"
    exit 1
fi
if grep -nE '(^|[^[:alnum:]_])eval([[:space:]]|$)' "$ROOT/patch-entrypoint.sh" "$TARGET"; then
    fail "patch or patched entrypoint contains eval"
    exit 1
fi

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
    assert_translated_messages "$REAL_TARGET" 'frozen fixture patched entrypoint' || exit 1
fi

printf 'PASS: patch-entrypoint.sh\n'
