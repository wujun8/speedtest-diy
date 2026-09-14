# speedtest-diy：固定或随机间隔的测速派生镜像

这是基于上游 `zephir284/speedtest` 的 Debian x86_64 / `linux/amd64` 派生镜像。它保留上游的直连测速、代理测速和 `URL_DDL` 下载入口，并在构建期应用经过校验的入口补丁。

## 不可变上游事实

- 基础镜像固定为 `zephir284/speedtest@sha256:5b2431c251a10ed6dc6600bba6dcb3ca0b5682b00700c17f1a970478e55a7334`。
- 上游只提供 `linux/amd64`；本项目不宣称支持 arm64。目标运行环境示例为 Debian x86_64。
- 构建期会校验上游 `/entrypoint.sh` 的 SHA256：`4ce13988639aba6ba591b5025023ef13b8db23490bbfcd96167e492a7f8e1f9d`。上游入口漂移或内容变化时构建 fail-closed，不会静默套用补丁。
- Compose 默认 `URL_DDL` 固定为 `https://github.com/cli/cli/releases/download/v2.100.0/gh_2.100.0_linux_amd64.tar.gz`。GitHub CLI release `v2.100.0` API 标记为 `immutable`；已核验资产大小为 `15152253` bytes，asset digest 为 `sha256:e4d4bb4498e8d007abe545b6568926793ace1b6447da598294a610018cb164be`，一字节 Range 实测返回 `206`，`Content-Range: bytes 0-0/15152253`。
- 用户可见自有运行日志统一为英文，并且每一物理行都带 UTC、ISO-8601 毫秒时间戳，例如 `[YYYY-MM-DDTHH:MM:SS.mmmZ]`；第三方命令的输出不翻译。

## 构建与运行

在 Debian x86_64 主机上：

```bash
docker build --platform linux/amd64 \
  -t ghcr.io/wujun8/speedtest-diy:local .

docker run --rm --platform linux/amd64 --network host \
  -e RUN_SPEEDTEST_DIRECT=true \
  -e RUN_SPEEDTEST_PROXY=false \
  ghcr.io/wujun8/speedtest-diy:local
```

镜像只面向 `linux/amd64`。默认入口会先等待 5 秒。镜像默认 `RUN_SPEEDTEST_DIRECT=false`、`RUN_SPEEDTEST_PROXY=false`。只有显式设置为 `true` 才运行对应的 `cf_speedtest` 任务。

## URL_DDL 下载与连接并发

`DOWNLOAD_THREADS` 同时控制 `cf_speedtest` 的下载线程数和 `URL_DDL` 的分段连接 worker 数；有效范围为 1～64。

- `DOWNLOAD_THREADS=1` 使用一次完整 GET，并把响应体写入 `/dev/null`。
- `N>1` 时先发起 `bytes 0-0` 的一字节 Range probe，再发起互不重叠的 Range 请求覆盖 `byte 1` 到对象末尾。
- `probe` 计入 `byte 0`，所有响应体都写入 `/dev/null`，因此总响应体仍是一个对象。
- Range 不受支持或响应不匹配时 fail closed；不会退回 N 个完整 GET。
- HTTP 元数据只在私有临时目录短暂保存，并在结束、失败或取消时清理；不会生成 payload 文件。
- `PROXY_CONFIG` 未设置或为空时，URL_DDL 直连；非空时通过 `proxychains4`。

