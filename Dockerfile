# =========================
# Stage 1: Build DSH
# =========================
FROM node:24-bookworm AS builder

RUN apt-get update \
    && apt-get install -y git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g pnpm@11.7.0 \
    && pnpm --version

WORKDIR /build/dsh

ARG DSH_COMMIT_HASH=0000000
ENV DSH_CLIENT_COMMIT_HASH=${DSH_COMMIT_HASH}

COPY deepseek-harness/ /build/dsh/

RUN pnpm install --frozen-lockfile
RUN pnpm run build
RUN test -f pnpm-lock.yaml


# =========================
# Stage 2: Runtime
# =========================
FROM node:24-bookworm

RUN apt-get update \
    && apt-get install -y \
        git \
        curl \
        ca-certificates \
        tini \
        socat \
        python3 \
        python3-venv \
        python3-pip \
        python3-dev \
        chromium \
        fonts-liberation \
        fonts-noto-core \
        libnss3 \
        libatk-bridge2.0-0 \
        libdrm2 \
        libxkbcommon0 \
        libxcomposite1 \
        libxdamage1 \
        libxrandr2 \
        libgbm1 \
        libasound2 \
        libpangocairo-1.0-0 \
        libgtk-3-0 \
    && rm -rf /var/lib/apt/lists/* \
    && test -x /usr/bin/chromium

RUN npm install -g pnpm@11.7.0 \
    && pnpm --version

ENV HOME=/home/dsh
ENV DSH_HOME=/data

# Tắt telemetry
ENV DSH_TELEMETRY_DISABLED=1
ENV DSH_TELEMETRY_MODE=DISABLED

RUN useradd \
    --create-home \
    --shell /bin/bash \
    dsh

RUN mkdir -p \
    /opt/dsh \
    /data \
    /workspace \
    /source/dsh \
    && chown -R dsh:dsh \
        /opt/dsh \
        /data \
        /workspace \
        /home/dsh

# Copy bản Harness đã install + build sẵn
COPY --from=builder \
    --chown=dsh:dsh \
    /build/dsh \
    /opt/dsh

# Entrypoint + runtime lib patches (web token, host-open). Harness source
# in /opt/dsh is the baked copy; host overlay via /source/dsh is optional.
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint.sh
COPY patch-runtime.mjs /usr/local/bin/dsh-patch-runtime.mjs

RUN chmod +x /usr/local/bin/dsh-entrypoint.sh

# Entrypoint cần chạy root để chmod/chown credential.
# Sau đó script sẽ tự chuyển xuống user node.
USER root

WORKDIR /workspace

EXPOSE 3080

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/dsh-entrypoint.sh"]
CMD ["pnpm", "--dir", "/opt/dsh", "dsh", "web"]