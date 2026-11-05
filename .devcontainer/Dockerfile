FROM node:26-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git curl ca-certificates procps gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*

# k6 load tester (Go, the .NET SDK and Rust come from devcontainer features)
ARG K6_VERSION=2.3.0
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/grafana/k6/releases/download/v${K6_VERSION}/k6-v${K6_VERSION}-linux-${arch}.tar.gz" \
       | tar -xz -C /usr/local/bin --strip-components=1 "k6-v${K6_VERSION}-linux-${arch}/k6"

# oha: a load generator written in Rust, for the heavy "oha" scenario
ARG OHA_VERSION=1.16.0
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL -o /usr/local/bin/oha "https://github.com/hatoo/oha/releases/download/v${OHA_VERSION}/oha-linux-${arch}" \
    && chmod +x /usr/local/bin/oha

# uv manages Python and the Python server's dependencies. It downloads the
# Python version the project asks for (3.15) on first use.
ARG UV_VERSION=0.13.7
RUN curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-$(uname -m)-unknown-linux-gnu.tar.gz" \
       | tar -xz -C /usr/local/bin --strip-components=1

RUN npm install -g @anthropic-ai/claude-code