`URL_DDL` 和 `cf_speedtest` 的子进程都会清除 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY`、`http_proxy`、`https_proxy`、`all_proxy`、`no_proxy` 八个环境变量；curl 使用 `--disable --noproxy '*'`，因此不读取 `.curlrc`。只有显式非空 `PROXY_CONFIG` 才选择 `proxychains4`，ambient proxy 环境变量不会改变传输选择。

下载会真实消耗带宽。尤其是默认 GitHub CLI 资产和较大的自定义 URL，频繁运行可能消耗流量配额并触发服务端限流；请按网络和服务条款选择等待间隔。

## cf_speedtest 直连、代理与 only-down

- `RUN_SPEEDTEST_DIRECT=true` 表示通过直连执行 `cf_speedtest`。
- `RUN_SPEEDTEST_PROXY=true` 只有在 `PROXY_CONFIG` 非空时才执行代理测速；RUN_SPEEDTEST_PROXY=true 但 PROXY_CONFIG 为空时只输出英文 warning 并跳过，绝不意外直连。实际警告为 `WARNING: proxy speed test skipped: PROXY_CONFIG is empty or unset.`
- `SPEEDTEST_DOWNLOAD_ONLY=false` 是默认值；false 时下载和上传都执行，每个方向持续 `TEST_DURATION` 秒。
- `SPEEDTEST_DOWNLOAD_ONLY=true` 时传给 `cf_speedtest` `--download-only`，且不执行 upload 阶段；该规则同时适用于直连和已配置代理的测速。
- `UPLOAD_THREADS` 在 only-down 模式下不生效。
- 直连、代理测速和 URL 下载都使用真实网络流量，请避免在不需要时同时打开多个任务。

### Cloudflare 请求大小、节流与 429

- `SPEEDTEST_DOWNLOAD_BYTES` 和 `SPEEDTEST_UPLOAD_BYTES` 分别控制一次下载或上传的单次 HTTP 请求大小，默认都是 `10485760`（10 MiB），有效范围为 1～2147483647；它们不是整轮测速的总字节数。
- `DOWNLOAD_THREADS` 仍控制并发，但同一方向的 worker 通过共享请求门控启动，每次实际请求的开始时间至少间隔 250 ms，避免并发瞬时突发。
- 每次实际请求（包括 429 重试）都生成新的非零 `measId`，不会重复使用失败请求的 ID。
- HTTP 429 最多重试 2 次，因此总计最多 3 次请求。十进制 `Retry-After` 为 1～30 秒时按该值等待；无效或缺失时依次等待 1 秒、2 秒。`Retry-After` 超过 30 秒时 fail closed 并停止该方向，非 429 不重试。
- 请求的方向无有效样本时非零退出，且不输出全零测速结果表；已有有效样本后发生终止错误也会非零退出，不把部分结果伪装为成功。
- 这些措施降低快速重试和大请求触发限流的风险，但不能保证消除服务端限制，仍可能收到 HTTP 429。

## Compose 仅 URL_DDL 下载

`compose.yaml` 保留 `network_mode: host`、`restart: unless-stopped` 和 `linux/amd64` 平台设置，不挂载 volumes，也不发布 ports。Compose 默认关闭两类 cf_speedtest，URL_DDL 直连：`RUN_SPEEDTEST_DIRECT=false`、`RUN_SPEEDTEST_PROXY=false`、`PROXY_CONFIG` 为空。只有在 `URL_DDL` 未设置时，Compose 才填入固定默认 URL；显式 `URL_DDL=` 保持为空并禁用下载。

启动、查看日志和停止：

```bash
docker compose up -d
docker compose logs -f speedtest
docker compose stop
```

在同目录创建本地 `.env`（不要提交该文件）即可覆盖配置。以下示例分别展示默认直连 URL、代理 URL 和直连 download-only speedtest。

### (a) 默认：直连 URL_DDL

```dotenv
URL_DDL=https://github.com/cli/cli/releases/download/v2.100.0/gh_2.100.0_linux_amd64.tar.gz
PROXY_CONFIG=
RUN_SPEEDTEST_DIRECT=false
RUN_SPEEDTEST_PROXY=false
```

### (b) 代理 URL_DDL

```dotenv
URL_DDL=https://example.invalid/assets/test.bin
PROXY_CONFIG="socks5 192.0.2.10 9100"
RUN_SPEEDTEST_DIRECT=false
RUN_SPEEDTEST_PROXY=false
```

### (c) 直连 download-only speedtest

```dotenv
URL_DDL=
PROXY_CONFIG=
RUN_SPEEDTEST_DIRECT=true
RUN_SPEEDTEST_PROXY=false
SPEEDTEST_DOWNLOAD_ONLY=true
TEST_DURATION=10
DOWNLOAD_THREADS=4
UPLOAD_THREADS=4
```

## 等待间隔变量与优先级

默认随机等待范围为 5～50 秒，首次启动固定等待 5 秒。`WAIT_TIME` 未设置或显式为空时，在 `WAIT_TIME_MIN=5` 到 `WAIT_TIME_MAX=50` 秒之间随机等待；随机值含边界，且最大值为 `2147483647` 秒。非法配置会在首次测速前写 stderr 并以非零状态退出，避免紧循环。

优先级从高到低：

1. `WAIT_TIME` 非空：采用固定秒数，优先于随机上下界；例如 `WAIT_TIME=300` 时每轮固定等待 300 秒。
2. `WAIT_TIME` 未设置或显式为空：采用 `WAIT_TIME_MIN` / `WAIT_TIME_MAX`，未设置的一侧分别默认为 5 / 50 秒。

固定间隔示例：

```bash
docker run --rm --platform linux/amd64 --network host \
  -e WAIT_TIME=21600 \
  ghcr.io/wujun8/speedtest-diy:local
