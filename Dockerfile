FROM --platform=linux/amd64 rust:1.87.0-slim-bookworm@sha256:c6d2b4f8115be78af2a07072f61cffbbb4d6c93b55a4712b922fb7391db6a2bc AS builder

WORKDIR /build/cf_speedtest
COPY third_party/cf_speedtest/Cargo.toml ./Cargo.toml
COPY third_party/cf_speedtest/Cargo.lock ./Cargo.lock
COPY third_party/cf_speedtest/src ./src
COPY third_party/cf_speedtest/LICENSE.txt ./LICENSE.txt
COPY third_party/cf_speedtest/UPSTREAM.json ./UPSTREAM.json
RUN cargo fetch --locked
RUN cargo test --locked --offline
RUN cargo build --release --locked --offline

FROM --platform=linux/amd64 zephir284/speedtest@sha256:5b2431c251a10ed6dc6600bba6dcb3ca0b5682b00700c17f1a970478e55a7334

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/cf_speedtest/target/release/cf_speedtest /usr/local/bin/cf_speedtest
RUN mkdir -p /usr/share/doc/cf_speedtest
COPY --from=builder /build/cf_speedtest/LICENSE.txt /usr/share/doc/cf_speedtest/LICENSE.txt
COPY --from=builder /build/cf_speedtest/UPSTREAM.json /usr/share/doc/cf_speedtest/UPSTREAM.json
COPY runtime-log.sh /usr/local/bin/runtime-log.sh
COPY random-wait.sh /usr/local/bin/random-wait.sh
COPY network-runtime.sh /usr/local/bin/network-runtime.sh
COPY patch-entrypoint.sh /usr/local/bin/patch-entrypoint.sh
RUN cd /usr/local/bin && chmod 0755 runtime-log.sh random-wait.sh network-runtime.sh patch-entrypoint.sh cf_speedtest \
    && /usr/local/bin/patch-entrypoint.sh /entrypoint.sh \
    && /usr/local/bin/cf_speedtest --help >/dev/null \
    && test -r /usr/share/doc/cf_speedtest/LICENSE.txt \
    && test -r /usr/share/doc/cf_speedtest/UPSTREAM.json \
    && rm -f /usr/local/bin/patch-entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
