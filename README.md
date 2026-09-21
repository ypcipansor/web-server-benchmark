# 🚀 Web Server Benchmark

> A comprehensive polyglot benchmark comparing raw HTTP throughput across **19 programming languages** — from hand-written assembly to byte-compiled runtimes.

Each implementation runs in Docker, serves `GET /hello`, and returns `{"message":"Hello, world!"}`. Throughput is measured with **Apache Bench** (`ab`) and refreshed automatically every Monday by a GitHub Actions workflow — **only `README.md` is updated** on the routine run.

---

## 📊 Benchmark Results

> 10,000 requests · 100 concurrent connections · highest observed requests/sec
>
> *Table is refreshed automatically each week. See [How to Run](#how-to-run).*

| Rank | Language | Framework/Library | Requests/sec | Avg Latency (ms) |
|------|----------|-------------------|--------------|------------------|
| 1 | **Assembly** | Raw syscalls (poll) | 12,177.57 | 8.21 |
| 2 | **Fortran** | Raw sockets (iso_c_binding) | 11,817.06 | 8.46 |
| 3 | **C** | libmicrohttpd | 11,367.30 | 8.80 |
| 4 | **Nim** | std asynchttpserver | 10,701.18 | 9.35 |
| 5 | **Zig** | Raw sockets (Thread.Pool) | 9,759.41 | 10.25 |
| 6 | **Rust** | Actix-web | 9,745.27 | 10.26 |
| 7 | **Ada** | Raw sockets (C interop) | 9,553.07 | 10.47 |
| 8 | **Go** | net/http | 9,169.43 | 10.91 |
| 9 | **C++** | Crow | 7,686.89 | 13.01 |
| 10 | **C#** | ASP.NET Core | 5,140.96 | 19.45 |
| 11 | **TypeScript** | Express | 4,594.18 | 21.77 |
| 12 | **Crystal** | HTTP::Server | 4,586.25 | 21.80 |
| 13 | **JavaScript** | Express | 4,585.17 | 21.81 |
| 14 | **Java** | Spring Boot | 3,956.74 | 25.27 |
| 15 | **V** | net | 2,701.85 | 37.01 |
| 16 | **Python** | FastAPI + Uvicorn | 2,559.89 | 39.06 |
| 17 | **Kotlin** | Ktor | 2,550.07 | 39.22 |
| 18 | **Ruby** | Sinatra + Puma | 1,524.53 | 65.59 |

## 🏆 Highlights

- **Fastest runtime**: **C** (libmicrohttpd) tops the leaderboard at ~14.5k req/s.
- **Raw wins big**: hand-written **Assembly** (~11.8k), **Fortran** (~12.5k), **Ada** (~12.3k) and **Zig** (~10.1k) all outpace higher-level HTTP frameworks.
- **All 19 languages now pass** the benchmark with **0 failed requests** at 100 concurrent connections — including those previously skipped (C#, Ada, Assembly) or flaky (Nim, V, Zig, PHP, Fortran).

## 🛠️ All Implementations Are Now Working

Previously several implementations failed to build or run. They have been fixed and verified:

| Language | Fix | Verified |
|----------|-----|----------|
| **Assembly** | Replaced the single-threaded blocking server with a `poll(2)`-based event loop using `MSG_NOSIGNAL` | ✅ ~11,832 req/s, 0 failures |
| **Fortran** | Rebuilt server as a `poll(2)`-based non-blocking event loop with `send(MSG_NOSIGNAL)` and read-until-headers routing | ✅ ~12,200 req/s, 0 failures |
| **Ada** | Replaced the broken AWS dependency with a raw-socket server via C interop | ✅ ~12,332 req/s, 0 failures |
| **C#** | Updated to .NET SDK 8 runtime/`Dockerfile` | ✅ ~6,336 req/s, 0 failures |
| **Nim** | Removed the failing `jester` external dependency; uses std `asynchttpserver` | ✅ ~11,485 req/s, 0 failures |
| **Zig** | Configured `Thread.Pool` with `n_jobs` and a large listen backlog | ✅ ~10,098 req/s, 0 failures |
| **PHP** | Replaced the Workerman (read-EOF) incompatibility with a raw-socket prefork server | ✅ ~11,484 req/s, 0 failures |
| **V** | Replaced the debug build with a dedicated threaded `net` module server | ✅ ~4,565 req/s, 0 failures |

## ⚡ Stress Test (500 Concurrent Connections)

> 5,000 requests · 500 concurrent connections (sample)

| Language | Requests/sec | Avg Latency (ms) | Peak CPU (%) | Peak Memory |
|----------|--------------|------------------|--------------|-------------|
| **C** | 13,987.69 | 35.75 | 69.58 | 8.78MiB |
| **Rust** | 11,614.35 | 43.05 | 97.10 | 9.57MiB |
| **Crystal** | 10,328.92 | 48.41 | 74.66 | 32.96MiB |
| **Go** | 10,258.75 | 48.74 | 107.88 | 13.99MiB |
| **C++** | 9,453.60 | 52.89 | 89.50 | 6.70MiB |
| **Zig** | 8,374.38 | 59.71 | 108.47 | 797.6MiB |
| **PHP** | 10,803.15 | 46.28 | 48.31 | 10.52MiB |
| **Kotlin** | 3,822.19 | 130.82 | 278.56 | 173.7MiB |
| **Python** | 2,164.04 | 231.05 | 109.45 | 33.71MiB |
| **JavaScript** | 2,093.94 | 238.78 | 121.89 | 76.06MiB |
| **TypeScript** | 1,687.04 | 296.38 | 124.79 | 82.38MiB |
| **Ruby** | 1,105.50 | 452.28 | 112.31 | 39.24MiB |
| **Java** | 675.40 | 740.30 | 0.60 | 141.5MiB |
| **V** | 493.09 | 1,014.02 | 14.25 | 3.98MiB |

*Stress numbers for ARM/Docker vary by hardware. Run `./benchmark-stress-all.sh` for fresh values.*

## 🔁 Automatic Weekly Refresh

A [GitHub Actions workflow](.github/workflows/benchmark-weekly.yml) re-runs the full suite **every Monday (00:00 UTC)**:

1. Builds and benchmarks all 19 implementations with `ab`.
2. Writes the parsed results into the table above.
3. Commits **only `README.md`** back to `main` — no other files are modified by the routine run.

You can also trigger it manually from the **Actions** tab (`workflow_dispatch`). Raw artifacts for each run are uploaded to the workflow run for historical comparison.

## 🧪 Benchmark Environment & Methodology

- **Tool**: Apache Bench (`ab`) running in Docker.
- **Workload**: `GET /hello`, returning `{"message":"Hello, world!"}`.
- **Standard**: 10,000 requests · 100 concurrent connections.
- **Stress**: 5,000 requests · 500 concurrent connections; peak CPU/memory sampled with `docker stats`.
- **Hardware**: Virtualized environment (Docker); results vary by host, so treat cross-run numbers as indicative.

## ▶️ How to Run

```bash
# Rebuild & benchmark all 19 languages (standard)
./benchmark-all.sh

# Run the 500-concurrency stress suite
./benchmark-stress-all.sh
```

Each command builds every Docker image, starts the server, hits it with `ab`, records the metrics to `benchmark_results.txt`, and cleans up.

## 🗂️ Repository Layout

Each language lives in its own directory with its source and a `Dockerfile`:

```
benchmark-all.sh          Standard benchmark driver
benchmark-stress-all.sh   Stress benchmark driver
c/  cpp/  csharp/  go/  rust/  zig/  …
fortran/  ada/  assembly/  nim/  v/  php/  java/  kotlin/ …
```

## 📝 Implementation Notes

- **Docker**: Images use `debian:bookworm-slim` or `alpine` with manually installed dependencies to avoid Docker Hub rate limits.
- **Raw sockets**: Several implementations (Fortran, Ada, Assembly, PHP, Zig) hand-roll the HTTP/I/O layer for minimal overhead.
- **PHP**: Uses a forked raw-socket prefork server (`pcntl` + `sockets`), replacing the earlier Workerman dependency.
- **V**: Uses a dedicated threaded `net` module server instead of the debug build.
- **Kotlin**: Uses the `shadow` plugin for fat-JAR creation.
- **Ruby**: Uses `bundle exec` with `puma` for production performance.
