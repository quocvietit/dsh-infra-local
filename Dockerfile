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
# Stage 1.1: JDK 17
# =========================
FROM eclipse-temurin:17-jdk AS jdk17


# =========================
# Stage 1.2: JDK 21
# =========================
FROM eclipse-temurin:21-jdk AS jdk21


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
        maven \
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
    && test -x /usr/bin/chromium \
    && test -x /usr/bin/mvn

# =========================
# Java 17 + Java 21
# =========================

COPY --from=jdk17 /opt/java/openjdk /opt/java/jdk17
COPY --from=jdk21 /opt/java/openjdk /opt/java/jdk21

# Java 21 mặc định
ENV JAVA17_HOME=/opt/java/jdk17
ENV JAVA21_HOME=/opt/java/jdk21
ENV JAVA_HOME=/opt/java/jdk21

ENV PATH="${JAVA_HOME}/bin:${PATH}"

# =========================
# Maven
# =========================

# Maven mặc định sử dụng:
# /home/dsh/.m2/settings.xml
# /home/dsh/.m2/repository
ENV MAVEN_CONFIG=/home/dsh/.m2

# =========================
# Node / PNPM
# =========================
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
    /opt/java \
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

# =========================
# Java helper commands
# =========================

# Cho phép:
#
#   use-java17 mvn clean test
#   use-java21 mvn clean test
#
# Không cần source shell nên rất phù hợp cho AI Agent.

RUN printf '%s\n' \
    '#!/bin/bash' \
    'export JAVA_HOME=/opt/java/jdk17' \
    'export PATH="$JAVA_HOME/bin:$PATH"' \
    'exec "$@"' \
    > /usr/local/bin/use-java17 \
    && chmod +x /usr/local/bin/use-java17 \
    \
    && printf '%s\n' \
    '#!/bin/bash' \
    'export JAVA_HOME=/opt/java/jdk21' \
    'export PATH="$JAVA_HOME/bin:$PATH"' \
    'exec "$@"' \
    > /usr/local/bin/use-java21 \
    && chmod +x /usr/local/bin/use-java21


# =========================
# Java / Maven environment check
# =========================

RUN printf '%s\n' \
    '#!/bin/bash' \
    'set -e' \
    'echo "========================================"' \
    'echo "Default Java"' \
    'echo "========================================"' \
    'java -version' \
    'echo' \
    'echo "JAVA_HOME=$JAVA_HOME"' \
    'echo' \
    'echo "========================================"' \
    'echo "Java 17"' \
    'echo "========================================"' \
    '/opt/java/jdk17/bin/java -version' \
    'echo' \
    'echo "========================================"' \
    'echo "Java 21"' \
    'echo "========================================"' \
    '/opt/java/jdk21/bin/java -version' \
    'echo' \
    'echo "========================================"' \
    'echo "Maven"' \
    'echo "========================================"' \
    'mvn -version' \
    'echo' \
    'echo "MAVEN_CONFIG=$MAVEN_CONFIG"' \
    'echo' \
    'echo "========================================"' \
    'echo ".m2"' \
    'echo "========================================"' \
    'ls -la /home/dsh/.m2 || true' \
    > /usr/local/bin/java-env \
    && chmod +x /usr/local/bin/java-env

# Entrypoint + runtime lib patches (web token, host-open). Harness source
# in /opt/dsh is the baked copy; host overlay via /source/dsh is optional.
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint.sh
COPY patch-runtime.mjs /usr/local/bin/dsh-patch-runtime.mjs

RUN chmod +x /usr/local/bin/dsh-entrypoint.sh

# =========================
# Verify Java / Maven
# =========================

RUN /opt/java/jdk17/bin/java -version \
    && /opt/java/jdk21/bin/java -version \
    && java -version \
    && javac -version \
    && mvn -version

# Entrypoint cần chạy root để chmod/chown credential.
# Sau đó script sẽ tự chuyển xuống user node.
USER root

WORKDIR /workspace

EXPOSE 3080

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/dsh-entrypoint.sh"]
CMD ["pnpm", "--dir", "/opt/dsh", "dsh", "web"]