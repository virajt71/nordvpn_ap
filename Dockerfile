# Multi-stage build
FROM rust:alpine AS builder

RUN apk add --no-cache musl-dev

WORKDIR /usr/src/ap-manager

# Cache dependencies
COPY Cargo.toml ./
RUN mkdir src && echo "fn main() {}" > src/main.rs
RUN cargo build --release
RUN rm -rf src

# Copy real sources and compile
COPY src ./src
RUN touch src/main.rs && cargo build --release

# Final runtime image
FROM alpine:3.20

# Install runtime dependencies: docker client, compose plugin, wifi & routing tools
RUN apk add --no-cache \
    docker-cli \
    docker-cli-compose \
    iw \
    iproute2 \
    iptables \
    curl \
    udev \
    libgcc

WORKDIR /app

# Copy the compiled binary to /usr/local/bin so it's not hidden by volume mounts
COPY --from=builder /usr/src/ap-manager/target/release/ap-manager /usr/local/bin/ap-manager

EXPOSE 42918

# ponytail: HEALTHCHECK uses curl against health/static endpoint; upgrade path: dedicated authenticated /healthz endpoint if auth added
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:42918/ || exit 1

ENTRYPOINT ["/usr/local/bin/ap-manager"]

