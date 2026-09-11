# ADR: Heartloom记忆检索重构与记忆网络底层设计

- 状态:已批准(2026-09-12,用户确认整体方案,含两处微调)
- 关联:issue #22-#29;`godot/docs/WorldTimeArchitectureReview.md`(ADR:world_time 架构评审)
- 强制时序:#23 world_time 落地 → #22 状态真相源迁移 → 本重构;schema v6 设计随本 ADR 冻结,实施在 #23 完成后

## 背景

Heartloom 现状(`memory_entries` 21 列,save_id 即旅程键):主检索为词法打分 + LIKE 兜底 + 召回强化,无语义召回;记忆网络图 `memory_graph` 按查询全量 O(n²) 配对;无生命周期状态,记忆表只增不减;里程碑仅有存档级计数登记表(`milestones`,save_id+milestone_id PK)。同时期确定的新约束:world_time 单时钟(ADR #23)、后端为生理状态唯一真相源(ADR #22)、离线驻留推演零 LLM(#26)、原始生理浮点禁止进入 LLM 上下文(#29)。记忆是离线批量生成的核心场景,SQLite 批量写入与 WAL 压力是第一级设计约束。

## 决策

### D1 检索主链路:有界候选池混合召回

- 三段式:硬过滤(save_id + lifecycle='active' + enabled=1)→ 有界候选池(≤400:world_time 最近窗口 300 条 ∪ always_active 常驻 ∪ memory_terms/词法命中集 ∪ importance≥0.8,超限按 recency+importance 截断)→ 池内混合打分。
- 融合公式(各通道归一化 0-1):
  `final = 0.40·semantic + 0.25·lexical + 0.20·time_decay + 0.10·importance + 0.05·graph_boost`
- **graph_boost 权重冻结为 0.05(Alpha 不调高,待评测集验证后再评估),且仅读取一级直接邻接边**:候选记忆的 graph_boost = 其与最近召回集/当前词法命中集之间一级邻接边的最大 link_strength;禁止递归遍历多级关联,邻居不参与权重传递。
- semantic 通道:复用现有 embedding 基建(`provider.embed`),cosine 映射 (cos+1)/2;embedding 延后回填(`embedding_json` 允许 NULL,调度器限速回填),回填缺失期间该路权重并回 lexical;记录 model+dim,与当前 provider 不匹配时该路静默弃用。
- 权重为后端常量,Alpha 不暴露配置;调参以 20-30 条"查询→期望记忆"评测集回归为准(建评测集是调参前置条件)。

### D2 词法检索:写入侧关键词,Alpha 不引入 FTS5 / bm25s

- 检索主入口 = `memory_terms` 倒查(精确/前缀)+ `content LIKE` 兜底(已含 ESCAPE);替代裸 LIKE 全扫。
- 写入侧丰富词条:organizer/传播的 LLM JSON 契约增加 `keywords` 数组字段;规则生成的记忆从事件类型/角色/动作词派生必填词条,全部入 `memory_terms`。
- FTS5(unicode61 对中文基本不可用;trigram 需 ≥3 字符,中文 2 字查询退化回 LIKE)与 bm25s+jieba(索引生命周期与离线批量写入耦合)均**不在 Alpha 引入**。升级触发条件:单旅程 memory_entries > 5000 或 recall p95 > 200ms 或实测召回不足;届时优先 FTS5 trigram 与 keywords 联合,bm25s 为最末备选。

### D3 依赖时序与 schema v6

- 强制顺序:#23 → #22 → 本重构;Phase 0(设计/纯函数/评测集/前端 mock)可并行。
- SCHEMA_VERSION 6 在 #23 内一次建齐:记忆扩充列 + memory_links + role_milestones + #22 事件日志空表,**建空表不算提前上线,写入代码分阶段启用**,避免 v7 二次迁移。

### D4 记忆网络底层:memory_links 增量建边

```sql
CREATE TABLE IF NOT EXISTS memory_links (
    link_id          TEXT PRIMARY KEY,
    save_id          TEXT NOT NULL,
    src_memory_id    TEXT NOT NULL,
    dst_memory_id    TEXT NOT NULL,
    link_type        TEXT NOT NULL
                     CHECK(link_type IN ('causal','association','spread','milestone')),
    link_strength    REAL NOT NULL DEFAULT 0.5,
    reason           TEXT NOT NULL DEFAULT '',
    world_created_at INTEGER NOT NULL,
    UNIQUE(src_memory_id, dst_memory_id, link_type)
);
CREATE INDEX idx_links_src  ON memory_links(save_id, src_memory_id, link_strength DESC);
CREATE INDEX idx_links_dst  ON memory_links(save_id, dst_memory_id);
CREATE INDEX idx_links_type ON memory_links(save_id, link_type);
```

- 增量建边协议:新记忆入库 → 候选集 = (world_time 最近 50 条 Active ∪ memory_terms 词条命中 top20 ∪ 同 source_event_id 族)→ 池内相似度取 top 3-5 建边,方向恒为 src=新、dst=旧,`reason` 记录建边依据。候选集有界,结构性杜绝 O(n²);禁止全量历史遍历。
- 四种边类型:causal(因果)、association(联想)、spread(传播,由 heard_from_* 链写入)、milestone(成就串联)。

### D5 三态生命周期(常量,不开放 UI 配置)

```sql
ALTER TABLE memory_entries ADD COLUMN world_created_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE memory_entries ADD COLUMN world_updated_at  INTEGER NOT NULL DEFAULT 0;
ALTER TABLE memory_entries ADD COLUMN last_recalled_world INTEGER NOT NULL DEFAULT 0;
ALTER TABLE memory_entries ADD COLUMN lifecycle TEXT NOT NULL DEFAULT 'active'
    CHECK(lifecycle IN ('active','dormant','archived'));
ALTER TABLE memory_entries ADD COLUMN lifecycle_changed_world INTEGER NOT NULL DEFAULT 0;
ALTER TABLE memory_entries ADD COLUMN is_second_hand INTEGER NOT NULL DEFAULT 0;
ALTER TABLE memory_entries ADD COLUMN embedding_json TEXT;
ALTER TABLE memory_entries ADD COLUMN embedding_model TEXT NOT NULL DEFAULT '';
```

- 常量(后端代码,不可配置):`DORMANT_AFTER_WORLD_DAYS = 14`(14 世界日无召回且无关联更新 → dormant);`ARCHIVE_CONFIDENCE_THRESHOLD = 0.15`(衰减后置信度 < 0.15 → archived)或手动归档。
- `always_active = 1` 的条目豁免自动 dormant 与自动归档(手动操作不受限)。
- 状态效果:active = 全量参与检索与图;dormant = 默认检索与图不返回,但显式词法/关键词精确命中可召回并自动升回 active;archived = 完全不参与,仅手动恢复。
- 旧档回填:统一 `lifecycle='active'`;`is_second_hand = 1 WHERE source LIKE 'heard_from_%'`;world_time 起点约定 = 迁移时刻,旧记忆按 real created_at 相对偏移映射。
- 旅程绑定沿用 `save_id`(全仓库事实上的旅程键),不新增 journey_id 列,文档统一术语。

### D6 成就里程碑:role_milestones,规则判定 + LLM 仅文案

```sql
CREATE TABLE IF NOT EXISTS role_milestones (
    milestone_id      TEXT PRIMARY KEY,   -- "ach-<rule_id>-<role>-<world_day>"(确定性幂等)
    save_id           TEXT NOT NULL,
    role_id           TEXT NOT NULL,
    rule_id           TEXT NOT NULL,
    title             TEXT NOT NULL DEFAULT '',
    description       TEXT NOT NULL DEFAULT '',
    icon              TEXT NOT NULL DEFAULT '',
    source_memory_id  TEXT NOT NULL DEFAULT '',
    unlocked_world_at INTEGER NOT NULL,
    created_at        INTEGER NOT NULL,
    UNIQUE(save_id, role_id, rule_id)
);
CREATE INDEX idx_role_ms_save ON role_milestones(save_id, role_id, unlocked_world_at DESC);
```

- 解锁由后端规则判定(确定性),LLM 仅生成 title/description 文案且**异步补齐**:规则命中 → 幂等插入(占位模板文案)→ 生成 milestone 类型记忆 → 自动建 milestone 边串联合相关记忆(top 3)→ LLM 文案回填,失败落占位不阻塞。
- 与现有 `milestones` 表(存档级计数解锁登记)职责分离:后者不变,前者为角色维度成就档案;代码注释与文档钉死边界。

### D7 graph API

`GET /heartloom/graph?save_id&role_id&limit&cursor`:输出 `{nodes[], edges[], cursor, truncated}`;默认仅 Active;节点上限 300,超限 `truncated=true` + 游标分页;edges 只含返回节点集合内部的边。前端做节点数限制、分页、筛选;>150 节点降级(聚类/分组)。现有 `/memory/graph` 保留过渡版本后废弃。

### D8 数值出域联动(#29)

召回结果组装进 prompt 的记忆上下文剥离 `confidence`/`importance`/`updated_at` 等数值元数据;STATE_DELTA/事件日志不得将数值回显进后续上下文。记忆侧与 #29 同批验收。

## 备选方案(已否决及理由)

| 备选 | 否决理由 |
|------|----------|
| 全库向量检索 / 现在引入 sqlite-vec | 万级以下无需 ANN;有界候选池已达毫秒级;扩展引入与单文件部署的耦合,Phase 2 评估 |
| Alpha 引入 FTS5 | 中文 2 字查询退化回 LIKE,收益有限;记忆量触发条件未到 |
| Alpha 引入 bm25s + jieba | 检索质量最好,但索引生命周期与离线批量写入耦合 + 两个新依赖,违反稳定性优先 |
| 里程碑由 LLM 判定 | 不可靠且不可幂等;规则判定 + LLM 仅文案 |
| 全量历史遍历建边 | O(n²),与 #4 的整改方向相反;候选集协议结构性解决 |
| 完整事件溯源(状态=重放) | schema 与双端改动过大,Alpha 记事件日志仅调试,Phase 2 评估 |
| 新增 journey_id 列 | 与 save_id 语义重复,双键分裂;沿用 save_id + 统一术语 |
| 双向边 / 递归图遍历 | 读放大与循环风险;单向新→旧 + 一级邻接足够 |
| 阈值开放 UI 配置 | 无评测基准的调参会破坏检索质量;作为后端常量,评测集建好后按版本调整 |

## 正面后果

- 语义召回补齐记忆主链路短板(词法+图 → 词法+向量+图混合),质量上限由评测集约束。
- 检索与建边的计算复杂度均有界(候选池协议),消除 O(n²) 隐患,事件循环零阻塞(配合 #4 的 to_thread)。
- 三态生命周期让检索范围收敛,大记忆量下的扫描面积随归档自动收缩;二手传闻(`is_second_hand`)可溯源(`source_event_id` 链),为后续冲突仲裁铺路。
- 离线批量生成安全:embedding 延后回填 + 分批事务 + 零 LLM 限流(#26),WAL 压力可控。
- 里程碑系统获得可解释的成就档案与自动串联的记忆边,且 LLM 失败不阻塞解锁。
- graph API + 力导向前端的契约先行,前端可 mock 并行;节点上限与分页防 UI 卡顿。
- schema v6 单次迁移,避免 v7;`#22` 事件日志表同步建齐。

## 负面后果

- v6 一次性迁移的回滚面大:回填脚本必须在备份副本上演练三种形态(最小旧档/最老档/含二手传播档),迁移前强制 backup。
- embedding 回填窗口内语义召回缺位(纯词法降级),检索质量有过渡期;回填消耗 embedding 配额(与用户对话共享 provider)。
- 融合权重在评测集建成前不可调也不可证;三态阈值初值(14 世界日/0.15)未经实测,存在召回过窄或过宽的调参风险。
- 召回上下文剥离数值元数据后,排查检索质量问题的可见性下降,需要日志侧补偿(记 recall 评分明细到调试日志而非 prompt)。
- 双里程碑系统(`milestones` 计数登记 vs `role_milestones` 成就档案)并存,认知与维护成本上升。
- 单向边 + 一级邻接意味着跨两级关联在检索中不可见(设计取舍:换取有界复杂度)。
- spread 边扇出在 >3 角色场景未经验证,需在多角色阶段补上限。

## 实施阶段与验收

- Phase 0(现在,并行,禁止落库):v6 DDL 冻结(本文)、残留清点、分桶摘要纯函数、融合打分纯函数 + 评测集、graph 契约 + 前端 mock。
- Phase 1 = #23:v6 迁移上线(建表 + 回填,三种形态演练)。
- Phase 2 = #22:事件日志写入启用,分桶摘要接入 prompt。
- Phase 3 = 本重构:links 建边 → 三态 → 向量回填与混合召回切换 → role_milestones → graph API → 前端接入。
- 验收:① 迁移演练三形态通过;② 评测集上混合召回优于纯词法基线;③ 结构断言测试确认 prompt 无原始数值;④ 建边单测(候选集有界、top3-5、四类型);⑤ graph API 分页/上限/Active 默认测试;⑥ CI 全绿。
