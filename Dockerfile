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
        socat \
        python3 \
        python3-venv \
        python3-pip \
    && rm -rf /var/lib/apt/lists/*

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
    
# Copy entrypoint dùng để chuẩn bị credentials
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint.sh

RUN chmod +x /usr/local/bin/dsh-entrypoint.sh

# Entrypoint cần chạy root để chmod/chown credential.
# Sau đó script sẽ tự chuyển xuống user node.
USER root

WORKDIR /workspace

EXPOSE 3080

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/dsh-entrypoint.sh"]
CMD ["pnpm", "--dir", "/opt/dsh", "dsh", "web"]