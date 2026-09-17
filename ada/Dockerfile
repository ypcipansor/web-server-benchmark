FROM debian:bookworm-slim as builder
RUN apt-get update && apt-get install -y gnat gprbuild && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY server.adb server.gpr ./
# Compile against the GNAT runtime only (raw C socket interop), no external AWS dependency
RUN gprbuild -P server.gpr

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y libgnat-12 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/server /server
WORKDIR /
EXPOSE 8080
CMD ["/server"]
