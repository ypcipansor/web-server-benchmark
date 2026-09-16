#!/bin/bash
set -e

# All 19 language implementations, matching benchmark-all.sh so the stress
# suite covers the same set as the standard benchmark.
LANGUAGES=(
    "c"
    "crystal"
    "rust"
    "go"
    "zig"
    "cpp"
    "php"
    "v"
    "kotlin"
    "java"
    "python"
    "javascript"
    "ruby"
    "typescript"
    "ada"
    "assembly"
    "csharp"
    "fortran"
    "nim"
)

echo "Starting Stress Tests..."

echo "| Language | Requests/sec | Avg Latency (ms) | Peak CPU (%) | Peak Memory |" > stress_summary.md
echo "|----------|--------------|------------------|--------------|-------------|" >> stress_summary.md

for LANG in "${LANGUAGES[@]}"; do
    ./benchmark-stress.sh $LANG 10

    # Parse results
    AB_FILE="stress_test_results/${LANG}_ab.txt"
    STATS_FILE="stress_test_results/${LANG}_stats.csv"

    RPS=$(grep "Requests per second:" $AB_FILE | awk '{print $4}')
    LATENCY=$(grep "Time per request:" $AB_FILE | grep "mean" | head -1 | awk '{print $4}')

    # Simple peak extraction
    PEAK_CPU=$(awk -F',' 'NR>1 {print $2}' $STATS_FILE | sort -rn | head -1)
    # Peak Mem parsing (taking the first part before space)
    PEAK_MEM=$(awk -F',' 'NR>1 {print $3}' $STATS_FILE | awk '{print $1}' | sort -rh | head -1)

    echo "| **${LANG^}** | $RPS | $LATENCY | $PEAK_CPU | $PEAK_MEM |" >> stress_summary.md
    echo "Finished $LANG"
done

cat stress_summary.md

echo "Generating Report..."
python3 frontend/generate_report.py
