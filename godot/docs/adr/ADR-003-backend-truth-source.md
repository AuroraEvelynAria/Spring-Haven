# ADR: 生理状态唯一真相源迁移到后端——Phase 1 现状与 Phase 2 待定项

- 状态:**Phase 1 已落地**(2026-09-13,commit `5013221`/`d00959f`);**Phase 2 未实施**,需用户裁决
- 关联:issue #22(Phase 1 已落地 / Phase 2 未做)、#23(world_time 单时钟)、#25(结构化输出信封,Phase 2 前置)、#26(离线驻留推演);`godot/docs/WorldTimeArchitectureReview.md` ADR-1
- 决策范围:`companion-core/src/spring_haven_core/service.py`、`memory.py`;客户端 `godot/scripts/autoload/LifeSimulation.gd`、`Global.gd`

## 背景

`WorldTimeArchitectureReview.md` ADR-1 已裁决「Companion Core 后端是角色生理状态的唯一真相源」,理由是客户端 `stats_by_role` 与后端 `life_state` 原本是**两份独立推进的状态(双头真相)**,靠 `/life/sync` 快照缝合;引入 `<<STATE_DELTA>>` 与后端驻留推演后,快照覆盖(last-write-wins)必然丢失增量,在线/离线切换会产生状态漂移。

Phase 1 的目标不是一次性搬完结算逻辑,而是**先把「真相源」这个身份确立下来**,并建立增量上报与调和的协议地基。

## 决策(Phase 1,已落地)

### D1 `state_truth_source` 开关,默认 `client`

- `service.py` 构造参数 `state_truth_source: str = "client"`,内部规整为 `"backend"` 或 `"client"`(非 `"backend"` 一律回落 `"client"`)。
- `/life/sync` 的响应携带 `"truth_source"` 字段,客户端据此调整行为。
- 客户端 `LifeSimulation.gd` 持有 `var _backend_truth := false`,由 `_apply_backend_truth(data)` 依据响应中的 `truth_source` 置位。
- **默认 `client` 是刻意的**:Phase 1 不改默认行为,开关用于灰度与回退。

### D2 `decay_state` 是后端独占的保留键

- 权威衰减状态存放在 `life_state` 快照的保留键 `decay_state` 内,**客户端永不写入**。
- 结构:`{ role_key: { "stats": {...}, "decay_world": {...} } }`。
- `sync_life_state()` 在合并客户端上传快照时,`decay_state` 以后端已有值为准,不从客户端快照取值(避免客户端覆盖权威状态)。

### D3 按角色 world_time 水位线推进

- 衰减以**每角色各自的 world_time 水位线**推进,而非全局统一时间戳。
- 理由:离线驻留推演与在线会话的时间推进速率可以不同,角色间也会因离线时长产生差异;单一水位线会把快进量错误地施加到所有角色。

### D4 `decay_scales`:时间缩放系数

- 支持 `life_time_scale`(全局)与 `role_scales`(按角色覆盖),用于把「现实时间」映射到「世界时间」的衰减速率。
- 离线期间的衰减续算依赖它:没有缩放系数,离线推演无法与在线推进保持一致的世界时间语义。

### D5 客户端增量上报:`stat_deltas` → `interaction_delta` 事件

- 客户端把本地交互产生的属性变化累积在 `_pending_stat_deltas`,随 `/life/sync` 快照以 `snapshot["stat_deltas"]` 上报。
- 后端 `memory.py::_apply_client_stat_deltas()` 读取该字段,把增量**并入 `decay_state[role_key]["stats"]`**,而不是直接覆盖。
- 同时写入一条 `event_type = 'interaction_delta'` 的 state_events 记录,留下可追溯的变更痕迹。
- 这样「后端权威衰减」与「客户端交互结算」在**同一个状态容器**里汇合,不再互相覆盖。

### D6 `client` 模式下剥离 `stat_deltas`

- `service.py` 在 `state_truth_source != "backend"` 时,主动 `snapshot.pop("stat_deltas", None)`。
- 理由:开关关闭时不应把增量协议半开启,避免出现「既有旧快照语义又有新增量语义」的混合态。

