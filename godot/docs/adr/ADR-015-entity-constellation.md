# ADR-015: 实体星座图(实体-主张层进图谱)

- 状态:已批准(2026-09-28,ADR-010 D3 遗留专项)
- 关联:ADR-009(实体-主张层,schema v8)、ADR-010(时间游标/as_of_world)、ADR-013(织结节 glyph);外部参照:AIRI「Entity Ledger: entity-claim constellation」「Subject-Predicate-Object Claim Triples (EntityLedger)」
- 前置:v8 的 entities / claims 数据层已就绪;graph_page 已露 source 字段(ADR-013 D4)

## 背景

记忆-记忆图谱只回答「哪些经历彼此相关」;实体-主张层(v8)记录「谁是谁、谁对谁做了什么、相信什么」——两张图一直各看各的。AIRI 对比表把「Subject-Predicate-Object Claim Triples + supersededBy 信念修订」列为其 Entity Ledger 的核心,而我们这份数据只服务于 prompt 水合(current_facts),从未可视化。ADR-010 D3 明确「实体-主张节点进图留给实体星座图专项」,本 ADR 落地该专项。

## 决策

### D1 图契约扩展(向后兼容)

- `graph_page(..., include_entities: bool = False)`;`/heartloom/graph?include_entities=1` 开启。缺省关闭时响应与现状**逐字节等价**(旧消费者零影响)。
- 开启后:
  - 节点数组新增**实体节点**,与记忆节点同列:
    ```
    {"node_id": <entity_id>, "node_type": "entity", "name": 实体名, "kind": person|object|place|event|concept,
     "aliases": [...], "claim_count": n, "world_created_at": first_seen, "world_updated_at": ...}
    ```
    记忆节点同步加 `node_id`(= memory_id)与 `node_type: "memory"`(增字段,不改旧键)。
  - 新增两类边:
    - **claim 边**(实体↔实体):`link_type: "claim"`,`src`=subject_entity_id,`dst`=object_entity_id,`predicate`=谓词,`link_strength`=confidence,`world_created_at`=world_from,`world_to`=失效时刻(现行主张为 null);`superseded_by` 供审计。
    - **claim_source 边**(记忆→实体):claims.source_memory_id 命中当前返回的记忆集时发出,把两张图缝合。
- 上限:实体 ≤150(按 world_updated_at 倒序);claim 边 ≤300(现行优先,再按 world_from 倒序);claim_source 边随 claim 边同批,≤300。
- 时间语义(与 ADR-010 一致):as_of 给定时实体按 world_created_at ≤ as_of 过滤、claim 边按 world_from ≤ as_of 过滤;**world_to 不做服务端硬过滤**——失效主张随载荷下发,由客户端调光表达「过去相信过」(信念修订可视化)。

### D2 Godot 画布

- 实体节点:细环 + 中心点(空心),按 kind 取色(人物/器物/地点/事件/概念五色);标签在缩放 ≥0.72 或悬停/选中时显示(复用记忆标签的避让逻辑)。
- claim 边:琥珀色细线,`predicate` 标签仅在该边任一端点选中/悬停时绘制;`claim_source` 边灰色更细。
- 时间游标:实体复用 `world_created_at` 幽灵规则;claim 边按 `world_from` 幽灵;`world_to ≤ 游标` 的失效边额外压暗至 0.35×(「当时还相信」)。
- 面板:图谱请求带 `include_entities=1`;节点归一化改用 `node_id`(回退 `memory_id`)。

### D3 明确不做(负面清单)

- 不做实体节点的编辑 UI(合并/改名走数据层);
- 不做 claim 边的力导向独立物理(实体节点坐标跟随既有布局,取平均/锚点;单独物理留给后续);
- 不做实体搜索/过滤面板(查询参数 query 只作用于记忆节点)。

## 后果

- 正面:信念修订(旧值 world_to + supersededBy)首次可视化;记忆图与实体图缝合(claim_source);AIRI 对比表 Entity Ledger 维度补齐展示层。
- 代价:开启时每次查询多两条 SELECT(实体列表 + claim 列表,均有索引);画布节点数上限翻倍量级(150 实体 + 200 记忆),自绘压力可控。
- 验收:① 缺省关闭时响应与旧版等价(回归断言);② 实体节点/claim 边/claim_source 边载荷正确;③ as_of 过滤实体与 claim(world_from);④ world_to 随载荷下发;⑤ 画布实体环与 claim 细线渲染,手动验收;⑥ 全量 CI 绿。