```

随机区间示例：

```bash
docker run --rm --platform linux/amd64 --network host \
  -e WAIT_TIME_MIN=10 \
  -e WAIT_TIME_MAX=120 \
  ghcr.io/wujun8/speedtest-diy:local
```

## 完整兼容环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `WAIT_TIME` | 未设置（显式空值也相同） | 非空时固定等待秒数，并优先于随机上下界；必须为正整数且不超过 `2147483647`。 |
| `WAIT_TIME_MIN` | `5` | `WAIT_TIME` 为空时的随机下界，含边界的正整数。 |
| `WAIT_TIME_MAX` | `50` | `WAIT_TIME` 为空时的随机上界，含边界的正整数。 |
| `PROXY_CONFIG` | 空 | `PROXY_CONFIG` 为空时 URL_DDL 直连；非空时使用 `proxychains4`。 |
| `TEST_DURATION` | `10` | `cf_speedtest` 每个方向的测速持续秒数。 |
| `DOWNLOAD_THREADS` | `4` | 同时控制 `cf_speedtest` 下载线程和 URL 分段连接 worker；范围 1～64。 |
| `UPLOAD_THREADS` | `4` | `cf_speedtest` 上传线程；only-down 模式下不生效。 |
| `SPEEDTEST_DOWNLOAD_BYTES` | `10485760`（10 MiB） | `cf_speedtest` 每个下载请求的单次 HTTP 请求字节数；范围 1～2147483647。 |
| `SPEEDTEST_UPLOAD_BYTES` | `10485760`（10 MiB） | `cf_speedtest` 每个上传请求的单次 HTTP 请求字节数；范围 1～2147483647。 |
| `SPEEDTEST_DOWNLOAD_ONLY` | `false` | `true` 只执行下载并传入 `--download-only`；false 执行下载和上传。 |
| `RUN_SPEEDTEST_DIRECT` | `false` | `true` 时运行直连测速。 |
| `RUN_SPEEDTEST_PROXY` | `false` | `true` 且代理已配置时运行代理测速；代理为空则英文 warning 后跳过。 |
| `URL_DDL` | Compose 默认 GitHub CLI 固定资产 URL | 非空时按 Range/并发规则下载到 `/dev/null`；为空则跳过。 |

## 上游许可信息（事实范围）

截至本项目核验，Docker Hub API 返回的 `source` 字段为 `null`，上游公开描述未声明许可证；本次核验未发现上游许可声明。本项目不宣称能为上游二进制重新授权；使用或再分发者需自行核对上游条款。

## GHCR 发布与 CI

发布路径为 `ghcr.io/wujun8/speedtest-diy`。GitHub Actions 在 pull request 上执行测试、`linux/amd64` 构建和真实 Docker smoke；`main` push 与 `v*` tag 只有在这些步骤通过后才发布。发布使用内置 `GITHUB_TOKEN`，不需要自定义 secret，并生成：

- `latest`（仅 `main`）；
- short `sha` 标签；
- semver 标签（例如 `v1.2.3` 生成 `1.2.3` 及对应 semver 变体）。

镜像构建和 smoke 都明确使用 `linux/amd64`。CI 会检查等待边界、旧 `WAIT_TIME` 固定间隔、非法配置 fail-fast、补丁 marker、curl、CA bundle、真实默认 URL 下载和英文日志。

### 发布后匿名验收

发布 job 成功后，`verify-public-pull` 会在不执行任何 GHCR 登录的前提下，使用临时空的 `DOCKER_CONFIG` 匿名执行：

1. 在 `linux/amd64` 上始终拉取、inspect 并运行刚发布的 `sha-${GITHUB_SHA::7}` 镜像；
2. 仅在 `main` 上额外拉取 `latest`，并要求其 Docker image ID 与 SHA 镜像 ID 相同；`v*` tag 不拉取也不使用 `latest`；
3. 检查公开 SHA 镜像中的 runtime helper、curl 和 CA bundle；
4. 在 SHA 镜像上以空 `PROXY_CONFIG` 运行一次受限的直连默认 URL smoke，并核对精确字节摘要。默认 URL smoke 对 main 和 tag 都使用 SHA 镜像。

GHCR package 必须设置为 **Public**，否则匿名 `docker pull` 会失败；Actions workflow 不会替你修改 package 可见性。验收仍明确限定为 `linux/amd64`。
