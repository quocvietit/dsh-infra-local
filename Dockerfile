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

# Profile plugin (not in the harness lockfile). Bind-mounted /data is wired
# to this tree at container start.
ARG DSH_VISION_TOOLKIT_VERSION=0.1.45
RUN mkdir -p /opt/dsh-plugins \
    && cd /opt/dsh-plugins \
    && printf '%s\n' '{"name":"dsh-plugins","private":true}' > package.json \
    && pnpm add "@anionex/dsh-vision-toolkit@${DSH_VISION_TOOLKIT_VERSION}" \
    && chown -R dsh:dsh /opt/dsh-plugins \
    && test -f /opt/dsh-plugins/node_modules/@anionex/dsh-vision-toolkit/package.json

RUN pip3 install --break-system-packages --no-cache-dir pillow numpy vtracer

# Entrypoint + runtime lib patches (web token, host-open). Harness source
# in /opt/dsh is the baked copy; host overlay via /source/dsh is optional.
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint.sh
COPY patch-runtime.mjs /usr/local/bin/dsh-patch-runtime.mjs
COPY ensure-vision-toolkit.mjs /usr/local/bin/dsh-ensure-vision-toolkit.mjs
COPY hide-vision-updates.mjs /usr/local/bin/dsh-hide-vision-updates.mjs

RUN chmod +x /usr/local/bin/dsh-entrypoint.sh

# Entrypoint cần chạy root để chmod/chown credential.
# Sau đó script sẽ tự chuyển xuống user node.
USER root

WORKDIR /workspace

EXPOSE 3080

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/dsh-entrypoint.sh"]
CMD ["pnpm", "--dir", "/opt/dsh", "dsh", "web"]