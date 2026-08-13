---
type: harness-core
status: active
created: 2026-07-17
updated: 2026-07-17
---

# Harness Core

## 职责

Hermes 只负责发现、调度、状态控制和证据闭环，不保存全部业务知识，也不代替目标项目执行专业工作。

## 控制循环

```text
received
→ understanding
→ contract_drafted
→ routed
→ dispatched
→ evaluating
→ completed | retrying | waiting_for_user | waiting_for_approval | failed
```

长期驻扎指事件驱动的状态与规则长期存在，不是模型持续思考。只有新需求、Worker 返回、用户补充、审批结果或超时事件才唤醒控制循环。

受监督执行在 `routed` 与 `dispatched` 之间增加一个操作性暂停点 `awaiting_worker_start`：Harness 先生成可检查的 Worker 包，用户批准后才真正派发；该暂停点不扩展 TaskContract 的业务状态集合。

## 权威边界

- 项目位置：[[00-系统/项目注册表]]。
- 跨项目稳定规则：[[00-系统/工作流决策]]。
- 单项目事实：各项目 `00_项目记忆/`。
- 运行状态：本项目 `runtime/`。
- 生成镜像和运行账本不能反向覆盖权威 Markdown。

返回：[[10-项目/Hermes-Harness/README|Hermes Harness]]。
