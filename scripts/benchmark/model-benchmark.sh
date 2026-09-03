#!/bin/bash
# Model benchmark script for gh-harness

set -e

# Configuration
MODEL_PATH="/home/yanli/work/9060xt/models/Qwen3.8-27B-GGUF/Qwen3.8-27B-IQ3_M.gguf"
LLAMA_CPP_PATH="/home/yanli/work/9060xt/llama-b1312-ubuntu-rocm-gfx120X-x64"
OUTPUT_DIR="benchmarks/results"
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
    
    # Check if llama-server exists
    if [ ! -f "$LLAMA_CPP_PATH/llama-server" ]; then
        log_error "llama-server not found in llama.cpp"
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

# Start llama-server
start_llama_server() {
    log_info "Starting llama-server..."
    
    # Start server in background
    cd "$LLAMA_CPP_PATH"
    ./llama-server \
        --model "$MODEL_PATH" \
        --ctx-size 4096 \
        --threads 8 \
        --gpu-layers 999 \
        --port 8080 \
        --host 0.0.0.0 \
        --log-disable \
        > "$OUTPUT_DIR/llama-server.log" 2>&1 &
    
    SERVER_PID=$!
    log_info "llama-server started with PID: $SERVER_PID"
    
    # Wait for server to start
    log_info "Waiting for server to start..."
    sleep 10
    
    # Check if server is running
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        log_error "llama-server failed to start"
        cat "$OUTPUT_DIR/llama-server.log"
        exit 1
    fi
    
    log_info "llama-server started successfully"
}

# Stop llama-server
stop_llama_server() {
    log_info "Stopping llama-server..."
    if [ ! -z "$SERVER_PID" ]; then
        kill $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
    fi
    log_info "llama-server stopped"
}

