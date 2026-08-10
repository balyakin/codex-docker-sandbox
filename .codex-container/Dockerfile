FROM node:22-bookworm-slim@sha256:f32b81066cde10a75dbac96646099533316d94bac4150c55da1636e1f0ffdc46 AS codex

ARG CODEX_VERSION=0.147.0
ARG CODEX_HOST_UID=1000
ARG CODEX_HOST_GID=1000

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl git jq ripgrep \
    && npm install --global "@openai/codex@${CODEX_VERSION}" \
    && npm cache clean --force \
    && rm -rf /var/lib/apt/lists/* \
    && if ! getent group "${CODEX_HOST_GID}" >/dev/null; then groupadd --gid "${CODEX_HOST_GID}" codex-host; fi \
    && usermod --uid "${CODEX_HOST_UID}" --gid "${CODEX_HOST_GID}" node \
    && install -d -o node -g "${CODEX_HOST_GID}" -m 0700 /codex-home

ENV CODEX_HOME=/codex-home

WORKDIR /workspace

USER node

ENTRYPOINT ["codex"]

FROM ubuntu/squid:6.6-24.04_edge@sha256:8a3baed477e2c282ab8aa5edad442f69873246964f225c5c2ae8364b6610963c AS egress

COPY squid.conf /etc/squid/squid.conf

USER proxy
