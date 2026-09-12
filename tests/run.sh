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
    local file_or_text=$1 needle=$2 label=$3
    if [[ "$file_or_text" == *$'\n'* ]]; then
        if ! grep -Fq -- "$needle" <<<"$file_or_text"; then
            printf 'FAIL: %s (missing %s)\n' "$label" "$needle" >&2
            return 1
        fi
    elif ! grep -Fq -- "$needle" "$file_or_text"; then
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

require_regex() {
    local file=$1 pattern=$2 label=$3
    if ! grep -Eq -- "$pattern" "$file"; then
        printf 'FAIL: %s (missing regex %s)\n' "$label" "$pattern" >&2
        return 1
    fi
}

extract_job() {
    local file=$1 job_name=$2
    awk -v job="  ${job_name}:" '
        $0 == job { in_job=1; print; next }
        in_job && /^  [[:alnum:]_-]+:/ { exit }
        in_job { print }
    ' "$file"
}

extract_step() {
    local file=$1 job_name=$2 step_name=$3
    awk -v job="  ${job_name}:" -v step="      - name: ${step_name}" '
        $0 == job { in_job=1; next }
        in_job && /^  [[:alnum:]_-]+:/ { exit }
        in_job && $0 == step { in_step=1; next }
        in_step && /^      - name:/ { exit }
        in_step { print }
    ' "$file"
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
    local metadata_step metadata_input shell_step image_step url_step only_down_step empty_proxy_step initial_step sigterm_step
    local shell_input image_input url_input only_down_input empty_proxy_input initial_input sigterm_input
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
    require_line "$file" 'ghcr.io/wujun8/speedtest-diy' 'GHCR image path' || return 1
    require_line "$file" 'type=raw,value=latest' 'latest tag rule' || return 1
    require_line "$file" 'type=sha,format=short' 'sha tag rule' || return 1
    require_line "$file" 'type=semver,pattern={{version}}' 'semver tag rule' || return 1
    require_line "$file" "github.event_name == 'push'" 'publish push guard' || return 1
    require_line "$file" 'needs: build-and-smoke' 'publish dependency' || return 1
    require_line "$file" 'docker/build-push-action' 'publish build action' || return 1
    require_no_line "$file" 'arm64' 'workflow architecture scope' || return 1

    metadata_step=$(extract_step "$file" publish 'Extract Docker metadata')
    metadata_input=$(printf '%s\n' "$metadata_step")
    require_line "$metadata_input" 'flavor: |' 'metadata latest flavor block' || return 1
    require_line "$metadata_input" 'latest=false' 'metadata implicit latest disabled' || return 1
    require_line "$metadata_input" 'type=raw,value=latest,enable=${{ github.ref == '\''refs/heads/main'\'' }}' 'metadata main-only latest tag rule' || return 1

    shell_step=$(extract_step "$file" test 'Shell syntax checks')
    require_line <(printf '%s\n' "$shell_step") \
        'run: bash -n random-wait.sh patch-entrypoint.sh network-runtime.sh tests/run.sh tests/test_random_wait.sh tests/test_network_runtime.sh tests/test_patch_entrypoint.sh' \
        'shell syntax list includes network runtime files' || return 1

    image_step=$(extract_step "$file" build-and-smoke 'Run image smoke checks')
    image_input=$(printf '%s\n' "$image_step")
    require_line "$image_input" 'docker run --rm --platform linux/amd64 --entrypoint /bin/bash "$IMAGE" -c' \
        'built-image smoke invocation' || return 1
    require_line "$image_input" 'test -x /usr/local/bin/random-wait.sh' 'random helper executable smoke' || return 1
    require_line "$image_input" 'test -x /usr/local/bin/network-runtime.sh' 'network helper executable smoke' || return 1
    require_line "$image_input" 'test -x "$(command -v curl)"' 'curl executable smoke' || return 1
    require_line "$image_input" 'test -s /etc/ssl/certs/ca-certificates.crt' 'CA bundle smoke' || return 1
    require_line "$image_input" "RANDOM_WAIT_PATCH_MARKER: validated random interval seam" 'patched marker smoke' || return 1
    require_line "$image_input" '. /usr/local/bin/network-runtime.sh' 'network helper marker smoke' || return 1
    require_line "$image_input" 'run_url_download \"\$URL_DDL\"' 'URL helper marker smoke' || return 1
    require_line "$image_input" 'run_cf_speedtest_direct' 'direct speedtest marker smoke' || return 1
    require_line "$image_input" 'run_cf_speedtest_proxy' 'proxy speedtest marker smoke' || return 1
    require_line "$image_input" 'help_output=$(cf_speedtest --help 2>&1)' 'pinned cf help invocation' || return 1
    require_line "$image_input" "grep -Fq -- '--download-only' <<<\"\$help_output\"" 'download-only help assertion' || return 1

    url_step=$(extract_step "$file" build-and-smoke 'Direct URL download smoke')
    url_input=$(printf '%s\n' "$url_step")
    require_line "$url_input" 'url_container="speedtest-diy-url-smoke-${GITHUB_RUN_ID:-local}"' 'named built-image URL container' || return 1
    require_line "$url_input" '--name "$url_container"' 'named URL smoke container' || return 1
    require_line "$url_input" "-e PROXY_CONFIG=''" 'direct URL empty proxy' || return 1
    require_line "$url_input" '-e DOWNLOAD_THREADS=4' 'direct URL four workers' || return 1
    require_line "$url_input" 'https://github.com/cli/cli/releases/download/v2.100.0/gh_2.100.0_linux_amd64.tar.gz' 'exact default URL smoke asset' || return 1
    require_line "$url_input" '-e WAIT_TIME=300' 'built-image URL long wait' || return 1
    require_line "$url_input" '-e HTTP_PROXY='\''poison-HTTP_PROXY'\''' 'built-image HTTP_PROXY poison' || return 1
    require_line "$url_input" '-e HTTPS_PROXY='\''poison-HTTPS_PROXY'\''' 'built-image HTTPS_PROXY poison' || return 1
    require_line "$url_input" '-e ALL_PROXY='\''poison-ALL_PROXY'\''' 'built-image ALL_PROXY poison' || return 1
    require_line "$url_input" '-e NO_PROXY='\''poison-NO_PROXY'\''' 'built-image NO_PROXY poison' || return 1
    require_line "$url_input" '-e http_proxy='\''poison-http_proxy'\''' 'built-image http_proxy poison' || return 1
    require_line "$url_input" '-e https_proxy='\''poison-https_proxy'\''' 'built-image https_proxy poison' || return 1
    require_line "$url_input" '-e all_proxy='\''poison-all_proxy'\''' 'built-image all_proxy poison' || return 1
    require_line "$url_input" '-e no_proxy='\''poison-no_proxy'\''' 'built-image no_proxy poison' || return 1
    require_line "$url_input" 'timeout 180s bash -c' 'bounded built-image URL smoke' || return 1
    require_line "$url_input" 'URL download complete: total bytes=15152253, concurrent segments=4, transport=direct' 'exact direct URL summary' || return 1
    require_line "$url_input" 'timeout 10s docker stop --time 5 "$url_container"' 'built-image URL bounded stop' || return 1
    require_line "$url_input" 'docker inspect -f '\''{{.State.Running}}'\'' "$url_container"' 'built-image URL stopped-state check' || return 1
    require_line "$url_input" 'docker inspect -f '\''{{.State.ExitCode}}'\'' "$url_container"' 'built-image URL exit-code check' || return 1
    require_line "$url_input" 'url_logs=$(docker logs "$url_container" 2>&1 || true)' 'built-image URL post-stop log reread' || return 1
    require_line "$url_input" 'grep -Fxc -- "$summary" <<<"$url_logs"' 'single-line URL summary assertion' || return 1
    if grep -Fq -- '-e WAIT_TIME=1' <<<"$url_input"; then
        printf 'FAIL: built-image URL smoke still uses WAIT_TIME=1\n' >&2
        return 1
    fi
    require_line "$url_input" 'grep -Fq -- "$url_url" <<<"$url_logs"' 'URL redaction assertion' || return 1
    require_line "$url_input" "'saved'" 'download progress noise assertion' || return 1
    require_line "$url_input" "'%'" 'percentage progress noise assertion' || return 1
    require_line "$url_input" 'docker rm -f "$url_container"' 'URL container trap cleanup' || return 1

    only_down_step=$(extract_step "$file" build-and-smoke 'Generated entrypoint download-only smoke')
    only_down_input=$(printf '%s\n' "$only_down_step")
    require_line "$only_down_input" 'fake_cf=' 'download-only fake binary setup' || return 1
    require_line "$only_down_input" 'chmod 0755 "$fake_cf"' 'download-only fake executable' || return 1
    require_line "$only_down_input" '--mount type=bind,src="$fake_cf",dst=/usr/local/bin/cf_speedtest,readonly' 'download-only fake binary mount' || return 1
    require_line "$only_down_input" '-e RUN_SPEEDTEST_DIRECT=true' 'download-only direct toggle' || return 1
    require_line "$only_down_input" '-e RUN_SPEEDTEST_PROXY=false' 'download-only proxy toggle' || return 1
    require_line "$only_down_input" "-e PROXY_CONFIG=''" 'download-only empty proxy' || return 1
    require_line "$only_down_input" "-e HTTP_PROXY='poison-HTTP_PROXY'" 'download-only HTTP_PROXY poison' || return 1
    require_line "$only_down_input" "-e HTTPS_PROXY='poison-HTTPS_PROXY'" 'download-only HTTPS_PROXY poison' || return 1
    require_line "$only_down_input" "-e ALL_PROXY='poison-ALL_PROXY'" 'download-only ALL_PROXY poison' || return 1
    require_line "$only_down_input" "-e NO_PROXY='poison-NO_PROXY'" 'download-only NO_PROXY poison' || return 1
    require_line "$only_down_input" "-e http_proxy='poison-http_proxy'" 'download-only http_proxy poison' || return 1
    require_line "$only_down_input" "-e https_proxy='poison-https_proxy'" 'download-only https_proxy poison' || return 1
    require_line "$only_down_input" "-e all_proxy='poison-all_proxy'" 'download-only all_proxy poison' || return 1
    require_line "$only_down_input" "-e no_proxy='poison-no_proxy'" 'download-only no_proxy poison' || return 1
    require_line "$only_down_input" "-e URL_DDL=''" 'download-only empty URL' || return 1
    require_line "$only_down_input" '-e SPEEDTEST_DOWNLOAD_ONLY=true' 'download-only mode toggle' || return 1
    require_line "$only_down_input" '-e DOWNLOAD_THREADS=4' 'download-only four workers' || return 1
    require_line "$only_down_input" '-e WAIT_TIME=30' 'download-only bounded wait setting' || return 1
    require_line "$only_down_input" 'for proxy_key in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do' 'download-only proxy poison audit' || return 1
    require_line "$only_down_input" 'if printenv "$proxy_key" >/dev/null 2>&1; then' 'download-only proxy poison fail-fast' || return 1
    require_line "$only_down_input" '/tmp/speedtest-diy-fake-state/cf.calls' 'download-only fake logs after proxy audit' || return 1
    require_line "$only_down_input" '/tmp/speedtest-diy-fake-state/cf.pid' 'download-only held fake marker' || return 1
    require_line "$only_down_input" 'trap '\'':'\'' TERM INT' 'download-only fake ignores TERM' || return 1
    require_line "$only_down_input" 'while [[ ! -e /tmp/speedtest-diy-fake-state/release-cf ]]; do' 'download-only fake holds in flight' || return 1
    require_line "$only_down_input" 'timeout 90s bash -c' 'bounded download-only smoke' || return 1
    require_line "$only_down_input" 'Starting direct speed test (download-only, 10 sec)' 'download-only start assertion' || return 1
    require_line "$only_down_input" 'grep -Fq -- '\''--download-only'\'' "$fake_state/cf.calls"' 'download-only fake argument assertion' || return 1
    require_line "$only_down_input" 'grep -Fq -- '\''--download-threads 4'\'' "$fake_state/cf.calls"' 'download thread fake argument assertion' || return 1
    require_line "$only_down_input" '[ -s "$fake_state/cf.pid" ]' 'download-only held process assertion' || return 1
    require_line "$only_down_input" 'Starting direct speed test (download and upload' 'both-direction log prohibition' || return 1
    require_line "$only_down_input" 'timeout 10s docker stop --time 5 "$only_down_container"' 'download-only bounded stop' || return 1
    require_line "$only_down_input" '[ "$(docker inspect -f '\''{{.State.Running}}'\'' "$only_down_container")" = false ]' 'download-only stopped-state assertion' || return 1
    require_line "$only_down_input" '[ "$(docker inspect -f '\''{{.State.ExitCode}}'\'' "$only_down_container")" = 0 ]' 'download-only exit code assertion' || return 1
    require_line "$only_down_input" 'only_down_logs=$(docker logs "$only_down_container" 2>&1 || true)' 'download-only post-stop log reread' || return 1
    require_line "$only_down_input" 'Stop requested. Cleaning up and exiting...' 'download-only English shutdown assertion' || return 1
    require_line "$only_down_input" 'Arrêt du script demandé.' 'French shutdown prohibition' || return 1
    require_line "$only_down_input" 'rm -rf -- "$fake_root"' 'download-only fake trap cleanup' || return 1

    empty_proxy_step=$(extract_step "$file" build-and-smoke 'Empty proxy speed-test protection smoke')
    empty_proxy_input=$(printf '%s\n' "$empty_proxy_step")
    require_line "$empty_proxy_input" '--mount type=bind,src="$empty_proxy_fake_cf",dst=/usr/local/bin/cf_speedtest,readonly' 'empty-proxy fake binary mount' || return 1
    require_line "$empty_proxy_input" '-e RUN_SPEEDTEST_DIRECT=false' 'empty-proxy direct toggle' || return 1
    require_line "$empty_proxy_input" '-e RUN_SPEEDTEST_PROXY=true' 'empty-proxy proxy toggle' || return 1
    require_line "$empty_proxy_input" "-e PROXY_CONFIG=''" 'empty-proxy empty configuration' || return 1
    require_line "$empty_proxy_input" "-e URL_DDL=''" 'empty-proxy empty URL' || return 1
    require_line "$empty_proxy_input" '-e WAIT_TIME=30' 'empty-proxy wait setting' || return 1
    require_line "$empty_proxy_input" 'timeout 60s bash -c' 'bounded empty-proxy smoke' || return 1
    require_line "$empty_proxy_input" 'WARNING: proxy speed test skipped: PROXY_CONFIG is empty or unset.' 'exact empty-proxy warning' || return 1
    require_line "$empty_proxy_input" '[ ! -e "$empty_proxy_state/cf.calls" ]' 'empty-proxy fake marker absence assertion' || return 1
    require_line "$empty_proxy_input" 'Waiting 30 seconds before running the tests again...' 'empty-proxy wait reached assertion' || return 1
    require_line "$empty_proxy_input" 'timeout 10s docker stop --time 5 "$empty_proxy_container"' 'empty-proxy bounded stop' || return 1
    require_line "$empty_proxy_input" '[ "$(docker inspect -f '\''{{.State.Running}}'\'' "$empty_proxy_container")" = false ]' 'empty-proxy stopped-state assertion' || return 1
    require_line "$empty_proxy_input" '[ "$(docker inspect -f '\''{{.State.ExitCode}}'\'' "$empty_proxy_container")" = 0 ]' 'empty-proxy exit code assertion' || return 1
    require_line "$empty_proxy_input" 'Stop requested. Cleaning up and exiting...' 'empty-proxy English shutdown assertion' || return 1
    require_line "$empty_proxy_input" 'rm -rf -- "$empty_proxy_root"' 'empty-proxy fake trap cleanup' || return 1

    sigterm_step=$(extract_step "$file" build-and-smoke 'Verify SIGTERM shutdown')
    sigterm_input=$(printf '%s\n' "$sigterm_step")
    require_line "$sigterm_input" 'fake_root=' 'default smoke fake state setup' || return 1
    require_line "$sigterm_input" '--mount type=bind,src="$fake_cf",dst=/usr/local/bin/cf_speedtest,readonly' 'default smoke fake binary mount' || return 1
    require_line "$sigterm_input" "-e URL_DDL=''" 'default smoke empty URL' || return 1
    if grep -Fq -- 'RUN_SPEEDTEST_DIRECT' <<<"$sigterm_input" ||
        grep -Fq -- 'RUN_SPEEDTEST_PROXY' <<<"$sigterm_input"; then
        printf 'FAIL: default lifecycle smoke overrides image speed-test defaults\n' >&2
        return 1
    fi
    require_line "$sigterm_input" 'Starting in 5 seconds...' 'English initial smoke marker' || return 1
    require_line "$sigterm_input" 'Direct speed test disabled.' 'English direct-disabled smoke marker' || return 1
    require_line "$sigterm_input" 'Proxy speed test disabled.' 'English proxy-disabled smoke marker' || return 1
    require_line "$sigterm_input" 'URL_DDL is empty. Download skipped.' 'English empty-URL smoke marker' || return 1
    require_line "$sigterm_input" 'Waiting 30 seconds before running the tests again...' 'English wait smoke marker' || return 1
    require_line "$sigterm_input" '[ ! -e "$fake_state/cf.calls" ]' 'default smoke fake was never called' || return 1
    require_line "$sigterm_input" 'Arrêt du script demandé.' 'French log prohibition' || return 1
    require_line "$sigterm_input" 'Stop requested. Cleaning up and exiting...' 'English shutdown log assertion' || return 1
    require_line "$sigterm_input" 'timeout 10s docker stop --time 5' 'bounded SIGTERM smoke' || return 1
    require_line "$sigterm_input" 'logs=$(docker logs "$container_id" 2>&1 || true)' 'post-stop Docker log reread' || return 1
    require_line "$sigterm_input" "docker inspect -f '{{.State.Running}}' \"\$container_id\"" 'post-stop State.Running check' || return 1
    require_line "$sigterm_input" "docker inspect -f '{{.State.ExitCode}}' \"\$container_id\"" 'post-stop ExitCode check' || return 1
    require_line "$sigterm_input" '= false ]' 'post-stop stopped-state assertion' || return 1

    initial_step=$(extract_step "$file" build-and-smoke 'Verify SIGTERM during initial wait')
    initial_input=$(printf '%s\n' "$initial_step")
    require_line "$initial_input" 'initial_container=' 'initial-wait smoke container' || return 1
    require_line "$initial_input" "-e URL_DDL=''" 'initial-wait empty URL' || return 1
    require_line "$initial_input" 'Starting in 5 seconds...' 'initial-wait marker' || return 1
    require_line "$initial_input" 'timeout 15s bash -c' 'bounded initial-wait polling' || return 1
    require_line "$initial_input" 'timeout 10s docker stop --time 5 "$initial_container"' 'initial-wait bounded stop' || return 1
    require_line "$initial_input" 'docker inspect -f '\''{{.State.Running}}'\'' "$initial_container"' 'initial-wait stopped-state assertion' || return 1
    require_line "$initial_input" '[ "$(docker inspect -f '\''{{.State.ExitCode}}'\'' "$initial_container")" = 0 ]' 'initial-wait exit code assertion' || return 1
    require_line "$initial_input" 'initial_logs=$(docker logs "$initial_container" 2>&1 || true)' 'initial-wait post-stop log reread' || return 1
    require_line "$initial_input" 'Stop requested. Cleaning up and exiting...' 'initial-wait English shutdown' || return 1
    require_line "$initial_input" 'docker rm -f "$initial_container"' 'initial-wait minimal cleanup' || return 1
}

