#!/bin/bash
# MIMO API test script for gh-harness

set -e

# Configuration
API_KEY="REMOVED_API_KEY"
BASE_URL="https://token-plan-cn.xiaomimimo.com/v1"
MODEL="mimo-v2.5-pro"
OUTPUT_DIR="benchmarks/mimo-api"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if curl is available
    if ! command -v curl &> /dev/null; then
        log_error "curl is not installed"
        exit 1
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed"
        exit 1
    fi
    
    log_info "Prerequisites checked successfully"
}

# Create output directory
create_output_dir() {
    log_info "Creating output directory..."
    mkdir -p "$OUTPUT_DIR"
    log_info "Output directory: $OUTPUT_DIR"
}

# Test API connectivity
test_api_connectivity() {
    log_info "Testing API connectivity..."
    
    # Test health endpoint
    RESPONSE=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        "$BASE_URL/models")
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | head -n -1)
    
    if [ "$HTTP_CODE" -eq 200 ]; then
        log_info "✓ API connectivity test passed"
        echo "$BODY" | jq -r '.data[].id' > "$OUTPUT_DIR/models.txt"
        return 0
    else
        log_error "✗ API connectivity test failed (HTTP $HTTP_CODE)"
        echo "$BODY"
        return 1
    fi
}

# Test simple prompt
test_simple_prompt() {
    log_info "Testing simple prompt..."
    
    PROMPT="Hello, how are you?"
    
    START_TIME=$(date +%s%N)
    RESPONSE=$(curl -s -X POST "$BASE_URL/chat/completions" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$MODEL\",
            \"messages\": [{\"role\": \"user\", \"content\": \"$PROMPT\"}],
            \"max_tokens\": 100,
            \"temperature\": 0.7
        }")
    END_TIME=$(date +%s%N)
    
    # Calculate time
    TIME_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    TIME_S=$(echo "scale=2; $TIME_MS / 1000" | bc)
    
    # Extract response
    CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
    TOKENS=$(echo "$RESPONSE" | jq -r '.usage.completion_tokens // 0')
    
    if [ -n "$CONTENT" ]; then
        log_info "✓ Simple prompt test passed"
        log_info "  Response: ${CONTENT:0:100}..."
        log_info "  Tokens: $TOKENS, Time: ${TIME_S}s"
        
        # Calculate token/s
        if [ "$TOKENS" -gt 0 ]; then
            TOKEN_S=$(echo "scale=2; $TOKENS / $TIME_S" | bc)
            log_info "  Token/s: $TOKEN_S"
            echo "$TOKEN_S" > "$OUTPUT_DIR/simple-prompt-token-s.txt"
        fi
        
        echo "$CONTENT" > "$OUTPUT_DIR/simple-prompt-response.txt"
        return 0
    else
        log_error "✗ Simple prompt test failed"
        echo "$RESPONSE"
        return 1
    fi
}

# Test multi-turn conversation
test_multi_turn_conversation() {
    log_info "Testing multi-turn conversation..."
    
    # Conversation messages
    MESSAGES=(
        '{"role": "user", "content": "What is the capital of France?"}'
        '{"role": "assistant", "content": "The capital of France is Paris."}'
        '{"role": "user", "content": "What is the population of Paris?"}'
        '{"role": "assistant", "content": "Paris has a population of about 2.1 million people in the city proper."}'
        '{"role": "user", "content": "What are some famous landmarks in Paris?"}'
    )
    
    # Build messages array
    MESSAGES_JSON="["
    for msg in "${MESSAGES[@]}"; do
        MESSAGES_JSON="$MESSAGES_JSON$msg,"
    done
    MESSAGES_JSON="${MESSAGES_JSON%,}]"
    
    START_TIME=$(date +%s%N)
    RESPONSE=$(curl -s -X POST "$BASE_URL/chat/completions" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$MODEL\",
            \"messages\": $MESSAGES_JSON,
            \"max_tokens\": 200,
            \"temperature\": 0.7
        }")
    END_TIME=$(date +%s%N)
    
    # Calculate time
    TIME_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    TIME_S=$(echo "scale=2; $TIME_MS / 1000" | bc)
    
    # Extract response
    CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
    TOKENS=$(echo "$RESPONSE" | jq -r '.usage.completion_tokens // 0')
    
    if [ -n "$CONTENT" ]; then
        log_info "✓ Multi-turn conversation test passed"
        log_info "  Response: ${CONTENT:0:100}..."
        log_info "  Tokens: $TOKENS, Time: ${TIME_S}s"
        
        # Calculate token/s
        if [ "$TOKENS" -gt 0 ]; then
            TOKEN_S=$(echo "scale=2; $TOKENS / $TIME_S" | bc)
            log_info "  Token/s: $TOKEN_S"
            echo "$TOKEN_S" > "$OUTPUT_DIR/multi-turn-token-s.txt"
        fi
        
        echo "$CONTENT" > "$OUTPUT_DIR/multi-turn-response.txt"
        return 0
    else
        log_error "✗ Multi-turn conversation test failed"
        echo "$RESPONSE"
        return 1
    fi
}

# Test reasoning ability
test_reasoning_ability() {
    log_info "Testing reasoning ability..."
    
    PROMPT="Solve this math problem: If a train travels at 60 km/h for 2 hours, then at 80 km/h for 3 hours, what is the total distance traveled?"
    
    START_TIME=$(date +%s%N)
    RESPONSE=$(curl -s -X POST "$BASE_URL/chat/completions" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$MODEL\",
            \"messages\": [{\"role\": \"user\", \"content\": \"$PROMPT\"}],
            \"max_tokens\": 200,
            \"temperature\": 0.7
        }")
    END_TIME=$(date +%s%N)
    
    # Calculate time
    TIME_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    TIME_S=$(echo "scale=2; $TIME_MS / 1000" | bc)
    
    # Extract response
    CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
    TOKENS=$(echo "$RESPONSE" | jq -r '.usage.completion_tokens // 0')
    
    if [ -n "$CONTENT" ]; then
        log_info "✓ Reasoning ability test passed"
        log_info "  Response: ${CONTENT:0:100}..."
        log_info "  Tokens: $TOKENS, Time: ${TIME_S}s"
        
        # Calculate token/s
        if [ "$TOKENS" -gt 0 ]; then
            TOKEN_S=$(echo "scale=2; $TOKENS / $TIME_S" | bc)
            log_info "  Token/s: $TOKEN_S"
            echo "$TOKEN_S" > "$OUTPUT_DIR/reasoning-token-s.txt"
        fi
        
        echo "$CONTENT" > "$OUTPUT_DIR/reasoning-response.txt"
        
        # Check if answer is correct (distance = 60*2 + 80*3 = 120 + 240 = 360 km)
        if echo "$CONTENT" | grep -q "360"; then
            log_info "  ✓ Correct answer: 360 km"
            echo "correct" > "$OUTPUT_DIR/reasoning-correctness.txt"
        else
            log_warn "  ✗ Answer may be incorrect"
            echo "incorrect" > "$OUTPUT_DIR/reasoning-correctness.txt"
        fi
        
        return 0
    else
        log_error "✗ Reasoning ability test failed"
        echo "$RESPONSE"
        return 1
    fi
}

