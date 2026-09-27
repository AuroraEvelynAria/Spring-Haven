# ADR-012: PAD 心境基线(缓慢漂移的情绪底色)

- 状态:已批准(2026-09-28,用户确认"三块差距全部实施",本块为 B)
- 关联:ADR-002(数值卫生:原始浮点不进 prompt)、ADR-009(organizer 抽取管线)、ADR-011(rerank,预留 valence 共振);外部参照:AIRI「Affective Dynamics: PAD emotional baseline deltas」
- 前置:schema v9(新增 mood_baseline 表);organizer 单次调用扩一个输出字段

## 背景

11 项生理数值是"身体的现在",但角色缺一层"心里的近日"——连续三件糟心事和单件糟心事,在对话语气上应当可感。AIRI 用 PAD(Pleasure-Arousal-Dominance)基线增量刻画这一层。春日庭院的版本刻意做小:不是一个潜意识引擎,只是**一条缓慢漂移、按世界时间自愈的心境底色**。

## 决策

### D1 数据(schema v9,一张表)

```sql
CREATE TABLE mood_baseline (
    save_id TEXT NOT NULL, role_id TEXT NOT NULL,
    pleasure REAL NOT NULL DEFAULT 0,   -- 愉悦 -1..1
    arousal  REAL NOT NULL DEFAULT 0,   -- 唤醒 -1..1
    dominance REAL NOT NULL DEFAULT 0,  -- 掌控感 -1..1
    world_updated_at REAL NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (save_id, role_id)
);
```

历史轨迹不建新表——每次变更追加现有 `state_events`(kind="mood")审计。稳态锚点(情绪的家)进角色定义:`RoleDefinition.mood_home = (p, a, d)`,roles.json 可配 `mood_home`,缺省 `(0.0, -0.1, 0.05)`(平静、微低唤醒、略安定)。

### D2 更新动力学(System 1,确定性,零额外 LLM 调用)

- **写入**:organizer 契约扩一个输出字段 `mood_delta:{p,a,d}`,每维限 [-0.3, 0.3](本轮互动的瞬时冲击);service 侧 EWMA 汇入:`baseline = baseline×(1-α) + delta×α, α=0.12`,clamp [-1,1]。模型没输出该字段 → 跳过,向后兼容。
- **自愈(世界时间招牌)**:不做"翻日定时器"——`current_mood()` 读取时按 elapsed 世界日**连续**向 mood_home 衰减:`v = home + (v-home)×0.9^Δworld_days`。离线推演加速时情绪同步自愈;Δ<0.05 世界天不回写(读多写少)。这就是 AIRI「morning mood recovery」的世界时钟版。

### D3 表达(ADR-002 纪律)

- PAD **数字永不出现在 prompt**:映射为定性词带(愉悦:明亮/平静偏亮/平静/低落/阴郁;唤醒:躁动/精神/安静/恹恹/疲惫;掌控感:从容/稳定/平和/局促/惶惑),渲染成一句 ≤20 字(如"心境平静偏亮、安静、掌控感平和"),放进 runtime 状态块的 `mood` 字段。三维绝对值全 <0.15 → 不输出(中性心境不占 token)。
- 响应载荷新增 `mood:{words, pleasure, arousal, dominance}`(原始浮点给可信的本地客户端,用于将来的场景化表达——尾巴姿态/待机动画倾向;本 ADR 不做 Godot 消费)。

### D4 明确不做(负面清单)

- 不做 Nan0 式潜意识状态机、不做情绪对召回的重加权(ADR-011 预留的 valence 共振项待本 ADR 稳定后单独评审);
- 不做情绪历史可视化 UI(审计在 state_events,取用留给图谱专项);
- 不让 mood 直接改写生理数值(单向:经历→心境;生理仍由 LifeSimulation 治理)。

## 后果

- 正面:语气连续性有了机制载体(连续糟心事 → 低落底色 → 措辞自然发闷);全部世界时间驱动,离线推演一致。
- 代价:SCHEMA_VERSION 8→9(守卫式迁移 + pre-v9.backup,纯新增表零回填);organizer 输出多 30 token 量级。
- 验收:① v9 升级建表+备份+版本位;② EWMA/clamp/连续衰减数值正确;③ state_events 审计落行;④ mood_words 分带正确且输出无数字字符;⑤ organizer 无 mood_delta 字段向后兼容;⑥ 全量 CI 绿。
