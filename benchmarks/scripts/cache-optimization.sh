#!/bin/bash
# Cache optimization script for trha

set -e

# Configuration
MODEL_PATH="/home/yanli/work/9060xt/models/Qwen3.8-27B-GGUF/Qwen3.8-27B-IQ3_M.gguf"
LLAMA_CPP_PATH="/home/yanli/work/9060xt/llama-b1312-ubuntu-rocm-gfx120X-x64"
OUTPUT_DIR="benchmarks/cache-optimization"
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

# Test different cache configurations
test_cache_configurations() {
    log_info "Testing different cache configurations..."
    
    # Test configurations
    CONFIGS=(
        "--ctx-size 2048 --threads 4"
        "--ctx-size 4096 --threads 8"
        "--ctx-size 8192 --threads 8"
        "--ctx-size 4096 --threads 8 --flash-attn on"
    )
    
    for CONFIG in "${CONFIGS[@]}"; do
        log_info "Testing configuration: $CONFIG"
        
        # Start server with configuration
        cd "$LLAMA_CPP_PATH"
        ./llama-server \
            --model "$MODEL_PATH" \
            $CONFIG \
            --gpu-layers 999 \
            --port 8080 \
            --host 0.0.0.0 \
            --log-disable \
            > "$OUTPUT_DIR/server.log" 2>&1 &
        
        SERVER_PID=$!
        
        # Wait for server to start
        sleep 10
        
        # Test cache performance
        test_cache_for_config "$CONFIG"
        
        # Stop server
        kill $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
        
        sleep 2
    done
}

# Test cache for specific configuration
test_cache_for_config() {
    local config=$1
    log_info "Testing cache for configuration: $config"
    
    # Test prompts
    PROMPTS=(
        "What is the capital of France?"
        "Explain machine learning."
        "Write a Python function."
        "What is the capital of France?"
        "Explain machine learning."
    )
    
    CACHE_HITS=0
    CACHE_MISSES=0
    TOTAL_TIME=0
    
    for PROMPT in "${PROMPTS[@]}"; do
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
        TOTAL_TIME=$((TOTAL_TIME + TIME_MS))
        
        # Check cache (simplified)
        if echo "$RESPONSE" | jq -r '.timings.prompt_n // 0' | grep -q "0"; then
            CACHE_HITS=$((CACHE_HITS + 1))
        else
            CACHE_MISSES=$((CACHE_MISSES + 1))
        fi
    done
    
    # Calculate metrics
    TOTAL=$((CACHE_HITS + CACHE_MISSES))
    if [ "$TOTAL" -gt 0 ]; then
        CACHE_HIT_RATE=$(echo "scale=2; $CACHE_HITS * 100 / $TOTAL" | bc)
        AVG_TIME=$(echo "scale=2; $TOTAL_TIME / $TOTAL" | bc)
        
        log_info "  Cache hit rate: $CACHE_HIT_RATE%"
        log_info "  Average response time: ${AVG_TIME}ms"
        
        # Save results
        echo "$config|$CACHE_HIT_RATE|$AVG_TIME" >> "$OUTPUT_DIR/cache-results.csv"
    fi
}

# Analyze cache results
analyze_cache_results() {
    log_info "Analyzing cache results..."
    
    if [ ! -f "$OUTPUT_DIR/cache-results.csv" ]; then
        log_error "No cache results found"
        return 1
    fi
    
    # Find best configuration
    BEST_CONFIG=""
    BEST_HIT_RATE=0
    BEST_TIME=999999
    
    while IFS='|' read -r config hit_rate avg_time; do
        if (( $(echo "$hit_rate > $BEST_HIT_RATE" | bc -l) )); then
            BEST_HIT_RATE=$hit_rate
            BEST_CONFIG=$config
            BEST_TIME=$avg_time
        elif (( $(echo "$hit_rate == $BEST_HIT_RATE" | bc -l) )); then
            if (( $(echo "$avg_time < $BEST_TIME" | bc -l) )); then
                BEST_CONFIG=$config
                BEST_TIME=$avg_time
            fi
        fi
    done < "$OUTPUT_DIR/cache-results.csv"
    
    log_info "Best configuration: $BEST_CONFIG"
    log_info "  Cache hit rate: $BEST_HIT_RATE%"
    log_info "  Average response time: ${BEST_TIME}ms"
    
    # Save best configuration
    echo "$BEST_CONFIG" > "$OUTPUT_DIR/best-config.txt"
    echo "$BEST_HIT_RATE" > "$OUTPUT_DIR/best-hit-rate.txt"
    echo "$BEST_TIME" > "$OUTPUT_DIR/best-time.txt"
}

# Generate optimization report
generate_report() {
    log_info "Generating optimization report..."
    
    REPORT_FILE="$OUTPUT_DIR/cache-optimization-report-$TIMESTAMP.md"
    
    cat > "$REPORT_FILE" << EOF
# Cache Optimization Report

**Date**: $(date)
**Model**: $MODEL_PATH

## Test Results

### Cache Configurations Tested

$(while IFS='|' read -r config hit_rate avg_time; do
    echo "- **Configuration**: \`$config\`"
    echo "  - Cache Hit Rate: $hit_rate%"
    echo "  - Average Response Time: ${avg_time}ms"
    echo ""
done < "$OUTPUT_DIR/cache-results.csv" 2>/dev/null || echo "No results available")

### Best Configuration

- **Configuration**: \`$(cat "$OUTPUT_DIR/best-config.txt" 2>/dev/null || echo "N/A")\`
- **Cache Hit Rate**: $(cat "$OUTPUT_DIR/best-hit-rate.txt" 2>/dev/null || echo "N/A")%
- **Average Response Time**: $(cat "$OUTPUT_DIR/best-time.txt" 2>/dev/null || echo "N/A")ms

## Recommendations

1. Use the best configuration for production
2. Monitor cache hit rate in production
3. Adjust context size based on use case
4. Enable Flash Attention if supported

## Files

- Optimization Report: $REPORT_FILE
- Cache Results: $OUTPUT_DIR/cache-results.csv
- Best Configuration: $OUTPUT_DIR/best-config.txt
- Best Hit Rate: $OUTPUT_DIR/best-hit-rate.txt
- Best Time: $OUTPUT_DIR/best-time.txt

## Notes

- All tests performed on Linux x86_64
- Model loaded with GPU acceleration (ROCm)
- Cache performance measured with repeated prompts
- Different context sizes and thread counts tested
EOF
    
    log_info "Optimization report generated: $REPORT_FILE"
}

# Main function
main() {
    log_info "Starting cache optimization"
    
    check_prerequisites
    create_output_dir
    test_cache_configurations
    analyze_cache_results
    generate_report
    
    log_info "Cache optimization completed successfully"
    log_info "Results saved to: $OUTPUT_DIR"
}

# Run main function
main "$@"