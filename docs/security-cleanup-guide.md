# Git 历史敏感信息清理指南

## 问题描述

API 密钥 `tp-cwa1hhqtypbyqyzk9ezz23usjfzk6575ddcq1s8gg3cc1042` 被提交到 Git 历史中。

**受影响的文件**：
- `scripts/benchmark/mimo-api-test.ts` (初始提交 `9af0c28`)
- `scripts/benchmark/mimo-api-test.sh` (初始提交 `9af0c28`)

## 清理方案

### 方案 1：使用 git-filter-repo（推荐）

```bash
# 安装 git-filter-repo
pip install git-filter-repo

# 备份仓库
cp -r /home/yanli/work/gh--harness /home/yanli/work/gh--harness-backup

# 创建替换文件
cat > /tmp/replacements.txt << 'EOF'
tp-cwa1hhqtypbyqyzk9ezz23usjfzk6575ddcq1s8gg3cc1042==>REMOVED_API_KEY
EOF

# 执行过滤
cd /home/yanli/work/gh--harness
git-filter-repo --replace-text /tmp/replacements.txt

# 强制推送
git push origin main --force
```

### 方案 2：使用 git filter-branch

```bash
cd /home/yanli/work/gh--harness

# 备份
cp -r . ../gh--harness-backup

# 执行过滤
git filter-branch --force --tree-filter '
if [ -f scripts/benchmark/mimo-api-test.ts ]; then
    sed -i "s/tp-cwa1hhqtypbyqyzk9ezz23usjfzk6575ddcq1s8gg3cc1042/REMOVED_API_KEY/g" scripts/benchmark/mimo-api-test.ts
fi
if [ -f scripts/benchmark/mimo-api-test.sh ]; then
    sed -i "s/tp-cwa1hhqtypbyqyzk9ezz23usjfzk6575ddcq1s8gg3cc1042/REMOVED_API_KEY/g" scripts/benchmark/mimo-api-test.sh
fi
' --tag-name-filter cat -- --all

# 强制推送
git push origin main --force
```

### 方案 3：使用 BFG Repo-Cleaner

```bash
# 下载 BFG
wget https://repo1.maven.org/maven2/com/madgag/bfg/1.14.0/bfg-1.14.0.jar

# 创建敏感信息文件
echo "tp-cwa1hhqtypbyqyzk9ezz23usjfzk6575ddcq1s8gg3cc1042" > /tmp/sensitive.txt

# 执行清理
java -jar bfg-1.14.0.jar --replace-text /tmp/sensitive.txt /home/yanli/work/gh--harness

# 清理引用
cd /home/yanli/work/gh--harness
git reflog expire --expire=now --all && git gc --prune=now --aggressive

# 强制推送
git push origin main --force
```

## 验证清理

```bash
# 检查历史中是否还有敏感信息
git log --all --oneline -- scripts/benchmark/mimo-api-test.ts scripts/benchmark/mimo-api-test.sh | while read commit; do
    echo "Checking $commit..."
    git show $commit:scripts/benchmark/mimo-api-test.ts 2>/dev/null | grep -c "tp-cwa1hhqtypbyqyzk9ezz23usjfzk6575ddcq1s8gg3cc1042" || true
    git show $commit:scripts/benchmark/mimo-api-test.sh 2>/dev/null | grep -c "tp-cwa1hhqtypbyqyzk9ezz23usjfzk6575ddcq1s8gg3cc1042" || true
done
```

## 安全建议

1. **立即轮换 API 密钥**：在 MIMO 平台轮换密钥
2. **使用环境变量**：所有敏感信息通过环境变量传递
3. **添加 .gitignore**：防止未来提交敏感文件
4. **使用 secrets 管理**：在 CI/CD 中使用 GitHub Secrets

## 风险警告

⚠️ **强制推送会重写历史**：
- 所有协作者需要重新克隆仓库
- 所有 PR 和 issue 链接可能失效
- 需要通知所有团队成员

## 参考

- [git-filter-repo](https://github.com/newren/git-filter-repos)
- [BFG Repo-Cleaner](https://rtyley.github.io/bfg-repo-cleaner/)
- [GitHub 文档](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)