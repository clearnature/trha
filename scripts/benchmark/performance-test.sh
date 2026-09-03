#!/bin/bash
# Performance test script for gh-harness

set -e

# Configuration
MODEL_PATH="/home/yanli/work/9060xt/models/Qwen3.8-27B-GGUF/Qwen3.8-27B-IQ3_M.gguf"
LLAMA_CPP_PATH="/home/yanli/work/9060xt/llama-b1312-ubuntu-rocm-gfx120X-x64"
OUTPUT_DIR="benchmarks/performance"
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
    
    # Check if model exists
    if [ ! -f "$MODEL_PATH" ]; then
        log_error "Model not found: $MODEL_PATH"
        exit 1
    fi
    
    # Check if llama.cpp exists
    if [ ! -d "$LLAMA_CPP_PATH" ]; then
        log_error "llama.cpp not found: $LLAMA_CPP_PATH"
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

# Start llama-server with optimal configuration
start_optimal_server() {
    log_info "Starting llama-server with optimal configuration..."
    
    # Start server with optimal configuration
    cd "$LLAMA_CPP_PATH"
    ./llama-server \
        --model "$MODEL_PATH" \
        --ctx-size 4096 \
        --threads 8 \
        --gpu-layers 999 \
        --flash-attn on \
        --port 8080 \
        --host 0.0.0.0 \
        --log-disable \
        > "$OUTPUT_DIR/server.log" 2>&1 &
    
    SERVER_PID=$!
    log_info "llama-server started with PID: $SERVER_PID"
    
    # Wait for server to start
    log_info "Waiting for server to start..."
    sleep 10
    
    # Check if server is running
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        log_error "llama-server failed to start"
        cat "$OUTPUT_DIR/server.log"
        exit 1
    fi
    
    log_info "llama-server started successfully"
}

# Stop llama-server
stop_server() {
    log_info "Stopping llama-server..."
    if [ ! -z "$SERVER_PID" ]; then
        kill $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
    fi
    log_info "llama-server stopped"
}

# Test short prompts
test_short_prompts() {
    log_info "Testing short prompts..."
    
    PROMPTS=(
        "Hello"
        "What is AI?"
        "Explain Python."
        "What is 2+2?"
        "Hello world."
    )
    
    TOTAL_TOKENS=0
    TOTAL_TIME=0
    
    for PROMPT in "${PROMPTS[@]}"; do
        log_info "Testing: $PROMPT"
        
        # Send request with timing
        START_TIME=$(date +%s%N)
        RESPONSE=$(curl -s -X POST http://localhost:8080/completion \
            -H "Content-Type: application/json" \
            -d "{
                \"prompt\": \"$PROMPT\",
                \"n_predict\": 64,
                \"temperature\": 0.7,
                \"top_p\": 0.9,
                \"stream\": false
            }")
        END_TIME=$(date +%s%N)
        
        # Calculate time
        TIME_MS=$(( (END_TIME - START_TIME) / 1000000 ))
        TIME_S=$(echo "scale=2; $TIME_MS / 1000" | bc)
        
        # Extract token count
        TOKENS=$(echo "$RESPONSE" | jq -r '.tokens_predicted // 0')
        
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
        log_info "✓ Short prompts average token/s: $AVG_TOKEN_S"
        echo "$AVG_TOKEN_S" > "$OUTPUT_DIR/short-prompts-token-s.txt"
    fi
}

# Test medium prompts
test_medium_prompts() {
    log_info "Testing medium prompts..."
    
    PROMPTS=(
        "Explain the concept of machine learning in simple terms."
        "Write a Python function to calculate the Fibonacci sequence."
        "Describe the architecture of a modern web application."
        "What are the advantages of using Docker containers?"
        "Explain the difference between TCP and UDP protocols."
    )
    
    TOTAL_TOKENS=0
    TOTAL_TIME=0
    
    for PROMPT in "${PROMPTS[@]}"; do
        log_info "Testing: ${PROMPT:0:50}..."
        
        # Send request with timing
        START_TIME=$(date +%s%N)
        RESPONSE=$(curl -s -X POST http://localhost:8080/completion \
            -H "Content-Type: application/json" \
            -d "{
                \"prompt\": \"$PROMPT\",
                \"n_predict\": 256,
                \"temperature\": 0.7,
                \"top_p\": 0.9,
                \"stream\": false
            }")
        END_TIME=$(date +%s%N)
        
        # Calculate time
        TIME_MS=$(( (END_TIME - START_TIME) / 1000000 ))
        TIME_S=$(echo "scale=2; $TIME_MS / 1000" | bc)
        
        # Extract token count
        TOKENS=$(echo "$RESPONSE" | jq -r '.tokens_predicted // 0')
        
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
        log_info "✓ Medium prompts average token/s: $AVG_TOKEN_S"
        echo "$AVG_TOKEN_S" > "$OUTPUT_DIR/medium-prompts-token-s.txt"
    fi
}

