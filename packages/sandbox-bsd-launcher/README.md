# trha-sandbox-bsd-launcher

FreeBSD (capsicum) and OpenBSD (pledge/unveil) launchers for trha's sandbox.

One source (`launcher.c`), two binaries:

| 二进制 | 平台 | 机制 |
|---|---|---|
| `trha-sandbox-bsd` | FreeBSD | 预开 writable 目录的 fd → `cap_rights_limit` → `cap_enter()` |
| `trha-sandbox-obsd` | OpenBSD | 逐条 `unveil(path, perms)` → `unveil(NULL,NULL)` 锁定 → `pledge(promises)` |

在其它平台上编译出来的是**拒绝执行**的 stub（exit 126）：一个无法执行自身平台边界的 launcher 不能退化成透传。

## 契约（Haskell 渲染器 → launcher）

argv 形状由 `Infrastructure.Sandbox.Backend.{FreeBSD,OpenBSD}` 产生，
并由 `test/SandboxBsdSpec.hs` 的黄金测试逐字锁定：

```
# FreeBSD (Backend/FreeBSD.hs)
trha-sandbox-bsd --workspace WS --scratch S --policy P --network N -- ARGV...

# OpenBSD (Backend/OpenBSD.hs)：pledge 与 unveil 是语义化的，便于断言
trha-sandbox-obsd --pledge "stdio rpath wpath cpath proc exec inet" \
                  --unveil WS:rw --unveil S:rw \
                  --unveil /etc:r --unveil /usr:r --unveil /bin:r --unveil /sbin:r \
                  -- ARGV...
```

`P` ∈ `read-only | workspace-write`；`N` ∈ `off | allow:domains | proxy:url`。
两边改任何一侧都要同时更新 `SandboxBsdSpec` 与 `smoke.sh`。

## 验证

```sh
make            # 编译两个二进制（非 BSD 上是 stub）
make syntax     # 只做 -fsyntax-only，不需要链接
make check      # smoke：两种 argv 形状 + 拒绝透传 + 畸形参数
```

`make check` 在任何主机上都能跑：`--dry-run` 打印解析结果而不执行命令，
所以 Linux 上也能核对渲染器输出的形状。

## 已知限制（未在真机验证）

- **没有任何一步在 FreeBSD/OpenBSD 真机上跑过**。capsicum 与 pledge 分支只经过
  `-fsyntax-only` 与代码审阅；真机验收需要 T5.4 的 VM CI（或一台 BSD）。
- capsicum 限制的是**已开 fd 的 capability**，不是路径：`cap_rights_limit` 之后
  子进程仍能对预开的目录做该 fd 允许的一切。所以 Haskell 侧把 FreeBSD 的
  `enforcement` 如实标为 `Partial`。
- pledge 过滤的是**系统调用类**，不是路径；路径边界靠 unveil。两者都不提供
  资源配额（那需要 rctl / login class），所以 OpenBSD 同样是 `Partial`。
- capsicum 分支把预开的目录 fd 留在子进程里（它是唯一的可写句柄），但没有把
  路径信息传下去——真正的读写要靠子进程通过这个 fd 操作，或在 launcher 里
  再 `dup` 到约定编号。这一点需要在真机上定案。
