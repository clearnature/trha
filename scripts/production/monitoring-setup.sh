#!/bin/bash
# Monitoring setup script for gh-harness

set -e

# Configuration
MONITORING_DIR="/opt/gh-harness/monitoring"
CONFIG_FILE="config/production.yaml"
LOG_FILE="logs/monitoring-setup.log"
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
    
    # Check if monitoring directory exists
    if [ ! -d "$MONITORING_DIR" ]; then
        log_info "Creating monitoring directory..."
        mkdir -p "$MONITORING_DIR"
    fi
    
    log_info "Prerequisites checked successfully"
}

# Install Prometheus
install_prometheus() {
    log_info "Installing Prometheus..."
    
    # Create Prometheus user
    useradd --no-create-home --shell /bin/false prometheus || true
    
    # Create Prometheus directories
    mkdir -p /etc/prometheus
    mkdir -p /var/lib/prometheus
    
    # Download Prometheus
    PROMETHEUS_VERSION="2.45.0"
    wget -q https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
    tar -xzf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
    
    # Install Prometheus
    cp prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus /usr/local/bin/
    cp prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool /usr/local/bin/
    cp -r prometheus-${PROMETHEUS_VERSION}.linux-amd64/consoles /etc/prometheus
    cp -r prometheus-${PROMETHEUS_VERSION}.linux-amd64/console_libraries /etc/prometheus
    
    # Cleanup
    rm -rf prometheus-${PROMETHEUS_VERSION}.linux-amd64*
    
    # Set permissions
    chown -R prometheus:prometheus /etc/prometheus
    chown -R prometheus:prometheus /var/lib/prometheus
    
    log_info "Prometheus installed successfully"
}

# Configure Prometheus
configure_prometheus() {
    log_info "Configuring Prometheus..."
    
    # Create Prometheus configuration
    cat > /etc/prometheus/prometheus.yml << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'gh-harness'
    static_configs:
      - targets: ['localhost:8080']
    metrics_path: '/metrics'
    scrape_interval: 5s

  - job_name: 'node-exporter'
    static_configs:
      - targets: ['localhost:9100']

  - job_name: 'llama-server'
    static_configs:
      - targets: ['localhost:8081']
    metrics_path: '/metrics'
    scrape_interval: 5s
EOF
    
    # Create Prometheus systemd service
    cat > /etc/systemd/system/prometheus.service << EOF
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \\
  --config.file=/etc/prometheus/prometheus.yml \\
  --storage.tsdb.path=/var/lib/prometheus/ \\
  --web.console.templates=/etc/prometheus/consoles \\
  --web.console.libraries=/etc/prometheus/console_libraries \\
  --web.enable-lifecycle
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable and start Prometheus
    systemctl daemon-reload
    systemctl enable prometheus
    systemctl start prometheus
    
    log_info "Prometheus configured successfully"
}

# Install Grafana
install_grafana() {
    log_info "Installing Grafana..."
    
    # Add Grafana repository
    apt-get install -y software-properties-common
    add-apt-repository "deb https://packages.grafana.com/oss/deb stable main"
    wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
    
    # Install Grafana
    apt-get update
    apt-get install -y grafana
    
    # Enable and start Grafana
    systemctl daemon-reload
    systemctl enable grafana-server
    systemctl start grafana-server
    
    log_info "Grafana installed successfully"
}

# Install Node Exporter
install_node_exporter() {
    log_info "Installing Node Exporter..."
    
    # Create Node Exporter user
    useradd --no-create-home --shell /bin/false node_exporter || true
    
    # Download Node Exporter
    NODE_EXPORTER_VERSION="1.6.1"
    wget -q https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
    tar -xzf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
    
    # Install Node Exporter
    cp node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
    
    # Cleanup
    rm -rf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64*
    
    # Create Node Exporter systemd service
    cat > /etc/systemd/system/node-exporter.service << EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable and start Node Exporter
    systemctl daemon-reload
    systemctl enable node-exporter
    systemctl start node-exporter
    
    log_info "Node Exporter installed successfully"
}

# Configure Grafana dashboards
configure_grafana() {
    log_info "Configuring Grafana dashboards..."
    
    # Wait for Grafana to start
    sleep 10
    
    # Add Prometheus data source
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d '{
            "name": "Prometheus",
            "type": "prometheus",
            "url": "http://localhost:9090",
            "access": "proxy",
            "isDefault": true
        }' \
        http://admin:admin@localhost:3000/api/datasources
    
    # Import gh-harness dashboard
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d @config/grafana-dashboard.json \
        http://admin:admin@localhost:3000/api/dashboards/db
    
    log_info "Grafana dashboards configured successfully"
}

# Generate monitoring report
generate_report() {
    log_info "Generating monitoring report..."
    
    REPORT_FILE="reports/monitoring-setup-$TIMESTAMP.md"
    mkdir -p reports
    
    cat > "$REPORT_FILE" << EOF
# Monitoring Setup Report

**Date**: $(date)
**Server**: $(hostname)

## Components Installed

### Prometheus
- Version: 2.45.0
- Port: 9090
- Config: /etc/prometheus/prometheus.yml
- Data: /var/lib/prometheus/

### Grafana
- Version: Latest
- Port: 3000
- Default Credentials: admin/admin

### Node Exporter
- Version: 1.6.1
- Port: 9100

## Monitoring Targets

- **gh-harness**: localhost:8080/metrics
- **llama-server**: localhost:8081/metrics
- **Node Exporter**: localhost:9100

## Dashboards

- **gh-harness Overview**: System metrics, request rates, response times
- **Node Overview**: CPU, memory, disk, network

## Access

- **Prometheus**: http://localhost:9090
- **Grafana**: http://localhost:3000
- **Node Exporter**: http://localhost:9100

## Files

- Monitoring Report: $REPORT_FILE
- Log File: $LOG_FILE
- Prometheus Config: /etc/prometheus/prometheus.yml
- Grafana Config: /etc/grafana/grafana.ini

## Notes

- All monitoring components installed and configured
- Prometheus scraping gh-harness metrics
- Grafana dashboards configured
- Node Exporter monitoring system metrics
EOF
    
    log_info "Monitoring report generated: $REPORT_FILE"
}

# Main function
main() {
    log_info "Starting monitoring setup"
    
    check_prerequisites
    install_prometheus
    configure_prometheus
    install_grafana
    install_node_exporter
    configure_grafana
    generate_report
    
    log_info "Monitoring setup completed successfully"
    log_info "Access Grafana at: http://localhost:3000"
}

# Run main function
main "$@"