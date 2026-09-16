# GitHub Actions Workflows

This repository uses several automated workflows to ensure code quality and track performance metrics.

## test-languages.yml

This workflow automatically tests all 19 language implementations in the repository to ensure they can be built/compiled without errors.

### Trigger Events

- Push to `main` or `master` branches
- Pull requests to `main` or `master` branches

### Test Jobs

The workflow includes 19 separate jobs, one for each programming language:

#### Compiled Languages (Build Tests)
- **Rust** - Builds with `cargo build --release`
- **Go** - Builds with `go build`
- **C** - Compiles with gcc and libmicrohttpd
- **C++** - Compiles with g++ and Crow framework
- **Crystal** - Builds with `crystal build --release`
- **Zig** - Builds with `zig build-exe`
- **Nim** - Builds with `nim c -d:release`
- **V** - Builds with `v -prod`
- **Fortran** - Compiles with gfortran
- **Ada** - Compiles with gnatmake and AWS libraries

#### JVM Languages (Build Tests)
- **Java** - Builds with Maven
- **Kotlin** - Builds with Gradle

#### .NET Languages (Build Tests)
- **C#** - Builds with `dotnet build`

#### Interpreted Languages (Syntax/Lint Tests)
- **Python** - Syntax check with `python -m py_compile` and basic linting
- **JavaScript** - Syntax check with `node --check`
- **TypeScript** - Compiles with `tsc`
- **Ruby** - Syntax check with `ruby -c`
- **PHP** - Syntax check with `php -l`

#### Assembly (Basic Validation)
- **Assembly** - Validates file exists and attempts NASM compilation

### Purpose

This CI/CD pipeline ensures that:
1. All code changes maintain syntactic correctness
2. Compilation errors are caught early
3. Each language implementation can be successfully built
4. Contributors receive immediate feedback on code quality

### Adding New Languages

When adding a new language implementation:

1. Create a new directory with the language name
2. Add source code and Dockerfile
3. Add a new job to `test-languages.yml` following the pattern of existing jobs
4. Ensure the job includes appropriate setup actions and build/test commands

## benchmark-weekly.yml

This workflow automatically runs comprehensive benchmarks every Monday and commits the updated results directly to `main`.

### Trigger Events

- **Scheduled**: Every Monday at 00:00 UTC (using cron: `0 0 * * 1`)
- **Manual**: Can be triggered manually via `workflow_dispatch` from the Actions tab

### Workflow Steps

1. **Setup Phase**
   - Checkout repository
   - Set up Docker with buildx
   - Install Apache Bench for benchmarking
   - Make benchmark scripts executable

2. **Benchmark Execution**
   - Run `benchmark-all.sh` to test all language implementations
   - Continue even if some benchmarks fail
   - Format results (if format script is available)

3. **Results Processing**
   - Generate timestamp for tracking
   - Create formatted benchmark summary in Markdown
   - Parse results into comparison table
   - Include success/failure status for each language

4. **README Update (only README is committed)**
   - The parsed results are written back into the `Benchmark Results` table of **`README.md`**
   - The routine run commits **only `README.md`** back to `main` — no other repository files are touched

5. **Artifact Upload**
   - Raw results (`benchmark_results.txt`, `benchmark_summary.md`) are uploaded as workflow artifacts
   - 90-day retention period for historical tracking

### Purpose

This automated workflow provides:
- **Regular performance tracking** - Weekly benchmarks for consistent data
- **Trend analysis** - Historical artifacts enable performance trend monitoring
- **Visibility** - Updated README table makes recent results easy to review
- **Regression detection** - Early warning of performance degradations

### Manual Triggering

To run benchmarks manually:
1. Go to the **Actions** tab in GitHub
2. Select **Weekly Benchmark Automation** workflow
3. Click **Run workflow** button
4. Select branch and click **Run workflow**

### Permissions

The workflow requires:
- `contents: write` - To commit the updated `README.md` back to `main`
  (no pull request is created, so `pull-requests` permission is not needed)