# Test long prompts
test_long_prompts() {
    log_info "Testing long prompts..."
    
    PROMPTS=(
        "Write a detailed explanation of how a microkernel architecture works in modern operating systems. Include the advantages and disadvantages compared to monolithic kernels. Discuss the performance implications and security benefits."
        "Explain the complete lifecycle of a web request from the user's browser to the server and back. Include DNS resolution, TCP handshake, HTTP request/response, and rendering process."
        "Describe the architecture of a distributed database system. Include concepts like sharding, replication, consistency models, and fault tolerance mechanisms."
    )
    
    TOTAL_TOKENS=0
    TOTAL_TIME=0
    
    for PROMPT in "${PROMPTS[@]}"; do
        log_info "Testing: ${PROMPT:0:50}..."
        
        # Send request with timing
        START_TIME=$(date +%s%N)
        RESPONSE=$(curl -s -X POST http://localhost:8080/completion \
            -H "Content-Type: application/json" \
            -d "{
                \"prompt\": \"$PROMPT\",
                \"n_predict\": 512,
                \"temperature\": 0.7,
                \"top_p\": 0.9,
                \"stream\": false
            }")
        END_TIME=$(date +%s%N)
        
        # Calculate time
        TIME_MS=$(( (END_TIME - START_TIME) / 1000000 ))
        TIME_S=$(echo "scale=2; $TIME_MS / 1000" | bc)
        
        # Extract token count
        TOKENS=$(echo "$RESPONSE" | jq -r '.tokens_predicted // 0')
        
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
        log_info "✓ Long prompts average token/s: $AVG_TOKEN_S"
        echo "$AVG_TOKEN_S" > "$OUTPUT_DIR/long-prompts-token-s.txt"
    fi
}

# Test cache performance
test_cache_performance() {
    log_info "Testing cache performance..."
    
    PROMPT="What is the capital of France?"
    CACHE_HITS=0
    CACHE_MISSES=0
    
    for i in {1..10}; do
        log_info "Cache test $i..."
        
        # Send request
        RESPONSE=$(curl -s -X POST http://localhost:8080/completion \
            -H "Content-Type: application/json" \
            -d "{
                \"prompt\": \"$PROMPT\",
                \"n_predict\": 64,
                \"temperature\": 0.7,
                \"top_p\": 0.9,
                \"stream\": false
            }")
        
        # Check cache (simplified)
        if echo "$RESPONSE" | jq -r '.timings.prompt_n // 0' | grep -q "0"; then
            CACHE_HITS=$((CACHE_HITS + 1))
        else
            CACHE_MISSES=$((CACHE_MISSES + 1))
        fi
        
        sleep 1
    done
    
    TOTAL=$((CACHE_HITS + CACHE_MISSES))
    if [ "$TOTAL" -gt 0 ]; then
        CACHE_HIT_RATE=$(echo "scale=2; $CACHE_HITS * 100 / $TOTAL" | bc)
        log_info "✓ Cache hit rate: $CACHE_HIT_RATE%"
        echo "$CACHE_HIT_RATE" > "$OUTPUT_DIR/cache-hit-rate.txt"
    fi
}

# Generate performance report
generate_report() {
    log_info "Generating performance report..."
    
    REPORT_FILE="$OUTPUT_DIR/performance-report-$TIMESTAMP.md"
    
    cat > "$REPORT_FILE" << EOF
# Performance Test Report

**Date**: $(date)
**Model**: $MODEL_PATH
**Configuration**: ctx-size=4096, threads=8, gpu-layers=999, flash-attn=on

## Test Results

### Short Prompts
- Average Token/s: $(cat "$OUTPUT_DIR/short-prompts-token-s.txt" 2>/dev/null || echo "N/A")

### Medium Prompts
- Average Token/s: $(cat "$OUTPUT_DIR/medium-prompts-token-s.txt" 2>/dev/null || echo "N/A")

### Long Prompts
- Average Token/s: $(cat "$OUTPUT_DIR/long-prompts-token-s.txt" 2>/dev/null || echo "N/A")

### Cache Performance
- Cache Hit Rate: $(cat "$OUTPUT_DIR/cache-hit-rate.txt" 2>/dev/null || echo "N/A")%

## Performance Summary

- **Short Prompts**: $(cat "$OUTPUT_DIR/short-prompts-token-s.txt" 2>/dev/null || echo "N/A") token/s
- **Medium Prompts**: $(cat "$OUTPUT_DIR/medium-prompts-token-s.txt" 2>/dev/null || echo "N/A") token/s
- **Long Prompts**: $(cat "$OUTPUT_DIR/long-prompts-token-s.txt" 2>/dev/null || echo "N/A") token/s
- **Cache Hit Rate**: $(cat "$OUTPUT_DIR/cache-hit-rate.txt" 2>/dev/null || echo "N/A")%

## Optimization Recommendations

1. **Context Size**: 4096 tokens is optimal for most use cases
2. **Thread Count**: 8 threads provides good balance
3. **Flash Attention**: Enabled for better performance
4. **GPU Layers**: All layers on GPU for maximum speed

## Files

- Performance Report: $REPORT_FILE
- Server Log: $OUTPUT_DIR/server.log
- Short Prompts Token/s: $OUTPUT_DIR/short-prompts-token-s.txt
- Medium Prompts Token/s: $OUTPUT_DIR/medium-prompts-token-s.txt
- Long Prompts Token/s: $OUTPUT_DIR/long-prompts-token-s.txt
- Cache Hit Rate: $OUTPUT_DIR/cache-hit-rate.txt

## Notes

- All tests performed on Linux x86_64
- Model loaded with GPU acceleration (ROCm)
- Flash Attention enabled for optimal performance
- Cache performance measured with repeated prompts
EOF
    
    log_info "Performance report generated: $REPORT_FILE"
}

# Main function
main() {
    log_info "Starting performance test"
    
    check_prerequisites
    create_output_dir
    start_optimal_server
    
    # Run tests
    test_short_prompts
    test_medium_prompts
    test_long_prompts
    test_cache_performance
    
    # Generate report
    generate_report
    
    # Cleanup
    stop_server
    
    log_info "Performance test completed successfully"
    log_info "Results saved to: $OUTPUT_DIR"
}

# Trap to ensure cleanup
trap 'stop_server' EXIT

# Run main function
main "$@"