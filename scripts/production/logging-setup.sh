#!/bin/bash
# Logging setup script for gh-harness

set -e

# Configuration
LOG_DIR="/opt/gh-harness/logs"
CONFIG_FILE="config/production.yaml"
LOG_FILE="logs/logging-setup.log"
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
    
    # Check if log directory exists
    if [ ! -d "$LOG_DIR" ]; then
        log_info "Creating log directory..."
        mkdir -p "$LOG_DIR"
    fi
    
    log_info "Prerequisites checked successfully"
}

# Create log directories
create_log_directories() {
    log_info "Creating log directories..."
    
    # Create log directories
    mkdir -p "$LOG_DIR"
    mkdir -p "$LOG_DIR/agent"
    mkdir -p "$LOG_DIR/model"
    mkdir -p "$LOG_DIR/system"
    mkdir -p "$LOG_DIR/access"
    
    # Set permissions
    chown -R gh-harness:gh-harness "$LOG_DIR"
    chmod 755 "$LOG_DIR"
    
    log_info "Log directories created successfully"
}

# Configure structured logging
configure_structured_logging() {
    log_info "Configuring structured logging..."
    
    # Create logging configuration
    cat > "$LOG_DIR/logging.yaml" << EOF
# gh-harness structured logging configuration
version: 1
disable_existing_loggers: false

formatters:
  json:
    format: '{"timestamp": "%(asctime)s", "level": "%(levelname)s", "logger": "%(name)s", "message": "%(message)s", "module": "%(module)s", "function": "%(funcName)s", "line": %(lineno)d}'
    class: pythonjsonlogger.jsonlogger.JsonFormatter
  
  standard:
    format: '%(asctime)s [%(levelname)s] %(name)s: %(message)s'
    datefmt: '%Y-%m-%d %H:%M:%S'

handlers:
  console:
    class: logging.StreamHandler
    level: INFO
    formatter: standard
    stream: ext://sys.stdout
  
  file:
    class: logging.handlers.RotatingFileHandler
    level: DEBUG
    formatter: json
    filename: $LOG_DIR/gh-harness.log
    maxBytes: 10485760  # 10MB
    backupCount: 10
    encoding: utf8
  
  agent_file:
    class: logging.handlers.RotatingFileHandler
    level: DEBUG
    formatter: json
    filename: $LOG_DIR/agent/agent.log
    maxBytes: 10485760  # 10MB
    backupCount: 10
    encoding: utf8
  
  model_file:
    class: logging.handlers.RotatingFileHandler
    level: DEBUG
    formatter: json
    filename: $LOG_DIR/model/model.log
    maxBytes: 10485760  # 10MB
    backupCount: 10
    encoding: utf8
  
  system_file:
    class: logging.handlers.RotatingFileHandler
    level: DEBUG
    formatter: json
    filename: $LOG_DIR/system/system.log
    maxBytes: 10485760  # 10MB
    backupCount: 10
    encoding: utf8
  
  access_file:
    class: logging.handlers.RotatingFileHandler
    level: INFO
    formatter: json
    filename: $LOG_DIR/access/access.log
    maxBytes: 10485760  # 10MB
    backupCount: 10
    encoding: utf8

loggers:
  agent:
    level: DEBUG
    handlers: [agent_file, console]
    propagate: false
  
  model:
    level: DEBUG
    handlers: [model_file, console]
    propagate: false
  
  system:
    level: DEBUG
    handlers: [system_file, console]
    propagate: false
  
  access:
    level: INFO
    handlers: [access_file, console]
    propagate: false

root:
  level: INFO
  handlers: [file, console]
EOF
    
    log_info "Structured logging configured successfully"
}

# Configure logrotate for structured logs
configure_logrotate() {
    log_info "Configuring logrotate..."
    
    cat > /etc/logrotate.d/gh-harness-structured << EOF
$LOG_DIR/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 gh-harness gh-harness
    sharedscripts
    postrotate
        systemctl reload gh-harness > /dev/null 2>&1 || true
    endscript
}

$LOG_DIR/**/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 gh-harness gh-harness
    sharedscripts
    postrotate
        systemctl reload gh-harness > /dev/null 2>&1 || true
    endscript
}
EOF
    
    log_info "Logrotate configured successfully"
}

