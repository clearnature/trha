# 基准测试设计文档

参考 DeepSeek-Reasonix 的基准测试架构，为 trha 设计完整的基准测试体系。

## 概述

trha 基准测试体系包含以下测试类型：

1. **E2E 测试**：端到端功能验证
2. **验证压力测试**：边界条件和错误处理
3. **内存基准测试**：内存使用和泄漏检测
4. **上下文维护测试**：长对话和上下文管理
5. **SWE-Bench**：软件工程基准测试

## 测试架构

```
benchmarks/
├── e2e/                    # 端到端测试
│   ├── tasks/              # 测试任务
│   │   ├── basic/          # 基础功能
│   │   ├── advanced/       # 高级功能
│   │   └── edge-cases/     # 边界情况
│   ├── docs/               # 测试文档
│   │   ├── SCORING.md      # 评分标准
│   │   └── TASKS.md        # 任务说明
│   └── verify.sh           # 验证脚本
├── verification-stress/    # 验证压力测试
│   ├── tasks/              # 测试任务
│   │   ├── positive/       # 正向测试
│   │   ├── negative/       # 负向测试
│   │   └── neutral/        # 中性测试
│   └── verify.sh           # 验证脚本
├── memorybench/            # 内存基准测试
│   ├── tasks/              # 测试任务
│   │   ├── allocation/     # 内存分配
│   │   ├── leak/           # 内存泄漏
│   │   └── gc/             # 垃圾回收
│   └── verify.sh           # 验证脚本
├── context-maintenance/    # 上下文维护测试
│   ├── tasks/              # 测试任务
│   │   ├── long-session/   # 长会话
│   │   ├── compaction/     # 压缩
│   │   └── recall/         # 召回
│   └── verify.sh           # 验证脚本
├── swebench/               # SWE-Bench 测试
│   ├── tasks/              # 测试任务
│   └── verify.sh           # 验证脚本
└── tests/                  # 单元测试
    ├── core/               # 核心模块测试
    ├── protocol/           # 协议模块测试
    ├── bridge/             # 桥接模块测试
    └── integration/        # 集成测试
```

## 1. E2E 测试

### 1.1 测试任务

#### 基础功能

| 任务 | 描述 | 评分标准 |
|------|------|----------|
| `basic-chat` | 基本对话 | 响应相关性、延迟 |
| `basic-tool` | 基本工具调用 | 调用正确性、结果准确性 |
| `basic-session` | 基本会话管理 | 创建、查询、删除 |
| `basic-model` | 基本模型切换 | 切换成功、响应正常 |

#### 高级功能

| 任务 | 描述 | 评分标准 |
|------|------|----------|
| `advanced-multi-turn` | 多轮对话 | 上下文保持、响应连贯性 |
| `advanced-parallel` | 并行任务 | 任务完成率、时间效率 |
| `advanced-subagent` | 子代理管理 | 创建、终止、状态同步 |
| `advanced-cache` | 缓存优化 | 命中率、响应时间 |

#### 边界情况

| 任务 | 描述 | 评分标准 |
|------|------|----------|
| `edge-empty-input` | 空输入处理 | 错误处理、用户提示 |
| `edge-long-input` | 长输入处理 | 截断策略、响应质量 |
| `edge-concurrent` | 并发请求 | 线程安全、资源管理 |
| `edge-timeout` | 超时处理 | 超时检测、重试策略 |

### 1.2 评分标准

```markdown
# E2E 评分标准

| 级别 | 得分 | 含义 |
|------|------|------|
| **L0 基础** | 20 分 | 功能可运行，无崩溃 |
| **L1 正确** | 40 分 | 功能正确，结果准确 |
| **L2 优化** | 70 分 | 性能优化，资源高效 |
| **L3 完美** | 100 分 | 边界处理完美，用户体验优秀 |

## 评分执行

- verify.sh 逐条断言，每条对应一个得分点
- 部分通过 = 按通过断言数 / 总断言数 × 100
- 功能正确但性能不达标 = 视为 L1（40 分），不判全对
```

## 2. 验证压力测试

### 2.1 测试分类

#### 正向测试 (Positive)

| 任务 | 描述 | 验证点 |
|------|------|--------|
| `vs-pos-chat` | 正常对话 | 响应正确性 |
| `vs-pos-tool` | 正常工具调用 | 调用正确性 |
| `vs-pos-session` | 正常会话管理 | 状态一致性 |

#### 负向测试 (Negative)

| 任务 | 描述 | 验证点 |
|------|------|--------|
| `vs-neg-invalid-input` | 无效输入 | 错误处理 |
| `vs-neg-missing-tool` | 缺失工具 | 优雅降级 |
| `vs-neg-timeout` | 超时场景 | 超时处理 |

#### 中性测试 (Neutral)

| 任务 | 描述 | 验证点 |
|------|------|--------|
| `vs-neu-unknown-command` | 未知命令 | 提示信息 |
| `vs-neu-empty-response` | 空响应 | 处理策略 |
| `vs-neu-large-context` | 大上下文 | 内存管理 |

### 2.2 验证脚本

```bash
#!/bin/bash
# 验证压力测试脚本

TASK_DIR="tasks"
SCORE=0
TOTAL=0

for task in "$TASK_DIR"/*/; do
    task_name=$(basename "$task")
    echo "Testing: $task_name"
    
    # 运行测试
    if bash "$task/verify.sh"; then
        SCORE=$((SCORE + 1))
    fi
    TOTAL=$((TOTAL + 1))
done

echo "Score: $SCORE/$TOTAL"
echo "Pass rate: $(echo "scale=2; $SCORE * 100 / $TOTAL" | bc)%"
```

## 3. 内存基准测试

### 3.1 测试任务

