# Benchmark Scripts

用于性能测试和优化的脚本。

## 概述

这些脚本使用 llama.cpp 和 Qwen3.8-27B-GGUF 模型进行性能测试和优化。

## 脚本

| 脚本 | 文件 | 职责 |
|------|------|------|
| **model-benchmark.sh** | `model-benchmark.sh` | 模型基准测试 |
| **cache-optimization.sh** | `cache-optimization.sh` | 缓存优化测试 |

## 使用方法

### 模型基准测试

```bash
# 运行模型基准测试
./benchmarks/scripts/model-benchmark.sh
```

### 缓存优化测试

```bash
# 运行缓存优化测试
./benchmarks/scripts/cache-optimization.sh
```

## 测试内容

### 模型基准测试

1. **模型加载测试**：验证模型是否成功加载
2. **长文本生成测试**：测试长文本生成能力
3. **Token/s 性能测试**：测量每秒处理的 token 数量
4. **缓存性能测试**：测量缓存命中率

### 缓存优化测试

1. **不同上下文大小测试**：测试 2048、4096、8192 上下文大小
2. **不同线程数测试**：测试 4、8 线程配置
3. **Flash Attention 测试**：测试 Flash Attention 启用/禁用
4. **缓存命中率分析**：分析不同配置的缓存命中率

## 测试结果

### 模型基准测试结果

- **模型加载**：成功
- **长文本生成**：成功
- **Token/s**：待测量
- **缓存命中率**：待测量

### 缓存优化测试结果

- **最佳配置**：待确定
- **最佳缓存命中率**：待测量
- **最佳响应时间**：待测量

## 输出文件

### 模型基准测试

- `benchmarks/results/benchmark-report-*.md`：基准测试报告
- `benchmarks/results/llama-server.log`：服务器日志
- `benchmarks/results/long-text-output.txt`：长文本输出
- `benchmarks/results/avg-token-s.txt`：平均 Token/s
- `benchmarks/results/cache-hit-rate.txt`：缓存命中率

### 缓存优化测试

- `benchmarks/cache-optimization/cache-optimization-report-*.md`：优化报告
- `benchmarks/cache-optimization/cache-results.csv`：缓存结果
- `benchmarks/cache-optimization/best-config.txt`：最佳配置
- `benchmarks/cache-optimization/best-hit-rate.txt`：最佳命中率
- `benchmarks/cache-optimization/best-time.txt`：最佳响应时间

## 配置

### 模型路径

```bash
MODEL_PATH="/home/yanli/work/9060xt/models/Qwen3.8-27B-GGUF/Qwen3.8-27B-IQ3_M.gguf"
```

### llama.cpp 路径

```bash
LLAMA_CPP_PATH="/home/yanli/work/9060xt/llama-b1312-ubuntu-rocm-gfx120X-x64"
```

## 技术细节

### llama.cpp 配置

- **上下文大小**：4096 tokens
- **线程数**：8 threads
- **GPU 层**：999 layers (全部 GPU)
- **Flash Attention**：auto

### 测试方法

1. **模型加载测试**：检查 `/health` 端点
2. **长文本生成测试**：生成 1024 tokens 的长文本
3. **Token/s 测试**：测量多个提示的平均 Token/s
4. **缓存测试**：重复发送相同提示，测量缓存命中率

## 故障排除

### 模型加载失败

```bash
# 检查模型文件
ls -la /home/yanli/work/9060xt/models/Qwen3.8-27B-GGUF/

# 检查 llama.cpp
ls -la /home/yanli/work/9060xt/llama-b1312-ubuntu-rocm-gfx120X-x64/llama-server
```

### 服务器启动失败

```bash
# 检查服务器日志
cat benchmarks/results/llama-server.log

# 检查端口占用
netstat -tulpn | grep 8080
```

### 测试失败

```bash
# 检查测试输出
cat benchmarks/results/long-text-output.txt

# 检查服务器状态
curl http://localhost:8080/health
```

## 参考

- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [Qwen3.8-27B-GGUF](https://huggingface.co/Qwen/Qwen3.8-27B-GGUF)
- [ROCm](https://rocm.docs.amd.com/)