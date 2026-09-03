#!/bin/bash
# Test static binary on multiple Linux distributions

set -e

# Configuration
BINARY="dist/gh-harness"
DISTROS=("ubuntu:22.04" "centos:7" "debian:11" "alpine:3.19" "fedora:38")

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

# Check if binary exists
check_binary() {
    if [ ! -f "$BINARY" ]; then
        log_error "Binary not found: $BINARY"
        exit 1
    fi
    
    if [ ! -x "$BINARY" ]; then
        log_warn "Binary is not executable, making it executable..."
        chmod +x "$BINARY"
    fi
    
    log_info "Binary found: $BINARY"
}

# Test on single distribution
test_distro() {
    local distro=$1
    log_info "Testing on $distro..."
    
    # Run test in Docker container
    docker run --rm -v "$(pwd)/$BINARY:/gh-harness:ro" "$distro" bash -c "
        # Make binary executable
        chmod +x /gh-harness
        
        # Test version
        echo 'Testing --version...'
        /gh-harness --version
        
        # Test help
        echo 'Testing --help...'
        /gh-harness --help
        
        # Test basic functionality
        echo 'Testing basic functionality...'
        /gh-harness --test-mode
        
        echo 'All tests passed on $distro'
    "
    
    if [ $? -eq 0 ]; then
        log_info "✓ $distro: Tests passed"
        return 0
    else
        log_error "✗ $distro: Tests failed"
        return 1
    fi
}

# Main function
main() {
    log_info "Starting multi-distribution tests"
    
    check_binary
    
    local failed=0
    
    for distro in "${DISTROS[@]}"; do
        if ! test_distro "$distro"; then
            ((failed++))
        fi
    done
    
    if [ $failed -eq 0 ]; then
        log_info "All distribution tests passed!"
        exit 0
    else
        log_error "$failed distribution(s) failed"
        exit 1
    fi
}

# Run main function
main "$@"