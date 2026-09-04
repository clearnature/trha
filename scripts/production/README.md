# Production Scripts

用于生产环境部署和优化的脚本。

## 概述

这些脚本用于生产环境的部署、优化和监控。

## 脚本

| 脚本 | 文件 | 职责 |
|------|------|------|
| **network-optimization.sh** | `network-optimization.sh` | 网络优化 |
| **monitoring-setup.sh** | `monitoring-setup.sh` | 监控部署 |
| **systemd-setup.sh** | `systemd-setup.sh` | systemd 服务配置 |
| **logging-setup.sh** | `logging-setup.sh` | 结构化日志配置 |

## 使用方法

### 网络优化

```bash
# 运行网络优化脚本
sudo ./scripts/production/network-optimization.sh
```

### 监控部署

```bash
# 运行监控部署脚本
sudo ./scripts/production/monitoring-setup.sh
```

### systemd 服务配置

```bash
# 运行 systemd 服务配置脚本
sudo ./scripts/production/systemd-setup.sh
```

### 结构化日志配置

```bash
# 运行结构化日志配置脚本
sudo ./scripts/production/logging-setup.sh
```

## 优化内容

### 网络优化

1. **TCP 设置优化**：somaxconn、tcp_max_syn_backlog、tcp_fin_timeout 等
2. **网络缓冲区优化**：rmem_max、wmem_max 等
3. **连接跟踪优化**：nf_conntrack_max、tcp_timeout_established 等
4. **文件描述符优化**：nofile、nproc 等
5. **DNS 解析优化**：nameserver、timeout 等

### 监控部署

1. **Prometheus**：指标收集和存储
2. **Grafana**：可视化仪表板
3. **Node Exporter**：系统指标监控

### systemd 服务配置

1. **服务用户创建**：trha 用户
2. **目录创建**：安装、配置、日志、数据目录
3. **服务配置**：systemd 服务文件
4. **日志轮转**：logrotate 配置

### 结构化日志配置

1. **日志目录**：agent、model、system、access 目录
2. **日志格式**：JSON 结构化日志
3. **日志轮转**：每日轮转，保留 14 天
4. **日志分析**：分析脚本

## 配置文件

### 生产配置

- **文件**: `config/production.yaml`
- **内容**: 服务器、模型、日志、监控、缓存、安全、性能、存储、网络、资源

### systemd 服务

- **文件**: `/etc/systemd/system/trha.service`
- **内容**: 服务配置、用户、权限、资源限制

### 日志配置

- **文件**: `/opt/trha/logs/logging.yaml`
- **内容**: 结构化日志配置、轮转策略

### 监控配置

- **文件**: `/etc/prometheus/prometheus.yml`
- **内容**: Prometheus 抓取配置

## 访问地址

- **trha**: http://localhost:8080
- **Prometheus**: http://localhost:9090
- **Grafana**: http://localhost:3000
- **Node Exporter**: http://localhost:9100

## 命令

### 服务管理

```bash
# 启动服务
systemctl start trha

# 停止服务
systemctl stop trha

# 重启服务
systemctl restart trha

# 查看状态
systemctl status trha

# 查看日志
journalctl -u trha -f
```

### 监控管理

```bash
# 查看 Prometheus 状态
systemctl status prometheus

# 查看 Grafana 状态
systemctl status grafana-server

# 查看 Node Exporter 状态
systemctl status node-exporter
```

### 日志管理

```bash
# 查看日志
tail -f /opt/trha/logs/trha.log

# 分析日志
/opt/trha/logs/analyze-logs.sh

# 检查错误
grep '"level": "ERROR"' /opt/trha/logs/*.log
```

## 故障排除

### 服务启动失败

```bash
# 查看服务状态
systemctl status trha

# 查看日志
journalctl -u trha -n 100

# 检查配置
cat /opt/trha/config/production.yaml
```

### 监控异常

```bash
# 查看 Prometheus 状态
systemctl status prometheus

# 查看 Grafana 状态
systemctl status grafana-server

# 检查端口占用
netstat -tulpn | grep -E "(9090|3000|9100)"
```

### 日志问题

```bash
# 检查日志目录权限
ls -la /opt/trha/logs/

# 检查日志文件大小
du -sh /opt/trha/logs/*.log

# 检查日志轮转
cat /etc/logrotate.d/trha
```

## 参考

- [systemd Documentation](https://www.freedesktop.org/software/systemd/man/)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [Node Exporter Documentation](https://prometheus.io/docs/guides/node-exporter/)