# 架构决策记录(ADR)索引

本目录收录 Spring Haven 的架构决策记录。编号递增,一经采纳不重写;
修订以**追加 ADR** 或加「修订」小节的形式进行,不改历史结论。

| 编号 | 文件 | 主题 | 状态 |
|---|---|---|---|
| ADR-001 | [ADR-001-heartloom-retrieval-network.md](ADR-001-heartloom-retrieval-network.md) | Heartloom 检索与记忆网络 | 已落地 |
| ADR-001 附录 | [ADR-001-appendix-graph-contract.md](ADR-001-appendix-graph-contract.md) | 记忆图契约与样例数据 | 参考 |
| ADR-002 | [ADR-002-llm-numeric-hygiene.md](ADR-002-llm-numeric-hygiene.md) | LLM 上下文数值卫生(定性分桶,硬性不变量) | 已落地 |
| ADR-003 | [ADR-003-backend-truth-source.md](ADR-003-backend-truth-source.md) | 生理状态唯一真相源 | Phase 1 已落地 / Phase 2 待定 |
| ADR-004 | [ADR-004-gameworld-stage-architecture.md](ADR-004-gameworld-stage-architecture.md) | GameWorld 舞台架构与 BackgroundFX 子层 | 已落地 |
| ADR-005 | [ADR-005-structured-output-envelope.md](ADR-005-structured-output-envelope.md) | 统一结构化输出信封(含 `STATE_DELTA` 速率闸门) | **草案** |
| ADR-006 | [ADR-006-offline-residency-throttling.md](ADR-006-offline-residency-throttling.md) | 离线驻留推演限流(纯规则模拟 + LLM 延后合并) | **草案** |
| ADR-007 | [ADR-007-session-key-lifecycle.md](ADR-007-session-key-lifecycle.md) | 会话键与会话生命周期 | **草案** |
| ADR-008 | [ADR-008-ws-push-contract.md](ADR-008-ws-push-contract.md) | WS 推送契约(鉴权 / 乱序 / 粒度 / 降级粘滞) | **草案** |

## 相关评审文档

- [`../WorldTimeArchitectureReview.md`](../WorldTimeArchitectureReview.md) —— world_time 单时钟评审(ADR-1 三项折中裁决)
- [`../WorldTimeConstantsInventory.md`](../WorldTimeConstantsInventory.md) —— #23 时间常量清点清单
- [`../CompanionCoreReliability.md`](../CompanionCoreReliability.md) —— Core 可靠性(心跳与离线推演)

## 草案项的依赖顺序

```
#23 world_time 收尾 ──┬─→ ADR-005 结构化输出信封 ──→ #22 Phase 2(互动结算上收后端)
                      ├─→ ADR-006 离线驻留限流
                      ├─→ ADR-008 WS 推送(单调序号依赖 world_time)
                      └─→ ADR-007 会话层(实现前须过评审)
```

> ADR-005 / 006 / 007 / 008 目前**均为设计草案,代码零实现**。
> 建议按上图的依赖顺序逐个评审后再落地。
