# trha Web

**独立客户端**（2026-10-27 定位，P-10）。

## 边界

- 只通过 HTTP + SSE 与 scheduler 通信（`/api/*`、`/api/events/:id`、`/v1/*` 透传）；
  不 import scheduler 内部模块，不读 `~/.trha`。
- 认证：`Authorization: Bearer <scheduler token>`；开发默认 `dev-token`。
- 端口由调用方决定（默认 `https://127.0.0.1:28433`）。

## 构建与测试

```bash
cd packages/app/Web
npm install
npm run typecheck
npm test          # vitest（stores / sse / columns / agents / turns）
npm run build     # 产物 dist/
```

CI 在 `.github/workflows/ci.yml` 的 `web` job 中执行同样四步（2026-10-27 加入）。

## 与 `/studio` 托管的关系

scheduler 的 `/studio` 路由仍可托管 `packages/app/Web/dist`（`export:studio`），
但那只是**开发便利**，不是 Web 的运行前提：Web 也可以独立部署，把 API 基址指向任意 scheduler。
