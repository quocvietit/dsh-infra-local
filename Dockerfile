# =========================
# Stage 1: Build DSH
# =========================
FROM node:26-bookworm AS builder

# build-essential + musl-tools: required to compile native C binaries
#   - flock      (Node-API addon, glibc + musl variants)
#   - landlock-run (static musl executable)
# Node headers are available at /usr/local/include/node in node:26-bookworm
RUN apt-get update \
    && apt-get install -y \
        git \
        ca-certificates \
        build-essential \
        musl-tools \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g pnpm@11.28.5 \
    && pnpm --version

WORKDIR /build/dsh

ARG DSH_COMMIT_HASH=0000000
ENV DSH_CLIENT_COMMIT_HASH=${DSH_COMMIT_HASH}

COPY deepseek-harness/ /build/dsh/

RUN pnpm install --frozen-lockfile
RUN pnpm run build
# Disable TTY-dependent purge prompt and dep verification for non-interactive
# container runtime (entrypoint runs pnpm without a TTY).
RUN pnpm config set confirmModulesPurge false --location project \
    && pnpm config set verifyDepsBeforeRun false --location project

# Xóa các thư mục chỉ cần lúc compile/type-check, không cần trong runtime image.
# - desktop apps: tsconfig.host.json reference, nhưng web mode không dùng
# - snapshots/website/scripts: scripts/*.spec.ts reference chúng trong host aggregate check
# Làm ở đây (builder stage) nên COPY --from=builder sang runtime sẽ không copy chúng.
RUN rm -rf \
    apps/desktop \
    apps/desktop-host \
    apps/plugin-market-generator \
    snapshots \
    docs \
    examples

# =========================
# Stage 1.1: JDK 17
# =========================
FROM eclipse-temurin:17-jdk AS jdk17


# =========================
# Stage 1.2: JDK 21
# =========================
FROM eclipse-temurin:21-jdk AS jdk21


# =========================
# Stage 1.3: Maven
# Dùng image chính thức thay vì curl — không cần network trong RUN,
# tránh apt kéo thêm openjdk-17-jdk-headless (~400 MB) thừa.
# =========================
FROM maven:3.9-eclipse-temurin-21 AS maven-dist


# =========================
# Stage 2: Runtime
# =========================
FROM node:26-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        curl \
        ca-certificates \
        tini \
        socat \
        python3 \
        python3-venv \
        python3-pip \
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
        libpangocairo-1.0-0 \
        libgtk-3-0 \
    && rm -rf /var/lib/apt/lists/*

# Copy Maven binary từ official image — không kéo openjdk thừa qua apt.
COPY --from=maven-dist /usr/share/maven /opt/maven
RUN ln -s /opt/maven/bin/mvn /usr/local/bin/mvn \
    && test -x /usr/bin/chromium \
    && test -x /usr/local/bin/mvn

# =========================
# Java 17 + Java 21
# =========================

COPY --from=jdk17 /opt/java/openjdk /opt/java/jdk17
COPY --from=jdk21 /opt/java/openjdk /opt/java/jdk21

# Java 21 default
ENV JAVA17_HOME=/opt/java/jdk17
ENV JAVA21_HOME=/opt/java/jdk21
ENV JAVA_HOME=/opt/java/jdk21

ENV PATH="${JAVA_HOME}/bin:${PATH}"

# =========================
# Maven
# =========================

# Maven config directory: /home/dsh/.m2/settings.xml + /home/dsh/.m2/repository
ENV MAVEN_CONFIG=/home/dsh/.m2
ENV MAVEN_HOME=/opt/maven

# =========================
# Node / PNPM / CodeGraph
# =========================
RUN npm install -g pnpm@11.28.5 @colbymchenry/codegraph \
    && pnpm --version \
    && codegraph --version \
    && npm cache clean --force

ENV HOME=/home/dsh
ENV DSH_HOME=/data

# Disable telemetry
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

# Copy the pre-installed + pre-built harness
COPY --from=builder \
    --chown=dsh:dsh \
    /build/dsh \
    /opt/dsh

# =========================
# Java helper commands
# =========================

# Usage:
#   use-java17 mvn clean test
#   use-java21 mvn clean test
#
# No shell sourcing needed -- suitable for AI Agents.

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

# Entrypoint + runtime lib patches (web token, host-open).
# Harness source in /opt/dsh is the baked copy; host overlay via /source/dsh is optional.
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

USER root

WORKDIR /workspace

EXPOSE 3080

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/dsh-entrypoint.sh"]
CMD ["pnpm", "--dir", "/opt/dsh", "dsh", "web"]
