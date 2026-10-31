# trha Benchmarks & Smoke Tests

全量冒烟测试和性能基准测试。

## 概述

本目录包含 trha 项目的全量冒烟测试和性能基准测试，覆盖所有核心模块的功能和函数。

## 测试范围

### 核心模块测试

| 模块 | 测试文件 | 覆盖内容 |
|------|----------|----------|
| **Core** | `tests/core.test.ts` | SchedulerClient, Logger, Retry, PluginManager, ParallelScheduler, SubAgentManager, EventEmitter, Queue |
| **Protocol** | `tests/protocol.test.ts` | ProtocolHandler, SessionManager, ErrorHandler, ResourcePool |
| **Bridge** | `tests/bridge.test.ts` | HaskellBridge |

### 测试类型

| 类型 | 描述 | 覆盖范围 |
|------|------|----------|
| **单元测试** | 测试每个函数的输入输出 | 所有公开函数 |
| **集成测试** | 测试模块之间的集成 | 核心模块交互 |
| **端到端测试** | 测试完整的业务流程 | 关键业务路径 |

## 测试框架

- **框架**: vitest
- **覆盖率**: v8
- **报告**: JSON, HTML

## 运行测试

### 安装依赖

```bash
cd benchmarks
npm install
```

### 运行所有测试

```bash
npm test
```

### 运行测试并生成覆盖率报告

```bash
npm run test:coverage
```

### 运行测试并生成 JSON 报告

```bash
npm run test:report
```

### 监听模式

```bash
npm run test:watch
```

## 测试报告

### JSON 报告

- **位置**: `results/test-results.json`
- **格式**: JSON
- **内容**: 测试结果、覆盖率、错误信息

### HTML 报告

- **位置**: `coverage/index.html`
- **格式**: HTML
- **内容**: 可视化覆盖率报告

### Markdown 报告

- **位置**: `results/test-report.md`
- **格式**: Markdown
- **内容**: 测试总结、覆盖率统计

## 测试用例

### Core 模块测试

1. **SchedulerClient**
   - 创建客户端（默认配置）
   - 创建客户端（自定义配置）

2. **Logger**
   - 创建日志器
   - 记录日志消息

3. **Retry**
   - 默认配置
   - 失败重试

4. **PluginManager**
   - 注册插件
   - 注销插件
   - 发送事件

5. **ParallelScheduler**
   - 并行执行任务
   - 流水线处理
   - MapReduce 模式

6. **SubAgentManager**
   - 创建子代理
   - 终止子代理
   - 更新状态

7. **EventEmitter**
   - 发送和监听事件
   - 一次性监听器

8. **Queue**
   - 入队和出队
   - 查看队首

### Protocol 模块测试

1. **ProtocolHandler**
   - 创建请求消息
   - 创建响应消息
   - 创建事件消息
   - 创建错误消息
   - 处理请求

2. **SessionManager**
   - 创建会话
   - 添加消息
   - 完成会话
   - 获取会话摘要
   - 列出会话

3. **ErrorHandler**
   - 分类超时错误
   - 分类连接错误
   - 分类验证错误
   - 提供重试延迟
   - 跟踪统计

4. **ResourcePool**
   - 获取资源
   - 释放资源
   - 跟踪统计
   - 按类型获取

### Bridge 模块测试

1. **HaskellBridge**
   - 创建桥接
   - 查询模型方法
   - 验证类型方法
   - 缓存查找方法
   - 缓存插入方法

## CI/CD 集成

### GitHub Actions

```yaml
name: Smoke Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-node@v3
        with:
          node-version: '18'
      - run: cd benchmarks && npm install
      - run: cd benchmarks && npm test
      - run: cd benchmarks && npm run test:coverage
```

## 故障排除

### 测试失败

```bash
# 查看详细错误
npm test -- --reporter=verbose

# 运行特定测试
npm test -- -t "SchedulerClient"
```

### 覆盖率不足

```bash
# 查看覆盖率报告
npm run test:coverage
open coverage/index.html
```

### 依赖问题

```bash
# 清理并重新安装
rm -rf node_modules package-lock.json
npm install
```

## 参考

- [vitest Documentation](https://vitest.dev/)
- [vitest Coverage](https://vitest.dev/guide/coverage.html)
- [GitHub Actions](https://docs.github.com/en/actions)