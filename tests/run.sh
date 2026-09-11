#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
failures=0

run_group() {
    local name=$1
    shift
    if "$@"; then
        printf 'PASS: %s\n' "$name"
    else
        printf 'FAIL: %s\n' "$name" >&2
        failures=$((failures + 1))
    fi
}

require_file() {
    local file=$1
    if [ ! -f "$file" ]; then
        printf 'FAIL: missing %s\n' "$file" >&2
        return 1
    fi
}

require_line() {
    local file=$1 needle=$2 label=$3
    if ! grep -Fq -- "$needle" "$file"; then
        printf 'FAIL: %s (missing %s)\n' "$label" "$needle" >&2
        return 1
    fi
}

require_no_line() {
    local file=$1 needle=$2 label=$3
    if grep -Fq -- "$needle" "$file"; then
        printf 'FAIL: %s (unexpected %s)\n' "$label" "$needle" >&2
        return 1
    fi
}

portability_contract() {
    local workspace_marker='/work''space/'
    local hermes_fixture_marker='.git''/hermes-inputs'
    local tracked_tests tracked_test

    if ! tracked_tests=$(git -C "$ROOT" ls-files -- tests); then
        printf 'FAIL: could not enumerate tracked tests\n' >&2
        return 1
    fi
    while IFS= read -r tracked_test; do
        [ -n "$tracked_test" ] || continue
        if grep -nF -- "$workspace_marker" "$ROOT/$tracked_test" ||
            grep -nF -- "$hermes_fixture_marker" "$ROOT/$tracked_test"; then
            printf 'FAIL: non-portable fixture path in %s\n' "$tracked_test" >&2
            return 1
        fi
    done <<<"$tracked_tests"
}

