# ADR-011: 记忆召回跨编码器重排(BGE Rerank)

- 状态:已批准(2026-09-28,用户确认"三块差距全部实施",本块为 A)
- 关联:ADR-001(混合召回)、ADR-012(PAD 心境基线,预留 valence 共振项);外部参照:AIRI 对比表「Jev Salience Gating & Multi-Factor Reranker」
- 前置:`provider_settings.json` 已配置 rerank 档(BAAI/bge-reranker-v2-m3,SiliconFlow),`provider.rerank()` 已存在(RAG 在用)

## 背景

混合召回(0.40 语义 + 0.25 词法 + 0.20 衰减 + 0.10 recency + 0.05 priority + 0.05 graph)是双塔式打分:查询与记忆各自编码后比余弦。实弹测试(livetest1,10/10)暴露了它的盲区——词法零交集的同义改写靠 `SEMANTIC_ONLY_ADMISSION` 兜底入池后,排序只能继续依赖余弦;而「换工作前/换工作后」这类时序敏感、否定敏感的区分,余弦原理上做不好,跨编码器(cross-encoder)逐对精排才能做。Rerank 档位早已配置但只服务于 RAG,记忆召回从未受益。

## 决策

### D1 `recall()` 拆分:无副作用候选池 + 定稿副作用

- `recall_pool(...)`:混合打分全流程(含池内局部 IDF、graph_boost、语义兜底入池、conversation_user 去重),返回**完整去重池**;零副作用——不唤醒 dormant、不记访问、不发唤醒奖励。
- `commit_recall_access(memory_ids, record_access)`:定稿副作用一次落定——池内 dormant 命中唤醒(ADR-001 D5 语义不变:仅词法命中的 dormant 才在池里)+ `last_recalled_*`/`recall_count`/唤醒奖励。
- `recall()` 重构为「池 → 截断 limit → commit」,对外行为与拆分前逐位一致(205 项既有测试守护)。

### D2 服务层重排(service,异步边界)

- chat 流程:`recall_pool(limit)` → 短名单前 12 条 → `provider.rerank(query, contents)` → 最终分 `0.55×rerank + 0.45×混合分` → 取前 `recall_limit` → `commit_recall_access`。
- rerank 分防御性归一:落在 [0,1] 直接用,越界按 logits 过 sigmoid(bge-reranker 不同网关返回口径不一)。
- 唤醒奖励/访问记录只落在**最终入选**的条目上——重排不放大奖励。

### D3 预算与降级(硬性)

- 每轮对话至多 1 次 rerank 调用,短名单 ≤12,单文档截断 2000 字符。
- 失败静默降级:rerank 档未启用、provider 抛错、超时 → 直接用混合序前 N,打 warning 不阻塞对话;断路器复用 provider 现有 `_record_provider_failure`。
- 开关:`memory_rerank_enabled`(core_config.json / 环境变量 `SPRING_HAVEN_MEMORY_RERANK`,默认开)。关 → 请求路径零变化。

### D4 明确不做(负面清单)

- 不做 rerank 结果缓存(每轮一次,收益小于复杂度;将来查询缓存层统一做);
- 不进 `recall_eval` 冻结棘轮(评测集是离线纯词法确定性跑,rerank 是在线网络通道,单独 `--rerank` 报告提升量);
- valence 共振项留给 ADR-012(PAD 基线落地时一并点亮,权重 0.03 级)。

## 后果

- 正面:跨编码器精排补上双塔盲区(时序/否定/改写),AIRI 对比表 rerank 维度对齐;零迁移、零新表。
- 代价:聊天热路径多一次网络调用(约 100-400ms);降级路径保证最坏情况即现状。
- 验收:① 假 rerank 重排生效、最终序正确;② 降级回落混合序;③ 开关关闭零调用;④ recall_pool 无副作用、commit 只奖励入选集;⑤ 全量 CI 绿;⑥ 棘轮 0.4667 不回归。
