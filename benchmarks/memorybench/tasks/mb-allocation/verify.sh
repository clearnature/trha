#!/bin/bash
# Memory allocation benchmark

set -e

TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
SCORE=0
TOTAL=0

echo "=== Memory Allocation Benchmark ==="

# Test 1: Basic allocation
echo "Test 1: Basic allocation"
TOTAL=$((TOTAL + 1))
START_MEM=$(ps -o rss= -p $$)
for i in {1..1000}; do
    curl -s http://localhost:8080/health > /dev/null
done
END_MEM=$(ps -o rss= -p $$)
MEM_DIFF=$((END_MEM - START_MEM))

if [ "$MEM_DIFF" -lt 10000 ]; then
    echo "  ✓ Basic allocation passed (memory increase: ${MEM_DIFF}KB)"
    SCORE=$((SCORE + 1))
else
    echo "  ✗ Basic allocation failed (memory increase: ${MEM_DIFF}KB)"
fi

# Test 2: Large request
echo "Test 2: Large request"
TOTAL=$((TOTAL + 1))
START_MEM=$(ps -o rss= -p $$)
PROMPT=$(printf 'A%.0s' {1..10000})
curl -s -X POST http://localhost:8080/completion \
    -H "Content-Type: application/json" \
    -d "{
        \"prompt\": \"$PROMPT\",
        \"n_predict\": 100,
        \"temperature\": 0.7
    }" > /dev/null
END_MEM=$(ps -o rss= -p $$)
MEM_DIFF=$((END_MEM - START_MEM))

if [ "$MEM_DIFF" -lt 50000 ]; then
    echo "  ✓ Large request passed (memory increase: ${MEM_DIFF}KB)"
    SCORE=$((SCORE + 1))
else
    echo "  ✗ Large request failed (memory increase: ${MEM_DIFF}KB)"
fi

# Calculate score
echo ""
echo "=== Results ==="
echo "Score: $SCORE/$TOTAL"
echo "Pass rate: $(echo "scale=2; $SCORE * 100 / $TOTAL" | bc)%"

if [ "$SCORE" -eq "$TOTAL" ]; then
    echo "Status: PASSED"
    exit 0
else
    echo "Status: FAILED"
    exit 1
fi