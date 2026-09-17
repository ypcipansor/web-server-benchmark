FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y nim && rm -rf /var/lib/apt/lists/*
WORKDIR /app
# server.nim uses only the Nim standard library (std/asynchttpserver);
# no external nimble packages are required.
COPY server.nim ./
RUN nim c -d:release --opt:speed server.nim

EXPOSE 8080
CMD ["./server"]
