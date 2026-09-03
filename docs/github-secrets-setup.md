# GitHub Secrets 设置指南

## 概述

为了安全地管理 API 密钥和敏感信息，我们使用 GitHub Secrets 来存储这些值。

## 设置步骤

### 1. 访问 GitHub Secrets

1. 打开你的 GitHub 仓库：https://github.com/clearnature/gh--harness
2. 点击 **Settings** 选项卡
3. 在左侧菜单中，点击 **Secrets and variables** → **Actions**
4. 点击 **New repository secret**

### 2. 添加 Secrets

#### MIMO API 密钥
- **Name**: `MIMO_API_KEY`
- **Value**: 你的 MIMO API 密钥
- **Description**: MIMO API 密钥用于基准测试

#### DeepSeek API 密钥
- **Name**: `DEEPSEEK_API_KEY`
- **Value**: 你的 DeepSeek API 密钥
- **Description**: DeepSeek API 密钥

#### OpenAI API 密钥
- **Name**: `OPENAI_API_KEY`
- **Value**: 你的 OpenAI API 密钥
- **Description**: OpenAI API 密钥

### 3. 在 CI/CD 中使用 Secrets

在 GitHub Actions 工作流中，你可以这样使用 secrets：

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Run tests
        env:
          MIMO_API_KEY: ${{ secrets.MIMO_API_KEY }}
          DEEPSEEK_API_KEY: ${{ secrets.DEEPSEEK_API_KEY }}
        run: |
          npm test
```

### 4. 在本地开发中使用 Secrets

在本地开发时，你可以创建一个 `.env` 文件：

```bash
# 复制示例文件
cp .env.example .env

# 编辑 .env 文件，填入你的 API 密钥
MIMO_API_KEY=your-mimo-api-key-here
DEEPSEEK_API_KEY=your-deepseek-api-key-here
```

**注意**：`.env` 文件已被添加到 `.gitignore`，不会被提交到 Git。

### 5. 验证 Secrets 设置

在 GitHub Actions 中，你可以验证 secrets 是否正确设置：

```yaml
- name: Verify secrets
  run: |
    if [ -z "$MIMO_API_KEY" ]; then
      echo "MIMO_API_KEY is not set"
      exit 1
    fi
    echo "MIMO_API_KEY is set"
```

## 安全最佳实践

### 1. 最小权限原则
- 只授予必要的权限
- 定期轮换 API 密钥
- 使用不同的密钥用于不同的环境

### 2. 密钥轮换
- 定期轮换 API 密钥（建议每 90 天）
- 在轮换后立即更新 GitHub Secrets
- 监控 API 使用情况

### 3. 访问控制
- 限制谁可以访问 secrets
- 使用环境特定的 secrets
- 审计 secrets 访问日志

### 4. 监控和警报
- 监控 API 使用情况
- 设置异常使用警报
- 定期审查 secrets 使用情况

## 故障排除

### Secret 未设置
如果 CI/CD 失败并显示 "secret not found"：
1. 检查 secret 名称是否正确
2. 确认 secret 已在 GitHub 中设置
3. 检查工作流文件中的引用是否正确

### Secret 值不正确
如果 API 调用失败：
1. 验证 secret 值是否正确
2. 检查 API 密钥是否已过期
3. 确认 API 密钥有足够的权限

### 环境变量未传递
如果环境变量未传递到测试：
1. 检查工作流文件中的 `env` 部分
2. 确认变量名称正确
3. 验证变量值是否已设置

## 参考

- [GitHub Secrets 文档](https://docs.github.com/en/actions/security-guides/encrypted-secrets)
- [GitHub Actions 环境变量](https://docs.github.com/en/actions/learn-github-actions/variables)
- [安全最佳实践](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions)