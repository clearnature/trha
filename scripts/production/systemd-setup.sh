#!/bin/bash
# systemd service setup script for trha

set -e

# Configuration
SERVICE_NAME="trha"
SERVICE_USER="trha"
SERVICE_GROUP="trha"
INSTALL_DIR="/opt/trha"
CONFIG_FILE="config/production.yaml"
LOG_FILE="logs/systemd-setup.log"
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
    
    # Check if binary exists
    if [ ! -f "$INSTALL_DIR/trha" ]; then
        log_error "Binary not found: $INSTALL_DIR/trha"
        exit 1
    fi
    
    log_info "Prerequisites checked successfully"
}

# Create service user
create_service_user() {
    log_info "Creating service user..."
    
    # Create user if not exists
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd --system --shell /bin/false --home-dir "$INSTALL_DIR" "$SERVICE_USER"
        log_info "User $SERVICE_USER created"
    else
        log_info "User $SERVICE_USER already exists"
    fi
    
    # Create group if not exists
    if ! getent group "$SERVICE_GROUP" &>/dev/null; then
        groupadd --system "$SERVICE_GROUP"
        log_info "Group $SERVICE_GROUP created"
    else
        log_info "Group $SERVICE_GROUP already exists"
    fi
    
    # Add user to group
    usermod -a -G "$SERVICE_GROUP" "$SERVICE_USER"
    
    log_info "Service user created successfully"
}

# Create directories
create_directories() {
    log_info "Creating directories..."
    
    # Create installation directory
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/config"
    mkdir -p "$INSTALL_DIR/logs"
    mkdir -p "$INSTALL_DIR/data"
    mkdir -p "$INSTALL_DIR/models"
    
    # Set permissions
    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
    
    log_info "Directories created successfully"
}

# Copy binary and config
copy_files() {
    log_info "Copying files..."
    
    # Copy binary
    cp trha "$INSTALL_DIR/"
    chmod 755 "$INSTALL_DIR/trha"
    
    # Copy config
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$INSTALL_DIR/config/"
    else
        # Create default config
        cat > "$INSTALL_DIR/config/production.yaml" << EOF
# trha production configuration
# 安全约定：只绑 loopback；端口/token 以 ~/.trha/runtime.json 为运行真相。
server:
  host: 127.0.0.1
  port: 28433
  workers: 8

kernel:
  host: 127.0.0.1
  port: 19433

model:
  path: /opt/trha/models
  context_size: 4096
  gpu_layers: 999
  threads: 8

logging:
  level: info
  format: json
  output: /opt/trha/logs/trha.log

monitoring:
  enabled: true
  port: 9090

cache:
  enabled: true
  size: 1000
  ttl: 3600
EOF
    fi
    
    # Set permissions
    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"
    
    log_info "Files copied successfully"
}

# Create systemd service
create_systemd_service() {
    log_info "Creating systemd service..."
    
    # Create service file
    cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=trha Agent Harness
Documentation=https://github.com/clearnature/trha
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/trha --config $INSTALL_DIR/config/production.yaml
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
TimeoutStartSec=30
TimeoutStopSec=30

# Environment
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=HOME=$INSTALL_DIR

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$INSTALL_DIR

# Resource limits
LimitNOFILE=1048576
LimitNPROC=1048576
LimitCORE=infinity
LimitFSIZE=infinity
LimitDATA=infinity
LimitSTACK=infinity
LimitRSS=infinity
LimitAS=infinity
LimitMEMLOCK=infinity
LimitLOCKS=infinity
LimitSIGPENDING=infinity
LimitMSGQUEUE=infinity
LimitNICE=infinity
LimitRTPRIO=infinity
LimitRTTIME=infinity

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable service
    systemctl enable "$SERVICE_NAME"
    
    log_info "systemd service created successfully"
}

# Create logrotate configuration
create_logrotate() {
    log_info "Creating logrotate configuration..."
    
    cat > "/etc/logrotate.d/$SERVICE_NAME" << EOF
$INSTALL_DIR/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 $SERVICE_USER $SERVICE_GROUP
    sharedscripts
    postrotate
        systemctl reload $SERVICE_NAME > /dev/null 2>&1 || true
    endscript
}
EOF
    
    log_info "Logrotate configuration created successfully"
}

# Start service
start_service() {
    log_info "Starting service..."
    
    # Start service
    systemctl start "$SERVICE_NAME"
    
    # Check status
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "Service started successfully"
    else
        log_error "Service failed to start"
        systemctl status "$SERVICE_NAME"
        exit 1
    fi
}

# Generate setup report
generate_report() {
    log_info "Generating setup report..."
    
    REPORT_FILE="reports/systemd-setup-$TIMESTAMP.md"
    mkdir -p reports
    
    cat > "$REPORT_FILE" << EOF
# systemd Setup Report

**Date**: $(date)
**Server**: $(hostname)

## Service Configuration

- **Service Name**: $SERVICE_NAME
- **Service User**: $SERVICE_USER
- **Service Group**: $SERVICE_GROUP
- **Installation Directory**: $INSTALL_DIR
- **Config File**: $INSTALL_DIR/config/production.yaml

## Directories Created

- $INSTALL_DIR/
- $INSTALL_DIR/config/
- $INSTALL_DIR/logs/
- $INSTALL_DIR/data/
- $INSTALL_DIR/models/

## systemd Service

- **Service File**: /etc/systemd/system/$SERVICE_NAME.service
- **Status**: $(systemctl is-active $SERVICE_NAME)
- **Enabled**: $(systemctl is-enabled $SERVICE_NAME)

## Logrotate

- **Config File**: /etc/logrotate.d/$SERVICE_NAME
- **Rotation**: Daily, 14 days

## Commands

- Start: \`systemctl start $SERVICE_NAME\`
- Stop: \`systemctl stop $SERVICE_NAME\`
- Restart: \`systemctl restart $SERVICE_NAME\`
- Status: \`systemctl status $SERVICE_NAME\`
- Logs: \`journalctl -u $SERVICE_NAME -f\`

## Files

- Setup Report: $REPORT_FILE
- Log File: $LOG_FILE
- Service File: /etc/systemd/system/$SERVICE_NAME.service
- Logrotate Config: /etc/logrotate.d/$SERVICE_NAME

## Notes

- Service configured for automatic restart
- Security hardening applied
- Resource limits configured
- Log rotation configured
EOF
    
    log_info "Setup report generated: $REPORT_FILE"
}

# Main function
main() {
    log_info "Starting systemd setup"
    
    check_prerequisites
    create_service_user
    create_directories
    copy_files
    create_systemd_service
    create_logrotate
    start_service
    generate_report
    
    log_info "systemd setup completed successfully"
    log_info "Service status: $(systemctl is-active $SERVICE_NAME)"
}

# Run main function
main "$@"