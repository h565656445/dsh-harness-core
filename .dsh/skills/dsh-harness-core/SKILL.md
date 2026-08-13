---
name: dsh-harness-core
description: 面向 Hermes Harness 核心控制平面的专家技能：任务契约、路由、质量门禁与受监督 Worker 编排 / Expert skill for the Hermes Harness core control plane: task contracts, routing, quality gates, and supervised worker orchestration
---

# Hermes Harness 核心控制平面 / Hermes Harness Core Control Plane

本技能指导在 Hermes Harness 核心控制平面中工作：理解 TaskContract 与路由规则，遵守权限边界与质量门禁，使用 harness_runner 创建任务并核对 Ledger 证据。

This skill guides work in the Hermes Harness core control plane: understanding the task contract and routing rules, respecting permission boundaries and quality gates, creating tasks with harness_runner, and verifying Ledger evidence.

## When to use / 何时使用

需要创建/核验任务契约、解析路由、执行质量门禁或编排受监督 Worker 时。

Use when creating or verifying task contracts, resolving routes, enforcing quality gates, or orchestrating supervised workers.

## Workflow / 工作流

1. 阅读 core/ 文档（task_contract / router_rules / permissions / quality_gates）。
2. 用 harness_runner.ps1 解析需求并创建任务。
3. 核对 TaskContract 与 Ledger 事件。
4. 用 tests/ 回归验证。

## References / 参考

- 项目 README: 见仓库根目录
- 作者: h565656445 (GitHub)