workflow_contract() {
    local file=$ROOT/.github/workflows/container.yml
    local sigterm_step post_stop_step post_stop_logs
    require_file "$file" || return 1

    require_line "$file" 'name: container' 'workflow name' || return 1
    require_line "$file" 'pull_request:' 'PR trigger' || return 1
    require_line "$file" 'branches:' 'push branch filter' || return 1
    require_line "$file" '    - main' 'main push filter' || return 1
    require_line "$file" "      - 'v*'" 'version tag filter' || return 1
    require_line "$file" 'permissions:' 'workflow permissions' || return 1
    require_line "$file" '  contents: read' 'read permission' || return 1
    require_line "$file" '      packages: write' 'package write permission' || return 1
    require_line "$file" '--platform linux/amd64' 'build platform' || return 1
    require_line "$file" 'platforms: linux/amd64' 'publish platform' || return 1
    require_line "$file" 'docker run --rm --platform linux/amd64' 'real Docker smoke' || return 1
    require_line "$file" 'RUN_SPEEDTEST_DIRECT=false' 'signal smoke direct toggle' || return 1
    require_line "$file" 'RUN_SPEEDTEST_PROXY=false' 'signal smoke proxy toggle' || return 1
    require_line "$file" "URL_DDL=''" 'signal smoke empty URL_DDL' || return 1
    require_line "$file" 'WAIT_TIME=30' 'signal smoke fixed wait' || return 1
    require_line "$file" 'timeout 10s docker stop --time 5' 'bounded SIGTERM smoke' || return 1
    require_line "$file" 'ghcr.io/wujun8/speedtest-diy' 'GHCR image path' || return 1
    require_line "$file" 'Starting in 5 seconds...' 'English initial smoke marker' || return 1
    require_line "$file" 'Direct speed test disabled.' 'English direct-disabled smoke marker' || return 1
    require_line "$file" 'Proxy speed test disabled.' 'English proxy-disabled smoke marker' || return 1
    require_line "$file" 'URL_DDL is empty. Download skipped.' 'English empty-URL smoke marker' || return 1
    require_line "$file" 'Waiting 30 seconds before running the tests again...' 'English wait smoke marker' || return 1
    require_line "$file" 'type=raw,value=latest' 'latest tag rule' || return 1
    require_line "$file" 'type=sha,format=short' 'sha tag rule' || return 1
    require_line "$file" 'type=semver,pattern={{version}}' 'semver tag rule' || return 1
    require_no_line "$file" 'Attente de 30 secondes' 'French wait smoke marker' || return 1
    require_line "$file" "github.event_name == 'push'" 'publish push guard' || return 1
    require_line "$file" 'needs: build-and-smoke' 'publish dependency' || return 1
    require_line "$file" 'docker/build-push-action' 'publish build action' || return 1
    require_no_line "$file" 'arm64' 'workflow architecture scope' || return 1

    sigterm_step=$(awk '
        /^      - name: Verify SIGTERM shutdown$/ { in_step=1 }
        in_step && /^      - name:/ && $0 !~ /^      - name: Verify SIGTERM shutdown$/ { exit }
        in_step && /^  [[:alnum:]_-]+:/ { exit }
        in_step { print }
    ' "$file")
    if [ -z "$sigterm_step" ]; then
        printf 'FAIL: SIGTERM smoke step is missing\n' >&2
        return 1
    fi
    post_stop_step=$(awk '
        /timeout 10s docker stop --time 5/ { after_stop=1; next }
        after_stop { print }
    ' <<<"$sigterm_step")
    require_line <(printf '%s\n' "$post_stop_step") \
        'logs=$(docker logs "$container_id" 2>&1 || true)' \
        'post-stop Docker log reread' || return 1
    require_line <(printf '%s\n' "$post_stop_step") \
        "docker inspect -f '{{.State.Running}}' \"\$container_id\"" \
        'post-stop State.Running check' || return 1
    require_line <(printf '%s\n' "$post_stop_step") '= false ]' \
        'post-stop stopped-state assertion' || return 1
    post_stop_logs=$(awk '
        /logs=\$\(docker logs/ { after_logs=1; next }
        after_logs { print }
    ' <<<"$post_stop_step")
    require_line <(printf '%s\n' "$post_stop_logs") \
        "if ! grep -Fq -- 'Stop requested. Cleaning up and exiting...' <<<\"\$logs\"; then" \
        'post-stop English shutdown log assertion' || return 1
    require_line <(printf '%s\n' "$post_stop_logs") \
        "if grep -Fq -- 'Arrêt du script demandé.' <<<\"\$logs\"; then" \
        'post-stop French shutdown log rejection' || return 1

    if command -v ruby >/dev/null 2>&1; then
        ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$file" || {
            printf 'FAIL: workflow is not parseable YAML\n' >&2
            return 1
        }
    fi
}

anonymous_ghcr_contract() {
    local file=$ROOT/.github/workflows/container.yml
    local job

    require_file "$file" || return 1
    job=$(awk '
        /^  verify-public-pull:/ { in_job=1 }
        in_job && /^  [[:alnum:]_-]+:/ && $0 !~ /^  verify-public-pull:/ { exit }
        in_job { print }
    ' "$file")
    if [ -z "$job" ]; then
        printf 'FAIL: anonymous GHCR verification job is missing\n' >&2
        return 1
    fi
    for needle in \
        'name: Verify anonymous GHCR pull and run' \
        'needs: publish' \
        "github.event_name == 'push'" \
        "github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/v')" \
        'IMAGE: ghcr.io/wujun8/speedtest-diy' \
        'export DOCKER_CONFIG="$RUNNER_TEMP/speedtest-diy-anonymous-docker-config"' \
        'unset DOCKER_AUTH_CONFIG' \
        'GITHUB_SHA::7' \
        'docker pull --platform linux/amd64' \
        'docker run -d --platform linux/amd64' \
        'RUN_SPEEDTEST_DIRECT=false' \
        'RUN_SPEEDTEST_PROXY=false' \
        "URL_DDL=''" \
        'WAIT_TIME=30' \
        'Waiting 30 seconds before running the tests again...' \
        'timeout 10s docker stop --time 5'; do
        if ! grep -Fq -- "$needle" <<<"$job"; then
            printf 'FAIL: anonymous GHCR contract (missing %s)\n' "$needle" >&2
            return 1
        fi
    done
    if grep -Fq -- '${{ runner.temp }}' <<<"$job"; then
        printf 'FAIL: anonymous GHCR job uses forbidden runner context\n' >&2
        return 1
    fi
    if grep -Fq -- 'docker/login-action' <<<"$job" ||
        grep -Fq -- 'docker login' <<<"$job"; then
        printf 'FAIL: anonymous GHCR job performs a registry login\n' >&2
        return 1
    fi
}

dockerfile_contract() {
    local file=$ROOT/Dockerfile
    require_file "$file" || return 1
    require_line "$file" 'FROM --platform=linux/amd64 zephir284/speedtest@sha256:5b2431c251a10ed6dc6600bba6dcb3ca0b5682b00700c17f1a970478e55a7334' 'frozen amd64 base' || return 1
    require_line "$file" 'COPY random-wait.sh /usr/local/bin/random-wait.sh' 'random helper image copy' || return 1
    require_line "$file" 'COPY patch-entrypoint.sh /usr/local/bin/patch-entrypoint.sh' 'patch helper image copy' || return 1
    require_line "$file" '/usr/local/bin/patch-entrypoint.sh /entrypoint.sh' 'build-time patch' || return 1
    require_line "$file" 'ENTRYPOINT ["/entrypoint.sh"]' 'upstream entrypoint' || return 1
    require_no_line "$file" 'arm64' 'Dockerfile architecture scope' || return 1
    if grep -nE '(^|[^[:alnum:]_])eval([[:space:]]|$)' "$file"; then
        printf 'FAIL: Dockerfile contains eval\n' >&2
        return 1
    fi
}

compose_contract() {
    local file=$ROOT/compose.yaml
    local needle count

    require_file "$file" || return 1
    for needle in \
        'services:' \
        '  speedtest:' \
        '    image: ghcr.io/wujun8/speedtest-diy:latest' \
        '    platform: linux/amd64' \
        '    network_mode: host' \
        '    restart: unless-stopped' \
        '    environment:' \
        '      URL_DDL: "${URL_DDL:-https://github.com/cli/cli/releases/download/v2.100.0/gh_2.100.0_linux_amd64.tar.gz}"' \
        '      WAIT_TIME_MIN: "${WAIT_TIME_MIN:-5}"' \
        '      WAIT_TIME_MAX: "${WAIT_TIME_MAX:-50}"' \
        '      RUN_SPEEDTEST_DIRECT: "false"' \
        '      RUN_SPEEDTEST_PROXY: "false"' \
        '      PROXY_CONFIG: "${PROXY_CONFIG:-socks5 127.0.0.1 9100}"'; do
        count=$(grep -Fxc -- "$needle" "$file" 2>/dev/null || true)
        if [ "$count" -ne 1 ]; then
            printf 'FAIL: Compose contract (expected exactly one line: %s; found %s)\n' "$needle" "$count" >&2
            return 1
        fi
    done
    require_no_line "$file" 'ai.here.link' 'Compose legacy ai.here.link URL' || return 1
    if grep -nE '^[[:space:]]*(ports|volumes):' "$file"; then
        printf 'FAIL: Compose contract (ports/volumes are forbidden)\n' >&2
        return 1
    fi
    if grep -nE '^[[:space:]]*-[[:space:]]*(URL_DDL|WAIT_TIME_MIN|WAIT_TIME_MAX|RUN_SPEEDTEST_DIRECT|RUN_SPEEDTEST_PROXY|PROXY_CONFIG)(:|[[:space:]])' "$file"; then
        printf 'FAIL: Compose contract (environment must use a mapping)\n' >&2
        return 1
    fi

    if [ "${CI:-}" = 'true' ]; then
        if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
            printf 'FAIL: Compose contract (CI=true requires docker compose)\n' >&2
            return 1
        fi
        if ! (CDPATH= cd -- "$ROOT" && docker compose -f compose.yaml config -q); then
            printf 'FAIL: Compose contract (docker compose config -q failed in CI)\n' >&2
            return 1
        fi
        printf 'PASS: docker compose config -q (CI)\n'
    elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        if ! (CDPATH= cd -- "$ROOT" && docker compose -f compose.yaml config -q); then
            printf 'FAIL: Compose contract (docker compose config -q failed)\n' >&2
            return 1
        fi
        printf 'PASS: docker compose config -q\n'
    else
        printf 'PASS: Compose static contract only (docker compose unavailable outside CI)\n'
    fi
}

documentation_contract() {
    local file=$ROOT/README.md
    require_file "$file" || return 1
    for needle in \
        'WAIT_TIME_MIN' 'WAIT_TIME_MAX' 'WAIT_TIME' 'PROXY_CONFIG' \
        'TEST_DURATION' 'DOWNLOAD_THREADS' 'UPLOAD_THREADS' \
        'RUN_SPEEDTEST_DIRECT' 'RUN_SPEEDTEST_PROXY' 'URL_DDL' \
        '5～50' 'ghcr.io/wujun8/speedtest-diy' 'Debian x86_64' \
        'Compose 仅 URL_DDL 下载' 'docker compose up -d' \
        'docker compose logs -f speedtest' 'docker compose stop' \
        '创建本地 .env' '默认等待范围为 5～50 秒' \
        '关闭两类 cf_speedtest' 'host 网络访问本机 9100 代理' \
        '不挂载 volumes' '只支持 linux/amd64' \
        '5 秒' '2147483647' 'sha256:5b2431c251a10ed6dc6600bba6dcb3ca0b5682b00700c17f1a970478e55a7334' \
        'https://github.com/cli/cli/releases/download/v2.100.0/gh_2.100.0_linux_amd64.tar.gz' \
        'GitHub CLI' 'v2.100.0' 'immutable' '15152253' \
        'sha256:e4d4bb4498e8d007abe545b6568926793ace1b6447da598294a610018cb164be' \
        'Range' '206' 'bytes 0-0/15152253' \
        '上游脚本产生的用户可见自有运行日志统一为英文' \
        'Docker Hub API' 'source' '公开描述未声明许可证' \
        'verify-public-pull' 'docker pull' 'docker run' '匿名' 'Public'; do
        require_line "$file" "$needle" "README contract" || return 1
    done
}

notice_contract() {
    local file=$ROOT/NOTICE.md
    require_file "$file" || return 1
    require_line "$file" 'zephir284/speedtest@sha256:5b2431c251a10ed6dc6600bba6dcb3ca0b5682b00700c17f1a970478e55a7334' 'NOTICE upstream digest' || return 1
    require_line "$file" 'source' 'NOTICE source fact' || return 1
    require_line "$file" '未发现上游许可声明' 'NOTICE license fact' || return 1
    require_line "$file" '自行核对上游条款' 'NOTICE terms reminder' || return 1
}

run_group 'test fixture portability' portability_contract
run_group 'random wait behavior' bash "$ROOT/tests/test_random_wait.sh"
run_group 'frozen entrypoint patch' bash "$ROOT/tests/test_patch_entrypoint.sh"
run_group 'workflow static contract' workflow_contract
run_group 'anonymous GHCR pull/run static contract' anonymous_ghcr_contract
run_group 'Dockerfile static contract' dockerfile_contract
run_group 'Compose static contract' compose_contract
run_group 'README static contract' documentation_contract
run_group 'NOTICE static contract' notice_contract

if [ "$failures" -ne 0 ]; then
    printf '%s test groups failed\n' "$failures" >&2
    exit 1
fi
printf 'All test groups passed\n'
