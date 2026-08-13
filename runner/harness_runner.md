---
type: harness-runner-guide
status: active
created: 2026-07-17
updated: 2026-07-17
---

# Runner 使用说明

`harness_runner.ps1` 默认是 route-only 入口，也可显式进入受监督 Worker 模式：

1. 读取 [[00-系统/项目注册表]]；
2. 合并本项目能力配置并生成 JSON 运行镜像；
3. 解析自然语言需求；
4. 创建 TaskContract、原始输入和 Ledger 事件；
5. 用 JSON Schema 验证合同；
6. 返回路由、等待澄清或等待审批状态；
7. `-ExecutionMode Supervised` 时快照材料和最小项目上下文，生成可检查的 Worker 包；主 Runner 不提供直接执行开关。

示例：

```powershell
pwsh -File .\10-项目\Hermes-Harness\runner\harness_runner.ps1 `
  -Request "使用已核验资料制作法国对西班牙90秒短视频平台视频草稿" `
  -AsJson
```

测试：

```powershell
Invoke-Pester -Script .\10-项目\Hermes-Harness\tests\HermesHarness.Tests.ps1
```

受监督准备示例：

```powershell
pwsh -File .\10-项目\Hermes-Harness\runner\harness_runner.ps1 `
  -Request "根据已提供资料制作法国对西班牙90秒短视频平台视频草稿" `
  -ExecutionMode Supervised `
  -MaterialPath "C:\path\match-brief.md"
```

准备完成后使用 `runner/codex_worker.ps1 -ContractPath ... -ApproveExecution` 从同一任务恢复。自定义 `-RuntimeRoot` 时，恢复入口必须传入同一个根目录；路径、任务ID、合同和不可变包任一不一致都会失败关闭。该流程不把 `routed` 冒充为完成。Worker 接入规则见 [[10-项目/Hermes-Harness/adapters/codex|Codex 适配器]]。

已路由的内容审计只读审查使用独立恢复入口：

```powershell
pwsh -File .\10-项目\Hermes-Harness\runner\content_audit_worker.ps1 `
  -ContractPath ".\10-项目\Hermes-Harness\runtime\tasks\<task_id>\contract.json" `
  -AsJson
```

该入口只接受恰好各出现一次的 `content_audit + content_distribution + analyze`，会复算当前机器注册表的项目路径，并且只在同一任务目录写审查报告和回执。公共参数只有 `ContractPath` 和输出格式；运行目录、注册表及 Schema 路径由 Harness 根目录固定，不能由调用方覆盖。

返回：[[10-项目/Hermes-Harness/README|Hermes Harness]]。
