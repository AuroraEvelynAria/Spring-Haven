# ADR-013: 夜织——世界时间驱动的记忆巩固与蒸馏

- 状态:已批准(2026-09-28,用户确认"三块差距全部实施",本块为 C)
- 关联:ADR-001(记忆网络/边)、ADR-009(实体-主张)、ADR-012(心境自愈共享世界日节律);外部参照:AIRI「Autonomous Dreaming Worker & Lifetime Distillation」与「context budget pruning & consolidation」
- 前置:**零 schema 迁移**——织结节复用 memory_entries(source/source_event_id 唯一索引做幂等)、memory_links 既有枚举('association'/'milestone')、heartloom_meta KV 做季织哨兵

## 背景

organizer(每轮)与 weekly insight(每周)之间缺一层**巩固纵深**:单日经历无人织成主题,归档记忆淡出后不留痕迹,季度尺度的"这一季的我"无处落地。AIRI 用 Dreaming Worker 做多级蒸馏(STMM→LTMM→Lifetime)。夜织是春日庭院的对位物,且有一个 AIRI 没有的优势:**触发器是世界时间**——离线推演加速时,角色真的"过了好几夜",夜织按世界日落自然发生,与 ADR-012 的心境自愈共享同一节律。

## 决策

### D1 夜织(每世界日,预算最重的一层也最便宜)

- **触发**:某 (scope_role_id, 世界日 D) 满足——①D 已结束(`world_now ≥ D+1`);②当日 ≥3 条可织记忆(排除既有织结节/weekly_insight/season_weave,防自我喂食);③该日尚无织结节(确定性 `source_event_id='nightly-world-d{D:04d}'` 落唯一索引,天然幂等)。
- **产出**:单次 LLM 调用,把当日记忆束织成 ≤1 条主题级 semantic 记忆(source=`consolidation_{scope}`,kind='semantic',half_life=180,importance **钳制 ≤0.65**——织结节是提纯不是新事件);与当日各源记忆补 `association` 边(strength 0.7,reason='consolidated')。
- **硬约束(防梦呓)**:契约写明"只能重组输入里已有的事实,禁止出现输入没有的新人物/新事件/新数字";LLM 失败/解析失败 → 该日跳过,下次调度重试,**不用模板兜底**(宁可缺一条织结节,不可产出幻觉)。
- **防洪**:每存档每轮调度最多织 2 个最旧的未织日(老存档升级不爆发)。

### D2 周织归档清扫(扩展既有 weekly insights,不新造管线)

- 周洞察生成前,取该世界周内被 `ARCHIVE_CONFIDENCE_THRESHOLD` 收走的记忆标题(≤12),作为"本周淡忘的记忆"并入洞察上下文;
- 周洞察落库后,对其与这批归档记忆补 `association` 边(reason='archived_sweep')——淡出者留审计线,对照 AIRI「old sessions roll into daily summaries」。

### D3 季织(每 90 世界日)

- `world_now` 跨过 90 日边界时,取当季 weekly insight(≥2 条)单次 LLM 调用 → 一条 identity 记忆(「这一季的我」,第一人称,`always_active=1`、`half_life=0`、importance 0.75),与当季周织补 `milestone` 边(strength 0.9);
- 哨兵 `heartloom_meta['season_weave:{save}:s{idx:03d}']` 幂等;失败跳过重试;不足 2 条周织不产(宁缺毋滥)。

### D4 表达(尊重场景式 UI 红线)

- `graph_page` 节点载荷新增 `source` 字段;
- 🕸️ 画布上,`consolidation_*`/`season_weave` 节点绘制**月相式自绘 glyph**(细线弦月,非 emoji),与既有 kind 视觉体系并列——不新增面板,不改布局。

### D5 明确不做(负面清单)

- 不做梦呓叙事进对话流(织结节只进记忆库,不主动发言);
- 不自动降级被织源记忆的生命周期(归档仍只由置信度阈值决定);
- 不做"梦见未来"类生成——夜织是巩固不是创作。

## 后果

- 正面:巩固纵深三层落地(日/周/季),对比表 Memory Consolidation 维度对齐;夜织是 AIRI 认可的"游戏内置时钟时间戳"哲学的自然延伸。
- 代价:每活跃世界日 1 次 LLM 调用 + 每季 1 次(比 organizer 低一个数量级);graph 载荷多一个字符串字段。
- 验收:① 世界日关闭判定与 ≥3 门槛;② 织结节幂等(同日重跑不重复);③ 钳制 ≤0.65 且 kind=semantic、关联边就位;④ 归档清扫边 + 上下文并入;⑤ 季织哨兵与 milestone 边;⑥ graph 载荷带 source、画布 glyph 渲染;⑦ 全量 CI 绿。
