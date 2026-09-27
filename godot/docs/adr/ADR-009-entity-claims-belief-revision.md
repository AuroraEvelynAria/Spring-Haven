# ADR-009: 实体-主张层与信念修订(Entity-Claims & Belief Revision)

- 状态:已批准(2026-09-27,用户确认实施)
- 关联:ADR-001(检索与记忆网络);外部参照:AIRI `EntityLedger` 的 supersededBy 信念修订思路(AIRI 开发者架构对比的头号建议)
- 前置:schema v7(world_time 单时钟,本 ADR 所有时间字段均为世界天)

## 背景

Heartloom 的 `memory_links` 把**记忆块**连成网,但没有**实体层**:角色换工作、纠正错误事实这类更新只能靠新记忆顶掉旧记忆的分数,`_detect_conflicts` 只能建一条 conflict 边(强度 0.9)供人观察——LLM 在后续对话中仍可能把旧事实当作当前事实说出来。检索修复(2026-09-27,冻结基线 2/15→7/15)解决了「找得准」,本 ADR 解决「**记得对**」:给记忆网加一层可修订的实体-主张结构。

## 决策

### D1 schema v8:两张新表,纯新增零回填

```sql
CREATE TABLE entities (
    entity_id  TEXT PRIMARY KEY, save_id TEXT NOT NULL,
    kind  TEXT NOT NULL DEFAULT 'concept',   -- person|object|place|event|concept
    name  TEXT NOT NULL, name_norm TEXT NOT NULL,
    aliases_json TEXT NOT NULL DEFAULT '[]',
    world_created_at REAL NOT NULL DEFAULT 0, world_updated_at REAL NOT NULL DEFAULT 0,
    UNIQUE (save_id, name_norm)
);
CREATE TABLE claims (
    claim_id TEXT PRIMARY KEY, save_id TEXT NOT NULL,
    subject_entity_id TEXT NOT NULL,
    predicate   TEXT NOT NULL,               -- 2-6 字关系/状态,如「喜欢」「在用」「属于」
    object_entity_id  TEXT,                  -- 宾语可为实体;自由描述时为 NULL
    object_text TEXT NOT NULL DEFAULT '',    -- 宾语逐字文本(始终保留)
    source_memory_id  TEXT NOT NULL DEFAULT '',
    confidence REAL NOT NULL DEFAULT 0.8,
    world_from REAL NOT NULL DEFAULT 0,
    world_to   REAL,                         -- NULL = 当前有效
    superseded_by_claim_id TEXT,
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
```

- 纯新增表,`executescript` 对旧库直接建表,**无需数据回填**;升级前强制 `pre-v8.backup`(沿用 v6/v7 惯例);`SCHEMA_VERSION 7 → 8`。
- 主张的**当前事实 = `world_to IS NULL`**(partial index 支持);历史事实经 `superseded_by_claim_id` 成链,可回溯「什么时候相信过什么」——这是 C 阶段 4D 心图的数据地基。

### D2 抽取:organizer 契约扩展,写入侧零新增进程

- `ORGANIZER_CONTRACT` JSON 增加两个可选数组:`entities[]`(name/kind/aliases,≤8)与 `claims[]`(subject/predicate/object,≤6);契约明确「只提取对话中明确表达的事实,推测不输出」。
- 不新增 LLM 调用、不新增进程——organizer 本来就每轮跑;claims 的来源记忆 = 本轮 organizer 写入的第一条记忆(无则空字符串)。
- `predicate`/实体名做清洗(长度上限、去标记符);`name_norm` = 小写去空白,实体按 `(save_id, name_norm)` 幂等 upsert,别名合并。

### D3 信念修订(supersession)语义

对同 `(save_id, subject, predicate)` 的新主张:
1. 当前无有效主张 → 直接写入;
2. 当前主张**宾语相同** → 视为强化:`confidence = max(旧, 新)`,不新增行;
3. 当前主张**宾语不同** → 顶替:旧主张 `world_to = 世界现在`,`superseded_by_claim_id = 新主张 id`;新主张写入;并在新旧两条主张的 `source_memory_id` 之间补一条 `conflict` 边(reason=「事实更新:<subject> <predicate>」)——保留 ADR-001 的冲突可观察性。

### D4 召回注入:有界 `<heartloom_current_facts>`

- 主召回完成后,取两类实体的并集:① 查询文本中按 name/alias 子串命中的实体;② 召回记忆作为 `source_memory_id` 挂靠的主张实体。
- 每实体取当前有效主张,全局上限 12 条,注入独立只读块 `<heartloom_current_facts version="1">`(与 `<heartloom_memory_context>` 平级,markers 同样转义)。内容形如 `{subject, predicate, object, since_world}`。
- 稳定前缀缓存不受影响:该块与记忆召回一样属于**动态**中段,不进 System 前缀。

### D5 明确不做(负面清单)

- 不引入完整三元组知识库/图数据库——SQLite 两张表足够单人规模;
- 不做实体消歧(同名不同物)——`name_norm` 相同即同实体,歧义留给未来按需加限定;
- 不改 `memory_entries` 任何列(零迁移风险);不上 FTS;
- C 阶段的 `/heartloom/graph?as_of_world=` 时间滑杆是**后续 ADR**,本 ADR 只保证数据可回溯(world_from/world_to/superseded_by 齐备)。

## 后果

- 正面:事实更新可表达、可审计、可回溯;LLM 拿到「当前事实表」后旧事实不再污染对话;为 4D 心图提供实体-主张时间轴。
- 代价/风险:organizer 输出更长(契约约束 ≤6 claims 兜底);实体抽取质量依赖模型,错误主张会进当前事实表——由 D3 的再次顶替自然纠错,conflict 边供审计。
- 验收:① v8 迁移演练(v7 档升级、版本戳、备份);② upsert 幂等;③ 顶替/强化/冲突边三态;④ `<heartloom_current_facts>` 注入与转义;⑤ 全量 CI 绿。
