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
| ADR-009 | [ADR-009-entity-claims-belief-revision.md](ADR-009-entity-claims-belief-revision.md) | 实体-主张层与信念修订 | 已落地(有修订) |
| ADR-010 | [ADR-010-temporal-graph-as-of.md](ADR-010-temporal-graph-as-of.md) | 心织图谱时间游标(as_of_world) | 已落地(有修订) |
| ADR-011 | [ADR-011-rerank-recall.md](ADR-011-rerank-recall.md) | 记忆召回跨编码器重排(BGE Rerank) | 已落地(有修订) |
| ADR-012 | [ADR-012-mood-baseline-pad.md](ADR-012-mood-baseline-pad.md) | PAD 心境基线(缓慢漂移的情绪底色) | 已落地 |
| ADR-013 | [ADR-013-nightweave-consolidation.md](ADR-013-nightweave-consolidation.md) | 夜织——世界时间驱动的记忆巩固与蒸馏 | 已落地 |
| ADR-014 | [ADR-014-ebbinghaus-stability.md](ADR-014-ebbinghaus-stability.md) | 艾宾浩斯正式化(intrinsic 稳定度系数与方向修正) | 已落地 |
| ADR-015 | [ADR-015-entity-constellation.md](ADR-015-entity-constellation.md) | 实体星座图(实体-主张层进图谱) | 已落地(有修订) |
| ADR-016 | [ADR-016-story-spine-and-beats.md](ADR-016-story-spine-and-beats.md) | 故事脊椎与节拍(作者给骨架、状态给演绎的"线性但有分支") | **草案** |

> **状态统计(2026-10-13 逐条对代码复核,2026-10-16 追加 ADR-016)**:已落地 **10** · 部分落地 **1**(ADR-003 Phase 2 待定) · 参考 **1**(ADR-001 附录) · 草案(零实现) **5**(ADR-005 / 006 / 007 / 008 / 016)。
> 复核方式:全量检索 `companion-core/src/` 与 `godot/` 对应实现与测试(如 `test_entity_claims.py` / `test_graph_as_of.py` / `test_ebbinghaus.py` / `test_consolidation.py`),而非依据文档自述。
> 分布规律值得注意:**记忆与认知层(ADR-009~015)已全部落地,协议与传输层(ADR-005~008)全部未落地**。

## 相关评审文档

- [`../WorldTimeArchitectureReview.md`](../WorldTimeArchitectureReview.md) —— world_time 单时钟评审(ADR-1 三项折中裁决)
- [`../WorldTimeConstantsInventory.md`](../WorldTimeConstantsInventory.md) —— #23 时间常量清点清单
- [`../CompanionCoreReliability.md`](../CompanionCoreReliability.md) —— Core 可靠性(心跳与离线推演)

## 草案项的依赖顺序

```
#23 world_time ✅ 已完成(2026-09-27,schema v7) ──┬─→ ADR-005 结构化输出信封 ──→ #22 Phase 2(互动结算上收后端)
                                                ├─→ ADR-006 离线驻留限流
                                                ├─→ ADR-008 WS 推送(单调序号依赖 world_time)
                                                └─→ ADR-007 会话层(实现前须过评审)
```

> ADR-005 / 006 / 007 / 008 目前**均为设计草案,代码零实现**。
> 其唯一的共同前置 `#23 world_time` 已按 [`../WorldTimeConstantsInventory.md`](../WorldTimeConstantsInventory.md) 的结论于 **2026-09-27 完成**(schema v7:digest 分桶与窗口、周反思周键、里程碑扫描范围全部切到 world_time;旧档幂等回填与演练齐备)。
> 因此**四篇草案已无阻塞**,可按上图依赖顺序逐个评审后落地;建议从 ADR-005 起——它是统一信封,也是 #22 Phase 2 与本阶段「判定层 / 引擎向模型发号施令」共同的地基。
