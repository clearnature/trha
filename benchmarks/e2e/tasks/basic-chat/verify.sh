#!/bin/bash
# Basic chat test verification

set -e

TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
SCORE=0
TOTAL=0

echo "=== Basic Chat Test ==="

# Test 1: API connectivity
echo "Test 1: API connectivity"
TOTAL=$((TOTAL + 1))
if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health | grep -q "200"; then
    echo "  ✓ API connectivity passed"
    SCORE=$((SCORE + 1))
else
    echo "  ✗ API connectivity failed"
fi

# Test 2: Simple prompt
echo "Test 2: Simple prompt"
TOTAL=$((TOTAL + 1))
RESPONSE=$(curl -s -X POST http://localhost:8080/completion \
    -H "Content-Type: application/json" \
    -d '{
        "prompt": "Hello, how are you?",
        "n_predict": 50,
        "temperature": 0.7
    }')

if echo "$RESPONSE" | jq -e '.content' > /dev/null 2>&1; then
    echo "  ✓ Simple prompt passed"
    SCORE=$((SCORE + 1))
else
    echo "  ✗ Simple prompt failed"
fi

# Test 3: Response time
echo "Test 3: Response time"
TOTAL=$((TOTAL + 1))
START_TIME=$(date +%s%N)
curl -s -X POST http://localhost:8080/completion \
    -H "Content-Type: application/json" \
    -d '{
        "prompt": "What is 2+2?",
        "n_predict": 20,
        "temperature": 0.7
    }' > /dev/null
END_TIME=$(date +%s%N)
DURATION=$(( (END_TIME - START_TIME) / 1000000 ))

if [ "$DURATION" -lt 5000 ]; then
    echo "  ✓ Response time passed ($DURATION ms)"
    SCORE=$((SCORE + 1))
else
    echo "  ✗ Response time failed ($DURATION ms)"
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