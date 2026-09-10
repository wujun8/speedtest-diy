FROM --platform=linux/amd64 zephir284/speedtest@sha256:5b2431c251a10ed6dc6600bba6dcb3ca0b5682b00700c17f1a970478e55a7334

USER root
COPY random-wait.sh /usr/local/bin/random-wait.sh
COPY patch-entrypoint.sh /usr/local/bin/patch-entrypoint.sh
RUN chmod 0755 /usr/local/bin/random-wait.sh /usr/local/bin/patch-entrypoint.sh \
    && /usr/local/bin/patch-entrypoint.sh /entrypoint.sh \
    && rm -f /usr/local/bin/patch-entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
