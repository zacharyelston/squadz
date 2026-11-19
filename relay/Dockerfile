# Not yet built or run: see docs/RELAY.md.
FROM rust:1 AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src src
RUN cargo build --release --locked

FROM debian:stable-slim
RUN useradd --system --home /data relay && mkdir /data && chown relay /data
COPY --from=build /src/target/release/squadz-relay /usr/local/bin/squadz-relay
USER relay
ENV RELAY_LISTEN=0.0.0.0:8443 RELAY_DB=/data/relay.db
VOLUME /data
EXPOSE 8443
CMD ["squadz-relay"]
