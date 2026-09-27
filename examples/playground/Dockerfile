# Builds the browser playground. Build context must be the repository root:
#   docker build -f examples/playground/Dockerfile .
FROM debian:bookworm-slim AS build
ARG ZIG_VERSION=0.17.0-dev.2131+d08989840
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils git \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://ziglang.org/builds/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt \
    && ln -s /opt/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig
WORKDIR /src
COPY . .
WORKDIR /src/examples/playground
RUN zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall

FROM python:3.12-slim
WORKDIR /app
COPY examples/playground/serve.py .
COPY --from=build /src/examples/playground/zig-out/web ./web
CMD ["sh", "-c", "python3 serve.py --port ${PORT:-8000} --directory web"]
