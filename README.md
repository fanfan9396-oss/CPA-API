# CPA + New API 中转站

本仓库保存本地集成环境、Mock 上游和验收工具。CPA 与 New API 以 Git 子模块引用；每个生产发布固定到可追溯的 SHA，开发和更新可以继续推进，但生产不会跟随 `latest` 自动漂移。

## 固定上游版本

- CLIProxyAPI (`CLIProxyAPI-main`): `555662940411a07460e9d24d14477a5f50dffdb5`
- New API (`new-api-main`): `8406a722a5ec89433cc1e98e1ad633796c1b40bb`（`fanfan9396-oss/new-api` fork；当前生产发布基线）

CPA 当前版本与原本下载的源码包逐文件核对一致。New API 先固定在上游基线后，为本项目 Wallet Hard Cap 阶段建立了 fork 分支 `wallet-hard-cap`；当前 gitlink 固定在上述 fork commit。更新任一版本时，请更新子模块指针、生成完整发布包、重新构建并运行 Staging 验收；服务器只拉取带 SHA-256 清单的指定发布包，不直接跟随可变的 `main` 或 `latest`。

New API fork 当前包含钱包硬上限、CNY-to-USD quota、充值回调强化、密码重置 Token 一次性消费修复和对应测试：关闭 wallet funding 的 trust bypass；正差额结算统一走原子 user-wallet reserve；余额不足拒绝而不形成负钱包；tiered/top-up 负债测试改为拒绝，并新增多 unlimited key 共用 wallet 的测试。

## 获取源码

克隆本仓库时初始化子模块：

```powershell
git clone --recurse-submodules https://github.com/fanfan9396-oss/CPA-API.git
```

如已普通克隆：

```powershell
git submodule update --init --recursive
```

## 本地集成环境

需要 Docker Desktop 和 Docker Compose。首次运行时：

```powershell
Copy-Item .env.integration.example .env.integration
Copy-Item runtime/cpa/config.example.yaml runtime/cpa/config.yaml
```

在 `.env.integration` 和 `runtime/cpa/config.yaml` 中替换示例值，确保 CPA 的 `api-keys` 与 `CPA_API_KEY` 一致。不要把这两个实际配置文件或任何 OAuth 文件提交到 Git。成员 New API client key 与 CPA provider credentials 分离；不要把 CPA 管理 key/provider key 发给成员。

启动：

```powershell
docker compose --env-file .env.integration -f docker-compose.integration.yml up -d --build
```

本地入口仅绑定回环地址：

- New API: `http://localhost:3000`
- CPA: `http://localhost:8317`
- Mock 上游诊断入口: `http://localhost:18080`

容器间流量走 Compose 内部网络。当前测试链路为：

```text
Client -> New API -> CPA -> Mock OpenAI upstream
```

Mock 上游继续用于可重复验证普通/流式响应、鉴权、计费、错误、重试和超时。2026-09-27 已用一份获授权的 Free OAuth 在本地及私有原生 Staging 完成 CPA 与 New API 非流/流式真实请求和 usage/Wallet 结算验证；这不代表 Plus/Pro 权益、OAuth 刷新/过期、DeepSeek 或生产商业授权已通过。

## 验收

常规集成验收（需传入 New API 客户端 API Key）：

```powershell
./tools/verify-integration.ps1 -ClientApiKey "<New API client key>"
```

超时场景单独执行；脚本会临时重建 New API，并在结束时恢复默认环境配置：

```powershell
./tools/verify-timeout.ps1 -ClientApiKey "<New API client key>"
```

历史常规验收记录为 14 项通过、超时验收通过；当前测试 Staging 已完成 `api.20280810.xyz` HTTPS、服务器页面/权限和 Web 分批回归。真实支付、Plus/Pro/DeepSeek、商业授权、远程监控/异地备份和公开注册生产防护仍未完成。

## Web 稳定测试

Windows 低内存环境建议使用串行 Vitest，避免大量 jsdom worker 并行导致 Node 内存不足：

```powershell
cd new-api-main/web
$env:NODE_OPTIONS="--max-old-space-size=4096"
bun run test:stable
```

`test:stable` 只限制测试执行并发，不改变业务代码；资源充足的 CI 可继续使用默认 `bun run test`。
## 备份

备份包含 PostgreSQL 数据库、Redis RDB、CPA 配置和可能的认证材料，必须显式确认后运行：

```powershell
./tools/backup-local.ps1 -ConfirmBackup
```

备份写入 `runtime/backups/`，该目录已忽略，不会提交。备份文件按敏感数据保管。

## 不要提交的本地数据

`.gitignore` 排除了实际 `.env.integration`、`runtime/cpa/config.yaml`、OAuth 文件、数据库数据、日志、备份、Playwright 输出及 ZIP 源包。提交前仍需检查 `git status` 和 staged 文件清单；忽略规则不能替代历史检查。

## 生产上线前

1. 接入你有权使用的有效 OAuth/API 凭证。
2. 验证真实模型、刷新、账号切换、usage 和计费。
3. 设置正式价格、HTTPS、域名、管理员凭证与 Secret 管理。
4. 演练 PostgreSQL 备份/恢复，确认 Redis 持久化和监控方案。
5. 完成权限、错误、页面操作和发布回滚验收。

当前配置是本地集成/测试环境，不应直接暴露到公网。


### 恢复演练

对已生成的敏感备份执行一次隔离恢复检查；脚本会创建临时数据库、恢复 PostgreSQL dump、检查公开表和用户表，并校验 Redis RDB 快照，然后默认删除临时数据库：

```powershell
./tools/restore-drill.ps1 -BackupDirectory "./runtime/backups/<backup-folder>"
```

需要保留临时数据库进行人工检查时才使用 `-KeepDatabase`，检查完成后应手动删除。该演练不替换正式灾备方案，也不会验证真实 OAuth/provider 凭据。备份脚本会同时生成敏感的 `redis.rdb`，请与 PostgreSQL dump 一样保护。

### 本地运维准备检查

检查本地服务、健康入口、支付回调拒绝、应用端口、备份新鲜度和私密路径边界；只读，不修改配置：

```powershell
./tools/check-ops-readiness.ps1 -RequireFreshBackup -MaxBackupAgeHours 48
```

需要机器可读结果时加 `-Json`。

### 本地准备检查

在运行本地验收前，可执行只读准备检查；它不会修改注册设置、密码、数据库或凭据：

```powershell
./tools/check-local-readiness.ps1
```

如要把“邀请制必须已关闭注册”作为强制门禁，使用 `-RequireInviteMode`。