# Create log analysis scripts
create_log_analysis() {
    log_info "Creating log analysis scripts..."
    
    # Create log analysis script
    cat > "$LOG_DIR/analyze-logs.sh" << 'EOF'
#!/bin/bash
# Log analysis script for gh-harness

LOG_DIR="/opt/gh-harness/logs"

echo "=== gh-harness Log Analysis ==="
echo "Date: $(date)"
echo ""

# Count log entries by level
echo "Log entries by level:"
echo "  DEBUG: $(grep -r '"level": "DEBUG"' $LOG_DIR/*.log 2>/dev/null | wc -l)"
echo "  INFO: $(grep -r '"level": "INFO"' $LOG_DIR/*.log 2>/dev/null | wc -l)"
echo "  WARNING: $(grep -r '"level": "WARNING"' $LOG_DIR/*.log 2>/dev/null | wc -l)"
echo "  ERROR: $(grep -r '"level": "ERROR"' $LOG_DIR/*.log 2>/dev/null | wc -l)"
echo "  CRITICAL: $(grep -r '"level": "CRITICAL"' $LOG_DIR/*.log 2>/dev/null | wc -l)"
echo ""

# Recent errors
echo "Recent errors (last 10):"
grep -r '"level": "ERROR"' $LOG_DIR/*.log 2>/dev/null | tail -10
echo ""

# Recent warnings
echo "Recent warnings (last 10):"
grep -r '"level": "WARNING"' $LOG_DIR/*.log 2>/dev/null | tail -10
echo ""

# Log file sizes
echo "Log file sizes:"
du -sh $LOG_DIR/*.log 2>/dev/null
du -sh $LOG_DIR/**/*.log 2>/dev/null
EOF
    
    chmod +x "$LOG_DIR/analyze-logs.sh"
    
    log_info "Log analysis scripts created successfully"
}

# Generate logging report
generate_report() {
    log_info "Generating logging report..."
    
    REPORT_FILE="reports/logging-setup-$TIMESTAMP.md"
    mkdir -p reports
    
    cat > "$REPORT_FILE" << EOF
# Logging Setup Report

**Date**: $(date)
**Server**: $(hostname)

## Logging Configuration

### Directory Structure
- $LOG_DIR/
- $LOG_DIR/agent/
- $LOG_DIR/model/
- $LOG_DIR/system/
- $LOG_DIR/access/

### Log Format
- **Format**: JSON structured logging
- **Rotation**: Daily, 14 days
- **Max Size**: 10MB per file
- **Encoding**: UTF-8

### Log Levels
- **Agent**: DEBUG
- **Model**: DEBUG
- **System**: DEBUG
- **Access**: INFO
- **Root**: INFO

## Log Files

- **Main Log**: $LOG_DIR/gh-harness.log
- **Agent Log**: $LOG_DIR/agent/agent.log
- **Model Log**: $LOG_DIR/model/model.log
- **System Log**: $LOG_DIR/system/system.log
- **Access Log**: $LOG_DIR/access/access.log

## Analysis

- **Analysis Script**: $LOG_DIR/analyze-logs.sh
- **Logrotate Config**: /etc/logrotate.d/gh-harness-structured

## Commands

- View logs: \`tail -f $LOG_DIR/gh-harness.log\`
- Analyze logs: \`$LOG_DIR/analyze-logs.sh\`
- Check errors: \`grep '"level": "ERROR"' $LOG_DIR/*.log\`
- Check warnings: \`grep '"level": "WARNING"' $LOG_DIR/*.log\`

## Files

- Logging Report: $REPORT_FILE
- Log File: $LOG_FILE
- Logging Config: $LOG_DIR/logging.yaml
- Analysis Script: $LOG_DIR/analyze-logs.sh
- Logrotate Config: /etc/logrotate.d/gh-harness-structured

## Notes

- Structured JSON logging configured
- Log rotation configured for 14 days
- Separate logs for different components
- Analysis scripts created for troubleshooting
EOF
    
    log_info "Logging report generated: $REPORT_FILE"
}

# Main function
main() {
    log_info "Starting logging setup"
    
    check_prerequisites
    create_log_directories
    configure_structured_logging
    configure_logrotate
    create_log_analysis
    generate_report
    
    log_info "Logging setup completed successfully"
    log_info "Logs directory: $LOG_DIR"
}

# Run main function
main "$@"