## Phase 2(未实施,需用户裁决)

Phase 2 = **互动结算整体迁后端 + `<<STATE_DELTA>>` 协议**。当前**未做**,且明确不作为本轮自主实施范围。前置依赖:

1. **#25 结构化输出信封规范** —— `STATE_DELTA` 需要稳定的信封契约(含速率闸门),否则 LLM 输出的增量结构不可校验。
2. **#23 单时钟落地** —— 结算迁移后若仍存在现实时间残留,衰减语义会再次分裂。

### Phase 2 实施时应先读的代码

- `memory.py::advance_life_decay()` —— 现有后端衰减入口(`state_truth_source=client` 时 no-op)。
- `memory.py::sync_life_state()` —— 快照合并与 `decay_state` 保留键处理。
- `memory.py::_apply_client_stat_deltas()` —— 增量并入协议,Phase 2 后此路径应由「客户端上报」转为「LLM 输出驱动」。
- `service.py` 的 `truth_source` 分支 —— 决定哪些字段进出响应。

### Phase 2 的迁移注意(承自 ADR-1)

- 客户端交互按钮/自然语言命中的确定性 delta 结算链路(`InteractionRules.make_effect_spec` → `commit_user_message`)整体上收到后端。
- `/life/sync` 语义从「双向快照合并」改为「客户端拉取只读快照」。
- 客户端 `LifeSimulation` 的 30s tick 与本地衰减必须一并移除,否则又是双头。

## 备选方案(已否决)

| 备选 | 否决理由 |
|------|----------|
| 一次性把结算全部迁后端(不分 Phase) | 同时改动衰减语义、结算链路、前端上报与提示词协议,回滚面过大且无法灰度 |
| 保持双头真相,加强 `/life/sync` 合并策略 | 增量丢失是**信息论问题**,不是合并算法问题;last-write-wins 无论如何调都无法保留增量 |
| 完整事件溯源(状态 = 事件重放) | schema 与双端改动过大,Alpha 阶段事件日志仅用于调试与排查,不做运行时重放(承 ADR-1) |
| Phase 1 直接默认 `backend` | 缺 #23/#25 地基时默认切换会让衰减与结算语义立刻分裂 |
| 让客户端继续持有权威衰减,后端只镜像 | 与「后端为唯一真相源」的裁决相反,且离线推演无法在客户端安全进行 |

## 正面后果

- 「真相源」身份明确:后端持有权威衰减状态,客户端不再自行推进权威状态。
- 增量协议落地后,在线/离线切换不再依赖快照覆盖,漂移面收窄。
- `decay_state` 保留键把旧快照结构与新权威状态**并存于同一容器**,迁移期无需 schema 破坏性变更。
- per-role world_time 水位线为 #26 的离线推演限流预留了正确的推进语义。

## 负面后果

- **迁移期存在两种模式**:`client`/`backend` 行为不同,排障必须先确认当前 `truth_source`,认知成本上升。
- 客户端仍保留 `_pending_stat_deltas` 累积与上报逻辑,与「后端唯一真相源」在字面上存在张力;这是 Phase 1 的折中,Phase 2 未完成前不应把它当作终态。
- `decay_scales` 的时间缩放若配置不当,会直接表现为「角色状态掉得比预期快/慢」,且不易与真实逻辑错误区分。
- `interaction_delta` 事件日志会随交互持续增长,需要维护侧归档策略。

## 验收(Phase 1)

- `/life/sync` 响应带 `truth_source`;`client` 模式下 `stat_deltas` 被剥离。
- `backend` 模式下:客户端上报增量 → 后端并入 `decay_state` → 写入 `interaction_delta` 事件,且不被下一次衰减覆盖。
- per-role 水位线:两个角色经历不同离线时长后,衰减量各自正确。
- 相关回归:`test_world_time.py`、`test_life_phase24.py`、`test_life_events.py` 通过;套件 182 项全绿。
