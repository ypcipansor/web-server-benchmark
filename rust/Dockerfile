FROM rust:1.98-slim as builder
WORKDIR /app
COPY Cargo.toml ./
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
COPY --from=builder /app/target/release/rust-server /usr/local/bin/rust-server
EXPOSE 8080
CMD ["rust-server"]
