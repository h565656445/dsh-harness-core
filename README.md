# dsh-harness-core

<!-- DeepSeek Harness 衍生声明 -->
> **DeepSeek Harness 个人适配声明（Personal Adaptation Notice）**
>
> 本项目是 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的**个人适配产物（personal adaptation）**，**并非 DeepSeek Harness 官方文件（not an official DeepSeek Harness file）**。随附功能、使用说明与个人产物，可与 DeepSeek Harness 搭配使用，也可独立使用。
>
> This project is a **personal adaptation** for DeepSeek Harness, and is **NOT an official DeepSeek Harness file**. It is bundled with features, documentation, and personal artifacts, and can be used alongside DeepSeek Harness or standalone.

**作者 / Author**: [h565656445](https://github.com/h565656445)

**合作 / Collaboration**: 如有项目可以一起合作，欢迎联系。微信：`wohaishihenshuaide`。If you have projects, let's collaborate. WeChat: `wohaishihenshuaide`.


---

## 用途 / What this is for

Hermes Harness 核心控制平面：任务契约、路由解析、安全门禁、受监督 Worker 与证据闭环的模块总装。

Hermes Harness core control plane: task contract, routing, safety gates, supervised worker and evidence closure.

---
## Hermes Harness Core Control Plane / Hermes Harness 核心控制平面

本仓库是 Hermes Harness 的核心控制平面：`HermesHarness.psm1` 承载任务契约（TaskContract）、路由解析、质量门禁与 Ledger 证据闭环；`harness_runner.ps1` 是 route-only 入口，也可显式进入受监督 Worker 模式；`core/` 文档定义核心职责、权限边界、质量门禁、路由规则与任务契约；配套配置（capabilities / task types）与 `task_contract.schema.json` 约束机器格式。

This repository is the core control plane of Hermes Harness: `HermesHarness.psm1` implements the task contract (TaskContract), routing, quality gates, and the Ledger evidence loop; `harness_runner.ps1` is the route-only entrypoint that can also enter supervised Worker mode; the `core/` docs define responsibilities, permission boundaries, quality gates, routing rules and the task contract; config (capabilities / task types) and `task_contract.schema.json` pin the machine format.

## Features / 功能

- 任务契约：`New-HarnessTask` 生成经 JSON Schema 校验的 TaskContract 与原始输入 / `New-HarnessTask` creates JSON-Schema-validated task contracts with raw inputs
- 路由解析：`Resolve-HarnessRoutes` 按注册表投影解析 domains/actions/channels / `Resolve-HarnessRoutes` resolves domains/actions/channels from the registry projection
- 安全门禁：`Assert-HarnessRequestSafe` 在持久化前拒绝凭据类内容 / `Assert-HarnessRequestSafe` rejects credential-like content before persistence
- 受监督 Worker：`New-HarnessCodexWorkerPackage` 生成不可变任务包并校验结果 / `New-HarnessCodexWorkerPackage` builds immutable worker packages and validates results
- 证据闭环：`Write-HarnessLedgerEvent` 追加只写 Ledger 事件，全流程可审计 / `Write-HarnessLedgerEvent` appends to the append-only Ledger for a fully auditable loop
- 双测试套件：`HermesHarness.Tests.ps1` 与 `HarnessConvergence.Tests.ps1` / Two Pester suites: core behavior and harness convergence

## What's inside / 目录结构

```
dsh-harness-core/
├── README.md                 # 双语说明
├── LICENSE                   # MIT
├── src/HermesHarness.psm1    # 核心控制平面模块
├── runner/harness_runner.ps1 # route-only / 受监督 Worker 入口
├── runner/harness_runner.md  # Runner 使用说明
├── core/                     # core / permissions / quality_gates / router_rules / task_contract
├── config/                   # project_capabilities.json / task_types.json
├── schemas/task_contract.schema.json
├── tests/                    # HermesHarness.Tests.ps1 / HarnessConvergence.Tests.ps1
└── .dsh/                     # DeepSeek Harness 衍生包
```

## Quick start / 快速开始

```powershell
# 运行回归测试（PowerShell 7 + Pester）
pwsh -NoProfile -Command "Invoke-Pester -Path .\tests"

# route-only 模式创建任务（Request 为自然语言需求）
pwsh -NoProfile -ExecutionPolicy Bypass -File .\runner\harness_runner.ps1 -Request "查询知识库" -RuntimeRoot .\runtime

# 直接加载模块
Import-Module .\src\HermesHarness.psm1 -Force
```

## DeepSeek Harness 衍生 / DSH Derivative

本项目附带 DeepSeek Harness 衍生包，位于 `.dsh/` 目录：

- `preset.yml` — Agent 预设元数据
- `agent.cordis.yml` — Cordis 组装（基于 standard 预设，persona 已定制）
- `skills/dsh-harness-core/SKILL.md` — 项目专属技能（skill）

安装与接入方式见 [`.dsh/README.md`](.dsh/README.md)（双语）。

## License / 许可证

[MIT](LICENSE)