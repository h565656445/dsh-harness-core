---
type: harness-task-contract
status: active
created: 2026-07-17
updated: 2026-07-17
---

# TaskContract

每个任务在执行前必须生成独立合同，机器格式由 `schemas/task_contract.schema.json` 约束。

核心字段：

- 原始需求、目标和创建时间；
- 输入材料的原路径、任务内快照路径、SHA-256 与 `provided/verified` 状态；
- 业务域、动作、渠道、置信度、证据与未知项；
- 路由步骤、项目根目录和项目记忆入口；
- 交付物、验收条件和明确约束；
- 权限状态与待批准动作；
- 最大尝试、修正和无进展限制。

TaskContract 是工作订单，不是执行结果。`routed` 只表示已经找到项目；只有验证通过并写入 Ledger 的任务才能成为 `completed`。

Schema `1.1` 增加 `inputs.materials`。route-only 任务允许材料为空；受监督 Worker 必须至少有一份已快照材料。`awaiting_worker_start` 是 Runner 的监督暂停返回值，不是 TaskContract 状态；此时合同仍保持 `routed`，可从同一合同恢复。

运动候选结构验证通过后，合同进入 `waiting_for_approval` 并登记 `content_fact_review`。自然语言事实不能只靠模型自检自动晋级，因此该候选不会直接成为 `completed`。

状态定义：

```text
waiting_for_user | waiting_for_approval | routed | dispatched
evaluating | retrying | completed | failed
```

返回：[[10-项目/Hermes-Harness/README|Hermes Harness]]。