# Test performance with multiple prompts
test_performance() {
    log_info "Testing performance with multiple prompts..."
    
    PROMPTS=(
        "Explain quantum computing in simple terms."
        "Write a Python function to sort a list."
        "What are the benefits of renewable energy?"
        "Describe the water cycle."
        "How does machine learning work?"
    )
    
    TOTAL_TOKENS=0
    TOTAL_TIME=0
    
    for PROMPT in "${PROMPTS[@]}"; do
        log_info "Testing: ${PROMPT:0:50}..."
        
        START_TIME=$(date +%s%N)
        RESPONSE=$(curl -s -X POST "$BASE_URL/chat/completions" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [{\"role\": \"user\", \"content\": \"$PROMPT\"}],
                \"max_tokens\": 150,
                \"temperature\": 0.7
            }")
        END_TIME=$(date +%s%N)
        
        # Calculate time
        TIME_MS=$(( (END_TIME - START_TIME) / 1000000 ))
        TIME_S=$(echo "scale=2; $TIME_MS / 1000" | bc)
        
        # Extract token count
        TOKENS=$(echo "$RESPONSE" | jq -r '.usage.completion_tokens // 0')
        
        if [ "$TOKENS" -gt 0 ]; then
            TOKEN_S=$(echo "scale=2; $TOKENS / $TIME_S" | bc)
            log_info "  Tokens: $TOKENS, Time: ${TIME_S}s, Token/s: $TOKEN_S"
            
            TOTAL_TOKENS=$((TOTAL_TOKENS + TOKENS))
            TOTAL_TIME=$(echo "scale=2; $TOTAL_TIME + $TIME_S" | bc)
        fi
    done
    
    # Calculate average
    if [ "$TOTAL_TOKENS" -gt 0 ]; then
        AVG_TOKEN_S=$(echo "scale=2; $TOTAL_TOKENS / $TOTAL_TIME" | bc)
        log_info "✓ Average token/s: $AVG_TOKEN_S"
        echo "$AVG_TOKEN_S" > "$OUTPUT_DIR/avg-token-s.txt"
        return 0
    else
        log_error "✗ No tokens generated"
        return 1
    fi
}

# Generate test report
generate_report() {
    log_info "Generating test report..."
    
    REPORT_FILE="$OUTPUT_DIR/mimo-api-test-report-$TIMESTAMP.md"
    
    cat > "$REPORT_FILE" << EOF
# MIMO API Test Report

**Date**: $(date)
**Model**: $MODEL
**API Endpoint**: $BASE_URL

## Test Results

### API Connectivity
- Status: $(test_api_connectivity > /dev/null 2>&1 && echo "✓ Passed" || echo "✗ Failed")

### Simple Prompt Test
- Status: $(test_simple_prompt > /dev/null 2>&1 && echo "✓ Passed" || echo "✗ Failed")
- Token/s: $(cat "$OUTPUT_DIR/simple-prompt-token-s.txt" 2>/dev/null || echo "N/A")
- Response: $(head -c 100 "$OUTPUT_DIR/simple-prompt-response.txt" 2>/dev/null || echo "N/A")...

### Multi-turn Conversation Test
- Status: $(test_multi_turn_conversation > /dev/null 2>&1 && echo "✓ Passed" || echo "✗ Failed")
- Token/s: $(cat "$OUTPUT_DIR/multi-turn-token-s.txt" 2>/dev/null || echo "N/A")
- Response: $(head -c 100 "$OUTPUT_DIR/multi-turn-response.txt" 2>/dev/null || echo "N/A")...

### Reasoning Ability Test
- Status: $(test_reasoning_ability > /dev/null 2>&1 && echo "✓ Passed" || echo "✗ Failed")
- Token/s: $(cat "$OUTPUT_DIR/reasoning-token-s.txt" 2>/dev/null || echo "N/A")
- Correctness: $(cat "$OUTPUT_DIR/reasoning-correctness.txt" 2>/dev/null || echo "N/A")
- Response: $(head -c 100 "$OUTPUT_DIR/reasoning-response.txt" 2>/dev/null || echo "N/A")...

### Performance Test
- Status: $(test_performance > /dev/null 2>&1 && echo "✓ Passed" || echo "✗ Failed")
- Average Token/s: $(cat "$OUTPUT_DIR/avg-token-s.txt" 2>/dev/null || echo "N/A")

## Performance Summary

- **Simple Prompt**: $(cat "$OUTPUT_DIR/simple-prompt-token-s.txt" 2>/dev/null || echo "N/A") token/s
- **Multi-turn**: $(cat "$OUTPUT_DIR/multi-turn-token-s.txt" 2>/dev/null || echo "N/A") token/s
- **Reasoning**: $(cat "$OUTPUT_DIR/reasoning-token-s.txt" 2>/dev/null || echo "N/A") token/s
- **Average**: $(cat "$OUTPUT_DIR/avg-token-s.txt" 2>/dev/null || echo "N/A") token/s

## Correctness Summary

- **Reasoning Correctness**: $(cat "$OUTPUT_DIR/reasoning-correctness.txt" 2>/dev/null || echo "N/A")

## Files

- Test Report: $REPORT_FILE
- Models List: $OUTPUT_DIR/models.txt
- Simple Prompt Response: $OUTPUT_DIR/simple-prompt-response.txt
- Multi-turn Response: $OUTPUT_DIR/multi-turn-response.txt
- Reasoning Response: $OUTPUT_DIR/reasoning-response.txt
- Performance Data: $OUTPUT_DIR/avg-token-s.txt

## Notes

- All tests performed using max 月套餐 API
- Model: mimo-v2.5-pro
- API Endpoint: $BASE_URL
- Tests include connectivity, simple prompts, multi-turn conversation, reasoning, and performance
EOF
    
    log_info "Test report generated: $REPORT_FILE"
}

# Main function
main() {
    log_info "Starting MIMO API test"
    
    check_prerequisites
    create_output_dir
    test_api_connectivity
    test_simple_prompt
    test_multi_turn_conversation
    test_reasoning_ability
    test_performance
    generate_report
    
    log_info "MIMO API test completed successfully"
    log_info "Results saved to: $OUTPUT_DIR"
}

# Run main function
main "$@"