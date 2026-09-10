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
    require_line "$file" 'type=raw,value=latest' 'latest tag rule' || return 1
    require_line "$file" 'type=sha,format=short' 'sha tag rule' || return 1
    require_line "$file" 'type=semver,pattern={{version}}' 'semver tag rule' || return 1
    require_line "$file" "github.event_name == 'push'" 'publish push guard' || return 1
    require_line "$file" 'needs: build-and-smoke' 'publish dependency' || return 1
    require_line "$file" 'docker/build-push-action' 'publish build action' || return 1
    require_no_line "$file" 'arm64' 'workflow architecture scope' || return 1

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
        'DOCKER_CONFIG:' \
        'unset DOCKER_AUTH_CONFIG' \
        'GITHUB_SHA::7' \
        'docker pull --platform linux/amd64' \
        'docker run -d --platform linux/amd64' \
        'RUN_SPEEDTEST_DIRECT=false' \
        'RUN_SPEEDTEST_PROXY=false' \
        "URL_DDL=''" \
        'WAIT_TIME=30' \
        'timeout 10s docker stop --time 5'; do
        if ! grep -Fq -- "$needle" <<<"$job"; then
            printf 'FAIL: anonymous GHCR contract (missing %s)\n' "$needle" >&2
            return 1
        fi
    done
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

documentation_contract() {
    local file=$ROOT/README.md
    require_file "$file" || return 1
    for needle in \
        'WAIT_TIME_MIN' 'WAIT_TIME_MAX' 'WAIT_TIME' 'PROXY_CONFIG' \
        'TEST_DURATION' 'DOWNLOAD_THREADS' 'UPLOAD_THREADS' \
        'RUN_SPEEDTEST_DIRECT' 'RUN_SPEEDTEST_PROXY' 'URL_DDL' \
        '5～50' 'ghcr.io/wujun8/speedtest-diy' 'Debian x86_64' \
        '5 秒' '2147483647' 'sha256:5b2431c251a10ed6dc6600bba6dcb3ca0b5682b00700c17f1a970478e55a7334' \
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
run_group 'README static contract' documentation_contract
run_group 'NOTICE static contract' notice_contract

if [ "$failures" -ne 0 ]; then
    printf '%s test groups failed\n' "$failures" >&2
    exit 1
fi
printf 'All test groups passed\n'