anonymous_ghcr_contract() {
    local file=$ROOT/.github/workflows/container.yml
    local job public_step public_input

    require_file "$file" || return 1
    job=$(extract_job "$file" verify-public-pull)
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
        'docker pull --platform linux/amd64 "$sha_image"' \
        'sha_id=$(docker image inspect --format '\''{{.Id}}'\'' "$sha_image")' \
        'case "$GITHUB_REF" in' \
        'refs/heads/main)' \
        'refs/tags/v*)' \
        'latest_id=$(docker image inspect --format '\''{{.Id}}'\'' "$latest_image")' \
        '[ "$latest_id" = "$sha_id" ]' \
        'docker run -d --name "$sha_container" --platform linux/amd64' \
        'RUN_SPEEDTEST_DIRECT=false' \
        'RUN_SPEEDTEST_PROXY=false' \
        "URL_DDL=''" \
        'WAIT_TIME=30' \
        'Waiting 30 seconds before running the tests again...' \
        'timeout 10s docker stop --time 5 "$sha_container"'; do
        if ! grep -Fq -- "$needle" <<<"$job"; then
            printf 'FAIL: anonymous GHCR contract (missing %s)\n' "$needle" >&2
            return 1
        fi
    done

    if ! awk '
        /case "\$GITHUB_REF" in/ { in_case=1 }
        in_case && /refs\/heads\/main\)/ { in_main=1 }
        in_main && /docker pull --platform linux\/amd64 "\$latest_image"/ { latest_pull=1 }
        in_main && /docker image inspect --format/ && /"\$latest_image"/ { latest_inspect=1 }
        in_main && /refs\/tags\/v\*\)/ { tag_branch=1 }
        END { exit !(in_case && in_main && latest_pull && latest_inspect && tag_branch) }
    ' <<<"$job"; then
        printf 'FAIL: latest image operations are not confined to the main branch\n' >&2
        return 1
    fi

    public_step=$(extract_step "$file" verify-public-pull 'Pull, inspect, and run GHCR images anonymously')
    public_input=$(printf '%s\n' "$public_step")
    require_line "$public_input" 'sha_id=$(docker image inspect --format '\''{{.Id}}'\'' "$sha_image")' 'public SHA image inspection' || return 1
    require_line "$public_input" 'docker run --rm --platform linux/amd64 --entrypoint /bin/bash "$sha_image" -c' 'public SHA helper inspection invocation' || return 1
    require_line "$public_input" 'test -x /usr/local/bin/network-runtime.sh' 'public network helper inspection' || return 1
    require_line "$public_input" 'test -x "$(command -v curl)"' 'public curl inspection' || return 1
    require_line "$public_input" 'test -s /etc/ssl/certs/ca-certificates.crt' 'public CA inspection' || return 1
    require_line "$public_input" 'sha_url_container="speedtest-diy-published-sha-url-${GITHUB_RUN_ID:-local}"' 'named published SHA URL container' || return 1
    require_line "$public_input" '--name "$sha_url_container"' 'named SHA URL smoke container' || return 1
    require_line "$public_input" '"$sha_image" >/dev/null' 'public SHA URL image selection' || return 1
    require_line "$public_input" "-e PROXY_CONFIG=''" 'public direct empty proxy' || return 1
    require_line "$public_input" '-e DOWNLOAD_THREADS=4' 'public direct four workers' || return 1
    require_line "$public_input" '-e WAIT_TIME=300' 'public URL long wait' || return 1
    require_line "$public_input" '-e HTTP_PROXY='\''poison-HTTP_PROXY'\''' 'public HTTP_PROXY poison' || return 1
    require_line "$public_input" '-e HTTPS_PROXY='\''poison-HTTPS_PROXY'\''' 'public HTTPS_PROXY poison' || return 1
    require_line "$public_input" '-e ALL_PROXY='\''poison-ALL_PROXY'\''' 'public ALL_PROXY poison' || return 1
    require_line "$public_input" '-e NO_PROXY='\''poison-NO_PROXY'\''' 'public NO_PROXY poison' || return 1
    require_line "$public_input" '-e http_proxy='\''poison-http_proxy'\''' 'public http_proxy poison' || return 1
    require_line "$public_input" '-e https_proxy='\''poison-https_proxy'\''' 'public https_proxy poison' || return 1
    require_line "$public_input" '-e all_proxy='\''poison-all_proxy'\''' 'public all_proxy poison' || return 1
    require_line "$public_input" '-e no_proxy='\''poison-no_proxy'\''' 'public no_proxy poison' || return 1
    require_line "$public_input" 'https://github.com/cli/cli/releases/download/v2.100.0/gh_2.100.0_linux_amd64.tar.gz' 'public exact default URL' || return 1
    require_line "$public_input" 'timeout 180s bash -c' 'bounded public URL smoke' || return 1
    require_line "$public_input" 'URL download complete: total bytes=15152253, concurrent segments=4, transport=direct' 'public exact summary' || return 1
    require_line "$public_input" 'timeout 10s docker stop --time 5 "$sha_url_container"' 'public URL bounded stop' || return 1
    require_line "$public_input" 'docker inspect -f '\''{{.State.Running}}'\'' "$sha_url_container"' 'public URL stopped-state assertion' || return 1
    require_line "$public_input" 'docker inspect -f '\''{{.State.ExitCode}}'\'' "$sha_url_container"' 'public URL exit-code assertion' || return 1
    require_line "$public_input" 'sha_url_logs=$(docker logs "$sha_url_container" 2>&1 || true)' 'public URL post-stop log reread' || return 1
    require_line "$public_input" 'grep -Fxc -- "$summary" <<<"$sha_url_logs"' 'public one-line summary assertion' || return 1
    require_line "$public_input" 'grep -Fq -- "$sha_url" <<<"$sha_url_logs"' 'public URL redaction assertion' || return 1
    require_line "$public_input" "'saved'" 'public progress noise assertion' || return 1
    require_line "$public_input" "'%'" 'public percentage progress noise assertion' || return 1
    require_line "$public_input" 'docker rm -f "$sha_container"' 'sha container trap cleanup' || return 1
    require_line "$public_input" 'docker rm -f "$sha_url_container"' 'public SHA URL trap cleanup' || return 1
    if grep -Fq -- 'latest_url_container' <<<"$job" ||
        grep -Fq -- 'latest_url=' <<<"$public_input" ||
        grep -Fq -- '"$latest_image" >/dev/null' <<<"$public_input"; then
        printf 'FAIL: public verification uses a misleading or unconditional latest URL image\n' >&2
        return 1
    fi
    if grep -Fq -- '-e WAIT_TIME=1' <<<"$public_input"; then
        printf 'FAIL: public URL smoke still uses WAIT_TIME=1\n' >&2
        return 1
    fi
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
    local file=$ROOT/Dockerfile builder_commands command frozen_file
    local rust_digest='rust:1.87.0-slim-bookworm@sha256:c6d2b4f8115be78af2a07072f61cffbbb4d6c93b55a4712b922fb7391db6a2bc'
    local runtime_digest='zephir284/speedtest@sha256:5b2431c251a10ed6dc6600bba6dcb3ca0b5682b00700c17f1a970478e55a7334'
    require_file "$file" || return 1
    require_line "$file" "FROM --platform=linux/amd64 $rust_digest AS builder" 'frozen amd64 Rust builder' || return 1
    require_line "$file" "FROM --platform=linux/amd64 $runtime_digest" 'frozen amd64 runtime base' || return 1
    for frozen_file in \
        'COPY third_party/cf_speedtest/Cargo.toml' \
        'COPY third_party/cf_speedtest/Cargo.lock' \
        'COPY third_party/cf_speedtest/src' \
        'COPY third_party/cf_speedtest/LICENSE.txt' \
        'COPY third_party/cf_speedtest/UPSTREAM.json'; do
        require_line "$file" "$frozen_file" "frozen Rust source copy: $frozen_file" || return 1
    done
    require_line "$file" 'cargo fetch --locked' 'locked Rust dependency fetch' || return 1
    require_regex "$file" 'cargo[[:space:]]+test[^\n]*--locked[^\n]*--offline' 'offline locked Rust tests' || return 1
    require_regex "$file" 'cargo[[:space:]]+build[^\n]*--locked[^\n]*--offline' 'offline locked Rust build' || return 1
    builder_commands=$(grep -nE 'cargo[[:space:]]+(test|build)' "$file" || true)
    while IFS= read -r command; do
        [ -n "$command" ] || continue
        case "$command" in
            *'--offline'*) ;;
            *)
                printf 'FAIL: live Rust test/build command is forbidden: %s\n' "$command" >&2
                return 1
                ;;
        esac
    done <<<"$builder_commands"
    require_line "$file" 'COPY --from=builder' 'builder artifact copy' || return 1
    require_regex "$file" '^COPY --from=builder[^\n]*cf_speedtest[^\n]*/usr/local/bin/cf_speedtest' 'runtime cf_speedtest binary path' || return 1
    require_regex "$file" '^COPY --from=builder[^\n]*LICENSE' 'runtime MIT provenance copy' || return 1
    require_line "$file" 'cf_speedtest --help' 'final cf_speedtest help check' || return 1
    require_line "$file" 'apt-get update' 'APT package index update' || return 1
    require_line "$file" 'apt-get install -y --no-install-recommends curl ca-certificates' 'curl and CA package install' || return 1
    require_line "$file" 'rm -rf /var/lib/apt/lists/*' 'APT list cleanup' || return 1
    require_line "$file" 'COPY runtime-log.sh /usr/local/bin/runtime-log.sh' 'runtime logger image copy' || return 1
    require_line "$file" 'COPY random-wait.sh /usr/local/bin/random-wait.sh' 'random helper image copy' || return 1
    require_line "$file" 'COPY network-runtime.sh /usr/local/bin/network-runtime.sh' 'network helper image copy' || return 1
    require_line "$file" 'COPY patch-entrypoint.sh /usr/local/bin/patch-entrypoint.sh' 'patch helper image copy' || return 1
    require_regex "$file" 'chmod[[:space:]]+0755[^\n]*runtime-log\.sh[^\n]*random-wait\.sh[^\n]*network-runtime\.sh[^\n]*patch-entrypoint\.sh' 'runtime helper modes' || return 1
    require_line "$file" '/usr/local/bin/patch-entrypoint.sh /entrypoint.sh' 'build-time patch' || return 1
    require_line "$file" 'ENTRYPOINT ["/entrypoint.sh"]' 'upstream entrypoint' || return 1
    if grep -nE 'git[[:space:]]+clone|^[[:space:]]*ADD[[:space:]]+(https?://|git@)|rust(:|[^[:space:]]*:)latest' "$file"; then
        printf 'FAIL: Dockerfile uses an unfrozen remote/latest builder source\n' >&2
        return 1
    fi
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
        '      URL_DDL: "${URL_DDL-https://github.com/cli/cli/releases/download/v2.100.0/gh_2.100.0_linux_amd64.tar.gz}"' \
        '      WAIT_TIME_MIN: "${WAIT_TIME_MIN:-5}"' \
        '      WAIT_TIME_MAX: "${WAIT_TIME_MAX:-50}"' \
        '      TEST_DURATION: "${TEST_DURATION:-10}"' \
        '      DOWNLOAD_THREADS: "${DOWNLOAD_THREADS:-4}"' \
        '      UPLOAD_THREADS: "${UPLOAD_THREADS:-4}"' \
        '      SPEEDTEST_DOWNLOAD_ONLY: "${SPEEDTEST_DOWNLOAD_ONLY:-false}"' \
        '      RUN_SPEEDTEST_DIRECT: "${RUN_SPEEDTEST_DIRECT:-false}"' \
        '      RUN_SPEEDTEST_PROXY: "${RUN_SPEEDTEST_PROXY:-false}"' \
        '      PROXY_CONFIG: "${PROXY_CONFIG:-}"'; do
        count=$(grep -Fxc -- "$needle" "$file" 2>/dev/null || true)
        if [ "$count" -ne 1 ]; then
            printf 'FAIL: Compose contract (expected exactly one line: %s; found %s)\n' "$needle" "$count" >&2
            return 1
        fi
    done
    require_no_line "$file" 'ai.here.link' 'Compose legacy ai.here.link URL' || return 1
    require_no_line "$file" 'socks5 127.0.0.1 9100' 'Compose synthesized localhost proxy' || return 1
    require_no_line "$file" '${URL_DDL:-' 'Compose empty URL must not fall back to default' || return 1
    if grep -nE '^[[:space:]]*(ports|volumes):' "$file"; then
        printf 'FAIL: Compose contract (ports/volumes are forbidden)\n' >&2
        return 1
    fi
    if grep -nE '^[[:space:]]*-[[:space:]]*(URL_DDL|WAIT_TIME_MIN|WAIT_TIME_MAX|TEST_DURATION|DOWNLOAD_THREADS|UPLOAD_THREADS|SPEEDTEST_DOWNLOAD_ONLY|RUN_SPEEDTEST_DIRECT|RUN_SPEEDTEST_PROXY|PROXY_CONFIG)(:|[[:space:]])' "$file"; then
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
        'SPEEDTEST_DOWNLOAD_ONLY' 'RUN_SPEEDTEST_DIRECT' 'RUN_SPEEDTEST_PROXY' 'URL_DDL' \
        'DOWNLOAD_THREADS` 同时控制 `cf_speedtest` 的下载线程数和 `URL_DDL` 的分段连接 worker 数；有效范围为 1～64。' \
        'N>1` 时先发起 `bytes 0-0` 的一字节 Range probe，再发起互不重叠的 Range 请求覆盖 `byte 1` 到对象末尾。' \
        '`probe` 计入 `byte 0`，所有响应体都写入 `/dev/null`，因此总响应体仍是一个对象。' \
        'Range 不受支持或响应不匹配时 fail closed；不会退回 N 个完整 GET。' \
        'HTTP 元数据只在私有临时目录短暂保存，并在结束、失败或取消时清理' \
        '`URL_DDL` 和 `cf_speedtest` 的子进程都会清除 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY`、`http_proxy`、`https_proxy`、`all_proxy`、`no_proxy` 八个环境变量' \
        'curl 使用 `--disable --noproxy '\''*'\''`，因此不读取 `.curlrc`。' \
        '只有显式非空 `PROXY_CONFIG` 才选择 `proxychains4`' \
        '`PROXY_CONFIG` 未设置或为空时，URL_DDL 直连；非空时通过 `proxychains4`。' \
        'RUN_SPEEDTEST_PROXY=true 但 PROXY_CONFIG 为空时只输出英文 warning 并跳过，绝不意外直连。' \
        '`RUN_SPEEDTEST_DIRECT=true` 表示通过直连执行 `cf_speedtest`。' \
        'SPEEDTEST_DOWNLOAD_ONLY=false' \
        'true` 时传给 `cf_speedtest` `--download-only`，且不执行 upload 阶段' \
        '`UPLOAD_THREADS` 在 only-down 模式下不生效。' \
        '默认关闭两类 cf_speedtest，URL_DDL 直连：' \
        '镜像默认 `RUN_SPEEDTEST_DIRECT=false`、`RUN_SPEEDTEST_PROXY=false`。' \
        '只有在 `URL_DDL` 未设置时，Compose 才填入固定默认 URL；显式 `URL_DDL=` 保持为空并禁用下载。' \
        '### (a) 默认：直连 URL_DDL' '### (b) 代理 URL_DDL' '### (c) 直连 download-only speedtest' \
        'PROXY_CONFIG="socks5 192.0.2.10 9100"' \
        'RUN_SPEEDTEST_DIRECT=true' 'SPEEDTEST_DOWNLOAD_ONLY=true' \
        '5～50' 'ghcr.io/wujun8/speedtest-diy' 'Debian x86_64' \
        '创建本地 `.env`' 'docker compose up -d' \
        'docker compose logs -f speedtest' 'docker compose stop' \
        '不挂载 volumes' '不发布 ports' '只面向 `linux/amd64`' \
        '5 秒' '2147483647' 'sha256:5b2431c251a10ed6dc6600bba6dcb3ca0b5682b00700c17f1a970478e55a7334' \
        'https://github.com/cli/cli/releases/download/v2.100.0/gh_2.100.0_linux_amd64.tar.gz' \
        'GitHub CLI' 'v2.100.0' 'immutable' '15152253' \
        'sha256:e4d4bb4498e8d007abe545b6568926793ace1b6447da598294a610018cb164be' \
        'Range' '206' 'bytes 0-0/15152253' \
        '用户可见自有运行日志统一为英文' \
        'Docker Hub API' 'source' '公开描述未声明许可证' \
        'verify-public-pull' 'docker pull' 'docker run' '匿名' 'Public' \
        '真实网络流量' '带宽' \
        'sha-${GITHUB_SHA::7}' \
        '仅在 `main` 上额外拉取 `latest`，并要求其 Docker image ID 与 SHA 镜像 ID 相同；`v*` tag 不拉取也不使用 `latest`；' \
        '默认 URL smoke 对 main 和 tag 都使用 SHA 镜像。'; do
        require_line "$file" "$needle" "README contract" || return 1
    done
    for obsolete in \
        'proxychains4 wget' \
        'wget' \
        'socks5 127.0.0.1 9100' \
        '除等待 seam 外' \
        '只在构建期对等待间隔 seam 做精确补丁' \
        'URL_DDL 仍经' \
        '不能修改为绕过'; do
        require_no_line "$file" "$obsolete" "README obsolete claim removal" || return 1
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
run_group 'runtime logger behavior' bash "$ROOT/tests/test_runtime_log.sh"
run_group 'random wait behavior' bash "$ROOT/tests/test_random_wait.sh"
run_group 'network runtime behavior' bash "$ROOT/tests/test_network_runtime.sh"
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
