# CPA + New API 中转站

本仓库保存本地集成环境、Mock 上游和验收工具。CPA 与 New API 以固定版本 Git 子模块引用，避免把上游源码副本及其中的第三方 OAuth 客户端常量再次复制进本仓库历史。

## 固定上游版本

- CLIProxyAPI (`CLIProxyAPI-main`): `555662940411a07460e9d24d14477a5f50dffdb5`
- New API (`new-api-main`): `996adffe5165bd5e311e33a03a86b8aede1fe376`

两个固定版本与原本下载的源码包逐文件核对一致。更新上游版本时，请更新子模块指针、重新构建并运行验收，不要直接跟随可变的 `main` 或 `latest`。

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

在 `.env.integration` 和 `runtime/cpa/config.yaml` 中替换示例值，确保 CPA 的 `api-keys` 与 `CPA_API_KEY` 一致。不要把这两个实际配置文件或任何 OAuth 文件提交到 Git。

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

当前没有有效 OAuth，因此 Mock 上游用于验证普通/流式响应、鉴权、计费、错误、重试和超时；它不代表真实供应商验收。

## 验收

常规集成验收（需传入 New API 客户端 API Key）：

```powershell
./tools/verify-integration.ps1 -ClientApiKey "<New API client key>"
```

超时场景单独执行；脚本会临时重建 New API，并在结束时恢复默认环境配置：

```powershell
./tools/verify-timeout.ps1 -ClientApiKey "<New API client key>"
```

本地最近一次记录为常规验收 14 项通过、超时验收通过。真实 OAuth、真实上游账号轮询/刷新、生产域名/TLS、备份恢复演练和完整页面交互仍未全部验收。

## 备份

备份包含数据库和可能的认证材料，必须显式确认后运行：

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
