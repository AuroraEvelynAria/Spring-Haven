# ADR: LLM 上下文数值卫生——生理数值只以定性分桶出域

- 状态:已落地(2026-09-15,commit `186babc`),并作为**硬性不变量**冻结;后续任何改动不得回退
- 关联:issue #29(落地单)、#22、#27;`godot/docs/WorldTimeArchitectureReview.md`「硬性约束:原始生理数值不出域」;`ADR-001-heartloom-retrieval-network.md` D8
- 决策范围:`companion-core/src/spring_haven_core/prompting.py`;守门测试 `companion-core/tests/test_prompt_qualitative.py`

## 背景

`WorldTimeArchitectureReview.md` 已把「原始生理数值不出域(never raw numbers to the LLM)」列为硬性约束,但当时的审计结论是**实现未守住**,存在两条直接泄露路径与一条相邻路径(即后来的 issue #29):

1. **直接泄露 A** —— `prompting.py` runtime 块 `body_state.stats`:`round(±100 钳位, 2)` 后的 11 项 0-100 浮点(health/stamina/hunger/thirst/awake/urine/intimacy/mood/stress/fertility/implantation)每轮每角色原样进入 user 消息。
2. **直接泄露 B** —— `prompting.py` `life_lab_event.needs_by_role`:Life Lab 社交事件中每个参与者的 hunger/thirst/stamina/mood 四项浮点进入 prompt。
3. **相邻路径 C** —— HEARTLOOM 记忆条目携带 `confidence`/`importance`(0-1 浮点)与 `updated_at`(unix 整数)元数据,非 0-100 生理值,但同属「裸数字进上下文」。

## 决策

### D1 分桶表:五档,后端常量

`prompting.py` 的 `_STATE_BUCKETS`(判定为「取第一个满足 `value >= threshold` 的档位」,全不满足则为最低档):

| 阈值(≥) | 标签 |
|---|---|
| 85.0 | 很高 |
| 65.0 | 偏高 |
| 35.0 | 普通 |
| 15.0 | 偏低 |
| (其余) | 很低 |

五档为**后端常量,不开放 UI 配置**。调整阈值必须伴随评测集回归,不得为个别表现临时调档。

### D2 有状态路径:`state_summary` 走 `_BucketHysteresis`

- `PromptComposer` 实例持有 `_BucketHysteresis`(`MARGIN = 2.0`)。
- 滞回状态键为 `(role_id, stat)`,即**按角色按指标**各自记忆上一档位。
- 规则:欲升档需 `value >= 边界 + MARGIN`;欲降档需 `value < 边界 - MARGIN`。数值在边界附近 ±2.0 内横跳时档位**不切换**,避免 LLM 观察到状态标签抖动。
- 输出形如 `健康=偏高；体力=普通；……`,仅标签,不含任何数字。

### D3 无状态路径:`needs_by_role` 走 `_qualitative_bucket`

- Life Lab 社交事件不需要跨轮记忆,使用无状态纯函数 `_qualitative_bucket()`。
- 该字段的**类型契约由 `dict[str, float]` 改为 `dict[str, str]`** —— 这是刻意的类型收紧:一旦上游试图塞回数字,类型即不成立。
- 入参钳位 `max(0.0, min(100.0, value))` 后再分桶。

### D4 记忆元数据走**白名单**而非黑名单

`_memory_context()` 不逐个剔除敏感字段,而是**只构造 4 个键**:`memory_id`、`kind`、`title`、`content`。

选择白名单的理由:黑名单会随 schema 演进不断漏;白名单让新增列**默认出局**,方向与「永不泄露」一致。

同时每条记忆序列化后有 12,000 字符总预算约束(超限即截断),并转义内部标记(`RUNTIME_*`/`HEARTLOOM_*`/`RAG_*`)防止记忆内容伪造 prompt 段落。

### D5 守门测试

`companion-core/tests/test_prompt_qualitative.py`(8 项):

- **结构断言** —— `needs_by_role` 的值必须是 `str` 而非 `float`。
- **数字审计** —— 对最终 prompt 文本做正则扫描,断言不出现生理指标的原始数字形态。
- **滞回单元测试** —— 覆盖「边界内不切换」「越过 ±MARGIN 才切换」「首次观测直接落档」三类行为。

此文件是**守门测试**:任何触碰 prompt 组装路径的改动落地后必须跑通它。

## 备选方案(已否决)

| 备选 | 否决理由 |
|------|----------|
| 继续保留原始浮点,只靠系统提示词「请不要引用这些数字」 | 提示不是约束,LLM 会引用;且数字一旦进上下文即可被回声泄露 |
| 放宽为「保留 1 位小数」 | 伪精确→伪精确,泄露性质不变;反而增加可信感更易被引用 |
| 用黑名单剔除已知数值字段 | 新增列默认暴露,防线会随 schema 演进失效 |
| 分桶阈值开放给用户配置 | 无评测基准的调参会让不同存档的 LLM 行为不可比;#29 的诉求是硬约束而非可调项 |
| 让 LLM 自己把数字转成定性描述 | 数字已在上下文中,转换不构成防护;且引入不可控的模型行为 |

## 正面后果

- 「原始数值不出域」从文档约束变成**代码级不变量**,并有测试守门。
- 滞回让 LLM 看到的状态标签稳定,减少「上轮说偏高这轮说普通」的自相矛盾。
- 类型收紧(`float` → `str`)把违规变成**编译/类型级错误**,而非需要人工审查的隐患。
- 白名单机制使未来新增记忆列**默认安全**。

## 负面后果

- 排查检索/状态质量问题时,上下文里看不到数值,可见性下降;需要靠**调试日志**补偿(记分桶输入/输出到日志,而非 prompt)。
- 五档丢掉了原值的分辨力:57.4 与 61.0 都显示「偏高」,对细粒度状态演化的观察变粗。
- `MARGIN = 2.0` 是经验值,未做敏感性测试;过大则状态标签迟钝,过小则等于无滞回。
- 滞回状态存在 `PromptComposer` 实例上,属**进程内易失状态**:重启后首次观测直接落档,离线推演与在线会话可能给出不同首轮标签。

## 验收与不可回退声明

- 验收:`test_prompt_qualitative.py` 8 项通过,且全套件 182 项全绿。
- **不可回退**:任何新增 prompt 路径若携带角色状态,必须走 D1 分桶;不得新增「仅此一处例外」的原始数值入口。若确需放宽,必须先修订本 ADR 并说明评测依据。