# Test model loading
test_model_loading() {
    log_info "Testing model loading..."
    
    # Send test request to check if model is loaded
    RESPONSE=$(curl -s http://localhost:8080/health)
    
    if echo "$RESPONSE" | grep -q "ok"; then
        log_info "✓ Model loaded successfully"
        return 0
    else
        log_error "✗ Model loading failed"
        echo "$RESPONSE"
        return 1
    fi
}

# Test long text generation
test_long_text_generation() {
    log_info "Testing long text generation..."
    
    # Test prompt
    PROMPT="Write a detailed explanation of how a microkernel architecture works in modern operating systems. Include the advantages and disadvantages compared to monolithic kernels."
    
    # Send request
    RESPONSE=$(curl -s -X POST http://localhost:8080/completion \
        -H "Content-Type: application/json" \
        -d "{
            \"prompt\": \"$PROMPT\",
            \"n_predict\": 1024,
            \"temperature\": 0.7,
            \"top_p\": 0.9,
            \"stream\": false
        }")
    
    # Extract completion
    COMPLETION=$(echo "$RESPONSE" | jq -r '.content // empty')
    
    if [ -n "$COMPLETION" ]; then
        log_info "✓ Long text generation successful"
        echo "$COMPLETION" > "$OUTPUT_DIR/long-text-output.txt"
        
        # Calculate token count
        TOKEN_COUNT=$(echo "$COMPLETION" | wc -w)
        log_info "Generated tokens: ~$TOKEN_COUNT"
        
        return 0
    else
        log_error "✗ Long text generation failed"
        echo "$RESPONSE"
        return 1
    fi
}

# Test token/s performance
test_token_performance() {
    log_info "Testing token/s performance..."
    
    # Test prompts of different lengths
    PROMPTS=(
        "Hello, how are you?"
        "Explain the concept of machine learning in simple terms."
        "Write a Python function to calculate the Fibonacci sequence."
        "Describe the architecture of a modern web application."
    )
    
    TOTAL_TOKENS=0
    TOTAL_TIME=0
    
    for PROMPT in "${PROMPTS[@]}"; do
        log_info "Testing prompt: ${PROMPT:0:50}..."
        
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
        
        # Calculate time in seconds
        TIME_MS=$(( (END_TIME - START_TIME) / 1000000 ))
        TIME_S=$(echo "scale=2; $TIME_MS / 1000" | bc)
        
        # Extract token count
        TOKENS=$(echo "$RESPONSE" | jq -r '.tokens_predicted // 0')
        
        if [ "$TOKENS" -gt 0 ]; then
            # Calculate token/s
            TOKEN_S=$(echo "scale=2; $TOKENS / $TIME_S" | bc)
            
            log_info "  Tokens: $TOKENS, Time: ${TIME_S}s, Token/s: $TOKEN_S"
            
            TOTAL_TOKENS=$((TOTAL_TOKENS + TOKENS))
            TOTAL_TIME=$(echo "scale=2; $TOTAL_TIME + $TIME_S" | bc)
        else
            log_warn "  No tokens generated"
        fi
    done
    
    # Calculate average token/s
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

# Test cache performance
test_cache_performance() {
    log_info "Testing cache performance..."
    
    # Test with same prompt multiple times
    PROMPT="What is the capital of France?"
    CACHE_HITS=0
    CACHE_MISSES=0
    
    for i in {1..5}; do
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
        
        # Check if cached (simplified check)
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
        return 0
    else
        log_error "✗ No cache test results"
        return 1
    fi
}

# Generate benchmark report
generate_report() {
    log_info "Generating benchmark report..."
    
    REPORT_FILE="$OUTPUT_DIR/benchmark-report-$TIMESTAMP.md"
    
    cat > "$REPORT_FILE" << EOF
# gh-harness Benchmark Report

**Date**: $(date)
**Model**: $MODEL_PATH
**llama.cpp**: $LLAMA_CPP_PATH

## Test Results

### Model Loading
- Status: $(test_model_loading > /dev/null 2>&1 && echo "✓ Passed" || echo "✗ Failed")

### Long Text Generation
- Status: $(test_long_text_generation > /dev/null 2>&1 && echo "✓ Passed" || echo "✗ Failed")
- Output: $OUTPUT_DIR/long-text-output.txt

### Token/s Performance
- Status: $(test_token_performance > /dev/null 2>&1 && echo "✓ Passed" || echo "✗ Failed")
- Average Token/s: $(cat "$OUTPUT_DIR/avg-token-s.txt" 2>/dev/null || echo "N/A")

### Cache Performance
- Status: $(test_cache_performance > /dev/null 2>&1 && echo "✓ Passed" || echo "✗ Failed")
- Cache Hit Rate: $(cat "$OUTPUT_DIR/cache-hit-rate.txt" 2>/dev/null || echo "N/A")%

## Performance Metrics

- **Token/s**: $(cat "$OUTPUT_DIR/avg-token-s.txt" 2>/dev/null || echo "N/A")
- **Cache Hit Rate**: $(cat "$OUTPUT_DIR/cache-hit-rate.txt" 2>/dev/null || echo "N/A")%

## Files

- Benchmark Report: $REPORT_FILE
- Server Log: $OUTPUT_DIR/llama-server.log
- Long Text Output: $OUTPUT_DIR/long-text-output.txt
- Average Token/s: $OUTPUT_DIR/avg-token-s.txt
- Cache Hit Rate: $OUTPUT_DIR/cache-hit-rate.txt

## Notes

- All tests performed on Linux x86_64
- Model loaded with GPU acceleration (ROCm)
- Cache performance measured with repeated prompts
EOF
    
    log_info "Benchmark report generated: $REPORT_FILE"
}

# Main function
main() {
    log_info "Starting model benchmark"
    
    check_prerequisites
    create_output_dir
    start_llama_server
    
    # Run tests
    test_model_loading
    test_long_text_generation
    test_token_performance
    test_cache_performance
    
    # Generate report
    generate_report
    
    # Cleanup
    stop_llama_server
    
    log_info "Benchmark completed successfully"
    log_info "Results saved to: $OUTPUT_DIR"
}

# Trap to ensure cleanup
trap 'stop_llama_server' EXIT

# Run main function
main "$@"