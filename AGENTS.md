# AGENTS.md

任何时候使用中文，除非用户明确要求英文。

## 项目阶段与真源

本仓库是半路接管项目，不是空项目。以代码、配置、运行态、Git 与内部文档共同确认当前事实；历史记录不完整时标为回填或未验证，不补造原始过程。

- 内部真源索引：`dev-docs/README.md`。
- 产品目标、第一闭环、MVP 和非目标：`dev-docs/project-brief.md`。
- 按日期记录决定、代码变化与验收事件：`dev-docs/project-log.md`；只追加事件和引用，不复制其他文档内容。
- 当前运行/Git/风险证据：`dev-docs/current-state-audit.md`。
- 技术取舍：`dev-docs/technical-selection.md`；当前架构 owner：`dev-docs/architecture.md`；验收：`dev-docs/acceptance.md`。
- `dev-docs/` 被根 `.gitignore` 排除，默认本地私有。不得为提交而强行添加内部资料；公开 README 与内部开发真源分开。
- 项目当前流程：运营方在 CPA 管理 provider credentials；New API 管理渠道和用户；成员创建自己的 New API client key。New API key 与 CPA 管理/provider 凭据不是同一种凭据。
- New API 用户钱包/订阅余额、成员自助充值订单/支付状态、单个 token 的 `UnlimitedQuota`、共享 provider pool 额度及运营商账单是不同语义。按 `project-brief.md` 中已确认/待确认项执行，不能从字段名代替产品决策。支付成功只能由经过验证且幂等的服务端回调入账。
- 当前实现版本与证据以固定子模块 SHA、运行代码及记录日期为准；此前成员自带 provider OAuth/API Key 的方案已被用户纠正并标记为 superseded。

## 开发规则

- 架构优先、设计优先、真源优先、严格验收。先找唯一 owner 和最近消费者，做最小修改；不重写已有上游，不创造重复业务 owner。
- 当前事实足以支持沿用才沿用；涉及框架、SDK、schema、auth、部署或 owner 边界变化时，先做有证据的决策并确认可见影响、成本、停机/迁移风险。
- 用户决定产品可见结果、费用和不可逆影响；AI 决定技术路线并说明依据。一个关键产品未知阻塞时，一次询问一个决定性问题，不自行推测。
- 普通局部任务窄查窄改；若触及身份、权限、数据、支付/额度、provider、安全、生产或隐私边界，按对应 Sliver lens/门禁扩展。

## 安全红线

- 前端输入不可信；身份、角色、owner、额度、model/group permissions、状态和写入字段必须由服务端校验。
- 成员只能读写/撤销自己的 New API client keys；CPA 管理 API、provider credentials 和 auth files 仅供获授权运营管理员使用。
- 密钥（API key、OAuth token、CPA auth 文件、provider secret）、数据库数据不得写入源码、文档、日志、错误、截图或 Git 历史。验证材料先脱敏，绝不回显秘密。
- 创建/更新 New API token 时，不得信任客户端提交的 `unlimited_quota`、quota、group 或 model-limit 字段；服务端必须强制执行已经确认的用户/运营策略。
- 自助充值时不得信任客户端“支付成功”、金额、quota 换算或订单状态；服务端必须验证网关签名、订单归属、金额、状态转换和幂等性。
- 安全审计不等于修复授权；没有安全验证证据不得声称安全或可以上线，缺失证据必须标记未验证。
- 未经确认，不轮换真实凭据、不更改权限/额度、不向团队或公网开放服务。

## 测试与验证

- 实现改动前先完成测试门禁分类，并复用能证明目标行为的真实 owner 测试。
- 稳定可自动化的行为变更遵循测试策略，适用时先 RED 再 GREEN；不为仪式新增无关测试。
- mock 只证明模拟链路，不代表真实 provider；零测试、旧日志或无关绿色测试都不构成验收。
- 每次结束记录 fresh verification 的命令和结果；没有新鲜验证就不声称完成。
## Git、隐私和交付

- 提交前审阅 Git root、`git status --short`、ignored/secret 文件、完整候选文件清单与历史边界。
- 禁止 `git add .`；只暂存审查过的明确路径。
- 公开仓库不得包含实际 `.env`、CPA auth/provider credentials、数据库、日志、备份、ZIP 上游源码或未授权内部文档。
- `.gitignore` 不会清理既有 Git 历史。历史改写、删除、push、publish、deploy 或 production action 必须先明确目标、影响、恢复办法并获得针对该动作的授权。
- 默认不提交、不推送。不得绕过 GitHub secret scanning。

## 危险接管动作

以下行为必须先说明影响并取得明确确认：修改本 `AGENTS.md` 或其他长期 agent 规则；更改产品范围/收费/充值/额度；改上游子模块或 schema；轮换/迁移真实凭据；删除或移动既有备份/历史；改变公开仓库、Git 历史、外部可达性、生产部署或用户数据。

## 停止条件

- 支付渠道/主体、价格/换算、退款/拒付、user wallet 资金来源、API token cap、共享 provider pool、超额/计费政策未确认且会改变用户花费或运营成本时，停止对应实现，先询问一个决定性问题。
- 发现自助请求能授予无限额度或超越管理员模型/分组策略，而服务端拒绝负例未通过时，不向团队或公网开放。
- 缺少有效 provider credentials 时停止真实 provider 验收，不用 mock 替代。
- 同一问题连续三次修复失败时，停止局部补丁，重审 owner、架构与真源。

## 交接

换窗口、阶段未闭合或交由他人继续时，在 `dev-docs/project-log.md` 追加一条日期事件：项目路径、分支/HEAD/工作区、实际改动、fresh verification、未验证项、风险和下一步。绝不记录密钥。
