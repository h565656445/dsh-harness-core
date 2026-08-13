---
type: harness-routing-rules
status: active
created: 2026-07-17
updated: 2026-07-17
---

# 路由规则

## 任务理解维度

Runner 从需求中提取：

- `domains`：sports、video、ai_video、novel、website、knowledge、research、content_distribution、data。
- `actions`：query、analyze、create、update、publish、delete、pay、account_change、change_core_rules。
- `channels`：short_video_platform、social_platform、website、obsidian。
- 明确约束：当前支持秒数。
- 模糊指代与副作用。

关键词只提供可审计线索，不是通用语义理解器。未识别业务域、未识别动作、出现模糊指代或没有匹配项目时，状态必须进入 `waiting_for_user`。

非运动视频需求在识别到 `video` 且未识别到 `sports` 时，额外派生 `ai_video` 域并留下 `derived:non_sports_video` 证据。普通运动视频仍只进入体育分支；明确包含 AI 视频、文生图、图生视频或导演 Agent 的运动需求才同时进入 AI 剪辑分支。

## 项目匹配

项目必须同时满足：

1. 在权威注册表中为 `active`；
2. 在能力配置中为 `routable=true`；
3. 至少匹配一个任务业务域。

多项目需求按匹配分数生成顺序计划；后续节点依赖前一节点。MVP 不做并行 DAG，也不自动创建新项目或 Agent。

## 置信度

置信度来自可观察证据：业务域、动作、渠道、明确时长和多域识别。它是路由策略分数，不代表模型真实概率，也不能绕过权限门。

返回：[[10-项目/Hermes-Harness/README|Hermes Harness]]。
