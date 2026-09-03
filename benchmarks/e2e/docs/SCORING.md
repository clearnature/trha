# E2E 评分标准

## 分级标准

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

## 测试任务

### 基础功能

| 任务 | 描述 | 评分标准 |
|------|------|----------|
| `basic-chat` | 基本对话 | 响应相关性、延迟 |
| `basic-tool` | 基本工具调用 | 调用正确性、结果准确性 |
| `basic-session` | 基本会话管理 | 创建、查询、删除 |
| `basic-model` | 基本模型切换 | 切换成功、响应正常 |

### 高级功能

| 任务 | 描述 | 评分标准 |
|------|------|----------|
| `advanced-multi-turn` | 多轮对话 | 上下文保持、响应连贯性 |
| `advanced-parallel` | 并行任务 | 任务完成率、时间效率 |
| `advanced-subagent` | 子代理管理 | 创建、终止、状态同步 |
| `advanced-cache` | 缓存优化 | 命中率、响应时间 |

### 边界情况

| 任务 | 描述 | 评分标准 |
|------|------|----------|
| `edge-empty-input` | 空输入处理 | 错误处理、用户提示 |
| `edge-long-input` | 长输入处理 | 截断策略、响应质量 |
| `edge-concurrent` | 并发请求 | 线程安全、资源管理 |
| `edge-timeout` | 超时处理 | 超时检测、重试策略 |

## 总分计算

```python
def calculate_score(passed, total):
    """计算得分"""
    if total == 0:
        return 0
    return int(passed * 100 / total)
```

## 参考

- [DeepSeek-Reasonix E2E 测试](https://github.com/esengine/DeepSeek-Reasonix/tree/master/benchmarks/e2e)
- [SWE-Bench 评分标准](https://www.swebench.com/)