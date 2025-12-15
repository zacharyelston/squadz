FROM rust:1.75 as builder

WORKDIR /app

# Copy workspace files
COPY Cargo.toml Cargo.lock ./
COPY backend ./backend

# Build release
RUN cargo build --release --bin squadz-server

# Runtime image
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/squadz-server /usr/local/bin/

EXPOSE 8080

CMD ["squadz-server"]
