#!/bin/bash
# Network optimization script for gh-harness

set -e

# Configuration
CONFIG_FILE="config/production.yaml"
LOG_FILE="logs/network-optimization.log"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" >> "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$LOG_FILE"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Check if config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        log_warn "Config file not found: $CONFIG_FILE"
    fi
    
    log_info "Prerequisites checked successfully"
}

# Create log directory
create_log_dir() {
    log_info "Creating log directory..."
    mkdir -p logs
    log_info "Log directory created"
}

# Optimize TCP settings
optimize_tcp() {
    log_info "Optimizing TCP settings..."
    
    # Backup current settings
    cp /etc/sysctl.conf /etc/sysctl.conf.backup.$TIMESTAMP
    
    # TCP optimization settings
    cat >> /etc/sysctl.conf << EOF

# gh-harness TCP optimization
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mem = 786432 1048576 1572864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
EOF
    
    # Apply settings
    sysctl -p
    
    log_info "TCP settings optimized"
}

# Optimize network buffers
optimize_buffers() {
    log_info "Optimizing network buffers..."
    
    # Increase buffer sizes
    cat >> /etc/sysctl.conf << EOF

# gh-harness buffer optimization
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 1048576
EOF
    
    # Apply settings
    sysctl -p
    
    log_info "Network buffers optimized"
}

# Optimize connection tracking
optimize_conntrack() {
    log_info "Optimizing connection tracking..."
    
    # Connection tracking settings
    cat >> /etc/sysctl.conf << EOF

# gh-harness connection tracking optimization
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
EOF
    
    # Apply settings
    sysctl -p
    
    log_info "Connection tracking optimized"
}

# Optimize file descriptors
optimize_file_descriptors() {
    log_info "Optimizing file descriptors..."
    
    # Set file descriptor limits
    cat >> /etc/security/limits.conf << EOF

# gh-harness file descriptor optimization
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 1048576
root hard nproc 1048576
EOF
    
    # Set systemd limits
    mkdir -p /etc/systemd/system/gh-harness.service.d
    cat > /etc/systemd/system/gh-harness.service.d/limits.conf << EOF
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
EOF
    
    log_info "File descriptors optimized"
}

# Optimize DNS resolution
optimize_dns() {
    log_info "Optimizing DNS resolution..."
    
    # Backup current resolv.conf
    cp /etc/resolv.conf /etc/resolv.conf.backup.$TIMESTAMP
    
    # Optimize DNS settings
    cat > /etc/resolv.conf << EOF
# gh-harness DNS optimization
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
nameserver 1.0.0.1
options timeout:2 attempts:3 rotate single-request-reopen
EOF
    
    log_info "DNS resolution optimized"
}

# Test network performance
test_network_performance() {
    log_info "Testing network performance..."
    
    # Test localhost performance
    log_info "Testing localhost performance..."
    for i in {1..10}; do
        curl -s -o /dev/null -w "%{time_total}\n" http://localhost:8080/health
    done | awk '{ sum += $1; n++ } END { print "Average localhost response time: " sum/n " seconds" }'
    
    # Test DNS resolution
    log_info "Testing DNS resolution..."
    for domain in google.com github.com huggingface.co; do
        start_time=$(date +%s%N)
        nslookup $domain > /dev/null 2>&1
        end_time=$(date +%s%N)
        duration=$(( (end_time - start_time) / 1000000 ))
        log_info "  $domain: ${duration}ms"
    done
    
    log_info "Network performance test completed"
}

# Generate optimization report
generate_report() {
    log_info "Generating optimization report..."
    
    REPORT_FILE="reports/network-optimization-$TIMESTAMP.md"
    mkdir -p reports
    
    cat > "$REPORT_FILE" << EOF
# Network Optimization Report

**Date**: $(date)
**Server**: $(hostname)

## Optimizations Applied

### TCP Settings
- somaxconn: 65535
- netdev_max_backlog: 65535
- tcp_max_syn_backlog: 65535
- tcp_fin_timeout: 15s
- tcp_tw_reuse: enabled
- tcp_keepalive_time: 300s

### Network Buffers
- rmem_max: 16MB
- wmem_max: 16MB
- rmem_default: 1MB
- wmem_default: 1MB

### Connection Tracking
- nf_conntrack_max: 1048576
- tcp_timeout_established: 3600s

### File Descriptors
- soft nofile: 1048576
- hard nofile: 1048576

### DNS Resolution
- Primary: 8.8.8.8
- Secondary: 8.8.4.4
- Timeout: 2s
- Attempts: 3

## Performance Test Results

$(test_network_performance 2>&1 | grep -E "(Average|ms)")

## Files

- Optimization Report: $REPORT_FILE
- Log File: $LOG_FILE
- Backup: /etc/sysctl.conf.backup.$TIMESTAMP

## Notes

- All optimizations applied successfully
- TCP settings optimized for high-concurrency
- Network buffers increased for better throughput
- DNS resolution optimized for speed
- File descriptors increased for more connections
EOF
    
    log_info "Optimization report generated: $REPORT_FILE"
}

# Main function
main() {
    log_info "Starting network optimization"
    
    check_prerequisites
    create_log_dir
    optimize_tcp
    optimize_buffers
    optimize_conntrack
    optimize_file_descriptors
    optimize_dns
    test_network_performance
    generate_report
    
    log_info "Network optimization completed successfully"
    log_info "Results saved to: reports/"
}

# Run main function
main "$@"