| 任务 | 描述 | 验证点 |
|------|------|--------|
| `mb-allocation` | 内存分配 | 分配速度、碎片率 |
| `mb-leak` | 内存泄漏 | 泄漏检测、自动回收 |
| `mb-gc` | 垃圾回收 | GC 频率、暂停时间 |
| `mb-stress` | 压力测试 | 高负载下的内存表现 |

### 3.2 验证指标

```markdown
# 内存基准指标

| 指标 | 目标 | 测量方法 |
|------|------|----------|
| 内存使用 | < 1GB | `ps aux` |
| 内存泄漏 | 0 | 连续运行 1 小时 |
| GC 暂停 | < 100ms | 日志分析 |
| 分配速度 | > 1MB/s | 基准测试 |
```

## 4. 上下文维护测试

### 4.1 测试任务

| 任务 | 描述 | 验证点 |
|------|------|--------|
| `cm-long-session` | 长会话 | 上下文保持、内存管理 |
| `cm-compaction` | 压缩 | 压缩策略、信息保留 |
| `cm-recall` | 召回 | 召回准确性、响应时间 |
| `cm-multi-session` | 多会话 | 会话隔离、资源管理 |

### 4.2 验证脚本

```go
// 上下文维护测试 (参考 DeepSeek-Reasonix)
package main

import (
    "context"
    "fmt"
    "time"
    
    "trha/internal/agent"
    "trha/internal/session"
)

const (
    windowTokens  = 1_000_000
    compactRatio  = 0.85
    defaultMaxUSD = 0.50
)

func main() {
    // 创建会话
    sess, err := session.Create("test-session")
    if err != nil {
        panic(err)
    }
    
    // 发送消息
    for i := 0; i < 1000; i++ {
        msg := fmt.Sprintf("Message %d", i)
        err := sess.SendMessage(msg)
        if err != nil {
            panic(err)
        }
    }
    
    // 验证上下文维护
    fmt.Println("Context maintenance test passed")
}
```

## 5. SWE-Bench 测试

### 5.1 测试任务

| 任务 | 描述 | 验证点 |
|------|------|--------|
| `swebench-bugfix` | Bug 修复 | 修复正确性、测试通过 |
| `swebench-refactor` | 代码重构 | 功能保持、代码质量 |
| `swebench-feature` | 功能实现 | 功能正确性、测试覆盖 |

### 5.2 验证脚本

```python
#!/usr/bin/env python3
# SWE-Bench 验证脚本

import json
import subprocess
import sys

def run_test(task_id):
    """运行 SWE-Bench 测试"""
    # 加载任务
    with open(f"tasks/{task_id}/task.json") as f:
        task = json.load(f)
    
    # 运行测试
    result = subprocess.run(
        ["bash", f"tasks/{task_id}/verify.sh"],
        capture_output=True,
        text=True
    )
    
    return result.returncode == 0

if __name__ == "__main__":
    # 运行所有测试
    tasks = ["bugfix-1", "refactor-1", "feature-1"]
    passed = 0
    
    for task in tasks:
        if run_test(task):
            passed += 1
            print(f"✓ {task}")
        else:
            print(f"✗ {task}")
    
    print(f"\nScore: {passed}/{len(tasks)}")
    print(f"Pass rate: {passed * 100 / len(tasks)}%")
```

## 6. 测试执行

### 6.1 运行所有测试

```bash
# 运行 E2E 测试
cd benchmarks/e2e
bash verify.sh

# 运行验证压力测试
cd benchmarks/verification-stress
bash verify.sh

# 运行内存基准测试
cd benchmarks/memorybench
bash verify.sh

# 运行上下文维护测试
cd benchmarks/context-maintenance
go run main.go

# 运行 SWE-Bench 测试
cd benchmarks/swebench
python3 select_subset.py
```

### 6.2 CI/CD 集成

```yaml
# .github/workflows/benchmarks.yml
name: Benchmarks

on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]

jobs:
  benchmark:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Run E2E tests
        run: |
          cd benchmarks/e2e
          bash verify.sh
      
      - name: Run verification stress tests
        run: |
          cd benchmarks/verification-stress
          bash verify.sh
      
      - name: Run memory benchmarks
        run: |
          cd benchmarks/memorybench
          bash verify.sh
      
      - name: Run context maintenance tests
        run: |
          cd benchmarks/context-maintenance
          go run main.go
      
      - name: Run SWE-Bench tests
        run: |
          cd benchmarks/swebench
          python3 select_subset.py
```

## 7. 评分系统

### 7.1 评分标准

| 测试类型 | 满分 | 评分维度 |
|---------|------|----------|
| E2E 测试 | 100 | 功能正确性、性能、用户体验 |
| 验证压力测试 | 100 | 边界处理、错误恢复、稳定性 |
| 内存基准测试 | 100 | 内存使用、泄漏检测、GC 效率 |
| 上下文维护测试 | 100 | 上下文保持、压缩效率、召回准确性 |
| SWE-Bench 测试 | 100 | Bug 修复、代码质量、测试覆盖 |

### 7.2 总分计算

```python
def calculate_total_score(scores):
    """计算总分"""
    weights = {
        'e2e': 0.3,
        'verification': 0.2,
        'memory': 0.2,
        'context': 0.2,
        'swebench': 0.1
    }
    
    total = 0
    for test_type, score in scores.items():
        total += score * weights.get(test_type, 0)
    
    return total
```

## 8. 参考

- [DeepSeek-Reasonix Benchmarks](https://github.com/esengine/DeepSeek-Reasonix/tree/master/benchmarks)
- [SWE-Bench](https://www.swebench.com/)
- [E2E Testing Best Practices](https://www.cypress.io/blog/2019/01/03/when-to-use-a-complex-or-simple-test/)