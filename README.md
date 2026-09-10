# speedtest-diy：固定或随机间隔的测速派生镜像

这是基于上游 `zephir284/speedtest` 的 Debian x86_64 / `linux/amd64` 派生镜像。它保留上游的直连测速、代理测速和 `URL_DDL` 下载测试逻辑，只在构建期对等待间隔 seam 做精确补丁。

## 不可变上游事实

- 基础镜像固定为 `zephir284/speedtest@sha256:5b2431c251a10ed6dc6600bba6dcb3ca0b5682b00700c17f1a970478e55a7334`。
- 上游只提供 `linux/amd64`；本项目不宣称支持 arm64。目标运行环境示例为 Debian x86_64。
- 构建期会校验上游 `/entrypoint.sh` 的 SHA256：`4ce13988639aba6ba591b5025023ef13b8db23490bbfcd96167e492a7f8e1f9d`。上游入口漂移或内容变化时构建 fail-closed，不会静默套用补丁。
- `URL_DDL` 继续使用上游的 `proxychains4 wget ... -O /dev/null` 逻辑，不保存下载响应文件。

## 构建与运行

在 Debian x86_64 主机上：

```bash
docker build --platform linux/amd64 \
  -t ghcr.io/wujun8/speedtest-diy:local .

docker run --rm --platform linux/amd64 --network host \
  -e RUN_SPEEDTEST_DIRECT=true \
  -e RUN_SPEEDTEST_PROXY=true \
  ghcr.io/wujun8/speedtest-diy:local
```

首次启动仍固定等待 **5 秒**，然后执行一轮启用的直连测速、代理测速和下载测试。只有整轮结束后才会重新独立采样下一次等待秒数；随机值是含边界的均匀整数。

## 等待间隔变量与优先级

新配置的默认行为是：`WAIT_TIME` 未设置或显式为空时，在 `WAIT_TIME_MIN=5` 到 `WAIT_TIME_MAX=50` 秒之间随机等待。所有等待配置必须是正整数，含边界，且最大值为 `2147483647` 秒。空的 `WAIT_TIME_MIN` 或 `WAIT_TIME_MAX`、零、非数字、超过上限，以及 `WAIT_TIME_MIN > WAIT_TIME_MAX` 都会在首次测速前写 stderr 并以非零状态退出，避免紧循环。

优先级从高到低：

1. `WAIT_TIME` 非空：采用固定秒数，优先于随机上下界；例如 `WAIT_TIME=300` 时每一轮固定等待 300 秒。该值本身仍必须有效。
2. `WAIT_TIME` 未设置或显式为空：采用 `WAIT_TIME_MIN` / `WAIT_TIME_MAX`，未设置的一侧分别默认为 5 / 50 秒。

因此，兼容上游旧配置的固定间隔示例为：

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

镜像使用已具备的 coreutils `shuf` 采样，不使用 shell `eval`，不保存响应文件，不内置凭据，也不添加 arm64 假支持。

## 完整兼容环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `WAIT_TIME` | 未设置（显式空值也相同） | 非空时固定等待秒数，并优先于随机上下界；必须为正整数且不超过 `2147483647`。 |
| `WAIT_TIME_MIN` | `5` | `WAIT_TIME` 为空时的随机下界，含边界的正整数。 |
| `WAIT_TIME_MAX` | `50` | `WAIT_TIME` 为空时的随机上界，含边界的正整数。 |
| `PROXY_CONFIG` | `socks5 127.0.0.1 9100` | 上游 `proxychains4` 的代理配置。 |
| `TEST_DURATION` | `10` | 上游 `cf_speedtest` 的测速持续秒数。 |
| `DOWNLOAD_THREADS` | `4` | 上游直连/代理测速的下载线程数。 |
| `UPLOAD_THREADS` | `4` | 上游直连/代理测速的上传线程数。 |
| `RUN_SPEEDTEST_DIRECT` | `true` | 为 `true` 时运行直连测速；其他值保持上游的禁用语义。 |
| `RUN_SPEEDTEST_PROXY` | `true` | 为 `true` 时通过 `proxychains4` 运行代理测速；其他值保持上游的禁用语义。 |
| `URL_DDL` | 空 | 非空时按上游逻辑通过代理下载，并把内容写入 `/dev/null`；为空则跳过。 |

除等待 seam 外，上述上游变量、测速命令、代理配置和 URL_DDL 语义不变。请注意：测速和下载会产生真实网络流量，频繁的 5～50 秒默认间隔可能消耗带宽、流量配额并触发服务端限流；请按网络、代理和 Cloudflare 服务条款选择间隔。

## 上游许可信息（事实范围）

截至本项目核验，Docker Hub API 返回的 `source` 字段为 `null`，上游公开描述未声明许可证；本次核验未发现上游许可声明。本项目不宣称能为上游二进制重新授权；使用或再分发者需自行核对上游条款。

## GHCR 发布与 CI

发布路径为 `ghcr.io/wujun8/speedtest-diy`。GitHub Actions 在 pull request 上只执行测试、`linux/amd64` 构建和真实 Docker smoke；`main` push 与 `v*` tag 只有在这些步骤通过后才发布。发布使用内置 `GITHUB_TOKEN`，不需要自定义 secret，并自动生成：

- `latest`（仅 `main`）；
- short `sha` 标签；
- semver 标签（例如 `v1.2.3` 生成 `1.2.3` 及对应 semver 变体）。

镜像构建和 smoke 都明确使用 `linux/amd64`。smoke 会验证默认 5～50、边界区间、旧 `WAIT_TIME` 固定间隔、非法配置 fail-fast，以及补丁 marker。
