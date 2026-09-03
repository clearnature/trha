#!/bin/bash
# Negative test: invalid input

set -e

TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
SCORE=0
TOTAL=0

echo "=== Negative Test: Invalid Input ==="

# Test 1: Empty prompt
echo "Test 1: Empty prompt"
TOTAL=$((TOTAL + 1))
RESPONSE=$(curl -s -X POST http://localhost:8080/completion \
    -H "Content-Type: application/json" \
    -d '{
        "prompt": "",
        "n_predict": 50,
        "temperature": 0.7
    }')

if echo "$RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
    echo "  ✓ Empty prompt handled correctly"
    SCORE=$((SCORE + 1))
else
    echo "  ✗ Empty prompt not handled"
fi

# Test 2: Invalid JSON
echo "Test 2: Invalid JSON"
TOTAL=$((TOTAL + 1))
RESPONSE=$(curl -s -X POST http://localhost:8080/completion \
    -H "Content-Type: application/json" \
    -d 'invalid json')

if echo "$RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
    echo "  ✓ Invalid JSON handled correctly"
    SCORE=$((SCORE + 1))
else
    echo "  ✗ Invalid JSON not handled"
fi

# Test 3: Missing required fields
echo "Test 3: Missing required fields"
TOTAL=$((TOTAL + 1))
RESPONSE=$(curl -s -X POST http://localhost:8080/completion \
    -H "Content-Type: application/json" \
    -d '{}')

if echo "$RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
    echo "  ✓ Missing fields handled correctly"
    SCORE=$((SCORE + 1))
else
    echo "  ✗ Missing fields not handled"
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