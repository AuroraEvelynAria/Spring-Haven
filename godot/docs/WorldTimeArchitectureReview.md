# Spring Haven world_time 架构评审(ADR)

- 日期:2026-09-12
- 评审基线:commit `3fc1bc6`(P0/P1 整改完成后)
- 性质:架构决策记录(ADR)。评审对象为 world_time 单时钟、`<<STATE_DELTA>>`、分桶滞回摘要、WebSocket 推送、有状态会话层、单写队列的设计方案,与存量代码交叉对照。评审发现的高优先级事项已拆分为 issue #22-#28。
- 裁决说明:评审初稿的三处可选方案争议(SQLite 并发模型、事件溯源深度、多实例策略)已按 Alpha 迭代成本裁决,见 ADR-2/ADR-1/ADR-3。

---

## ADR-1:生理状态唯一真相源 = Companion Core 后端

**决策**:Companion Core 后端是角色生理状态的唯一真相源。Godot 客户端移除本地 tick 衰减与状态修改逻辑(`LifeSimulation` 的 30s tick、`InteractionRules`/`Global.commit_user_message` 的 delta 结算链路),只保留 UI 渲染与交互意图上报。

**理由**:现状客户端 `stats_by_role` 与后端 `life_state` 是两份独立推进的状态(双头真相),靠 `/life/sync` 快照缝合。引入 `<<STATE_DELTA>>` 与后端驻留推演后,快照覆盖(last-write-wins)会丢失增量,在线/离线切换必然产生状态漂移。

**存储**:后端内存 + SQLite 状态快照;同时记录变更事件日志(delta + world_time),事件日志**仅用于调试与排查**,不做运行时重放。

**预留**:完整事件溯源(状态 = 事件重放)为第二阶段评估项,Alpha 不实施。

**迁移注意**:客户端交互按钮/自然语言命中的确定性 delta 结算链路(`InteractionRules.make_effect_spec` → `commit_user_message`)整体上收到后端;`/life/sync` 语义从"双向快照合并"改为"客户端拉取只读快照"。

## ADR-2:SQLite 并发模型 = thread-local 连接 + WAL + busy_timeout + 短事务

**决策**:Alpha 采用每线程独立连接(to_thread 场景即 worker 线程各自连接)+ WAL + `busy_timeout` + 短写事务。`check_same_thread=False` 的共享连接与 RLock 在 to_thread 迁移完成后退役。

**理由**:单写队列能彻底消除写争抢,但需要自建队列、重试、事务边界与错误处理;thread-local + WAL 在单用户量级即可满足,爆发写入(离线推演批量记忆)依赖 busy_timeout 排队是可接受的折中。

**预留**:出现真实锁压力时再引入单写工作线程(全局唯一写连接)作为优化。

## ADR-3:单实例运行

**决策**:Alpha 以文档约束"同一时间只运行一个 Godot 客户端实例";多实例/多客户端协议(连接声明、WS 广播、会话所有权)为中长期待办。

---

## 硬性约束:原始生理数值不出域(never raw numbers to the LLM)

**约束**:LLM 绝不允许直接读取原始生理浮点数值(0-100 数字)。所有给到 LLM 的角色状态信息,只能是后端基于 RoleState 原始数值、经过【分桶+滞回】转换后的纯定性文本摘要(很高/偏高/普通/偏低/很低);原始浮点数永远不进入 prompt 上下文。

**现状审计结论:现有实现未守住该边界**,存在两条直接泄露路径与一条相邻路径(issue #29 跟踪):

1. **直接泄露 A**:`prompting.py` runtime 块 `body_state.stats` —— 11 项 0-100 浮点(health/stamina/hunger/thirst/awake/urine/intimacy/mood/stress/fertility/implantation)经 `round(±100 钳位, 2)` 后每轮每角色原样进入 user 消息。
2. **直接泄露 B**:`prompting.py` `life_lab_event.needs_by_role` —— Life Lab 社交事件中每个参与者的 hunger/thirst/stamina/mood 四项浮点进入 prompt。
3. **相邻路径 C**:HEARTLOOM 记忆条目携带 `confidence`/`importance`(0-1 浮点)与 `updated_at`(unix 整数)元数据 —— 非 0-100 生理值,但同属"裸数字进上下文",应定性化(高/中/低)或剔除。
4. **合规项**:`sensations` 已是定性文本;`interaction_context` 不含数值;`menstrual_cycle` 的天数属时间语义(已有 `day_description` 受控模板),建议最终仅保留模板文本、移除裸数值字段。
5. **输出方向不受此约束**:`STATE_DELTA` 是写入指令而非读取;但解析器的日志与事件记录不得把数值回显进后续上下文。

**结构性根因**:泄露不是过滤遗漏,而是数据来源问题 —— runtime 块的 `body_state` 由**客户端上报**,后端只做白名单转发。ADR-1(状态唯一真相源迁后端)落地时,客户端 `body_state` 应整体不再进入 prompt,由后端从自身 RoleState 经分桶层生成定性摘要;`allowed_stats` 白名单机制随之退役。

**守护方式**:#29 验收包含结构断言测试(解析 runtime JSON,断言无 stats/needs 数值键)与"数字审计"测试(按字段名+数值配对断言,而非裸正则,避免误伤"第 3 天"这类合法时间文本)。

---

## 高优先级(Alpha 必须,issue #22-#29)

按落地顺序,**前三项是其余事项的前置**:

| # | 事项 | 说明 |
|---|------|------|
| #22 | 生理状态唯一真相源迁移到后端 | 移除 Godot 本地 tick 衰减与状态修改;快照+事件日志存储;最高优先 |
| #23 | world_time 单时钟落地与 real-time 残留清点 | outbox TTL(现为现实 7 天)、digest 12h 冷却、weekly ISO 周键、记忆 half-life、生命周期/里程碑判定的全部时间基准迁移;SCHEMA_VERSION 6;旧档回填规则;倍率下记忆衰减体感调参 |
| #24 | 状态摘要移至消息尾部,保护前缀缓存 | 摘要放本轮 user 消息紧前方而非"动态前置",否则任一角色翻越分桶边界即作废全部历史缓存,76% 命中率失效 |
| #25 | 统一结构化输出信封规范 | RUNTIME/HEARTLOOM/scene_action/STATE_DELTA 单一解析器、单信任源、转义规则、嵌套与共存优先级;STATE_DELTA 需 role_id 白名单 + 单次钳位 + 每 world_time 小时每字段累积速率闸门 |
| #26 | 离线驻留推演限流 | 驻留推演 = 纯规则模拟 + 事件日志(零 LLM);digest/周反思/角色社交 LLM 调用延后到返回时合并生成或限速队列;否则倍率线性放大调用密度 |
| #27 | 会话键与会话生命周期正式定义 | 会话键 `(journey_id, session_kind, participant_set)`;会话内存上下文与 Heartloom 持久化的存储边界;failover 重建的成本预算(缓存全冷) |
| #28 | WS 推送设计补全 | 握手鉴权、心跳、以 world_time 为单调序号防降级轮询乱序、降级切换粘滞;推送粒度 = 分桶翻越/事件(不推浮点抖动),UI 两次推送间用已知衰减速率本地插值 |
| #29 | 硬性约束:原始生理数值不出域 | 分桶+滞回定性摘要层落地;移除 runtime 块 stats 与 needs_by_role 数值;记忆元数据定性化;结构断言 + 数字审计守护测试(详见上方硬性约束章节) |

## 中优先级(第二阶段)

- 记忆向量召回:复用现有 embedding 基建,补词法+图检索的语义短板
- 显式记忆生命周期(Active/Dormant/Archived):检索默认只扫 Active,收敛大记忆量扫描范围
- 传播链冲突检测:二手记忆(heard_from_*)与后续第一手经历的仲裁
- 记忆图增量边计算:替代每次全量 O(n²)(to_thread 只解决阻塞不解决复杂度)
- 多实例/多客户端连接协议

## 低优先级(架构预留,暂不实现)

- 完整事件溯源(状态 = 事件重放)
- 多角色(>3)拆分协同会话的完整编排协议
- 存档内时间旅行/回档分支
- DMAE 式完整证据链审计视图

---

## 与存量代码的冲突清单(评审要点备份)

1. 状态权威三头:客户端规则 delta(commit_user_message)/ 后端规则衰减 / LLM STATE_DELTA —— 由 ADR-1 + #25 边界规则收敛。
2. DeepSeek 前缀缓存依赖稳定前缀,与"动态前置片段"冲突 —— 由 #24 尾部放置收敛。
3. 离线倍率线性放大 LLM 触发密度 —— 由 #26 收敛。
4. outbox TTL、digest 冷却、weekly 周键、half-life 均为现实时间语义 —— 由 #23 清点迁移;**#6 已上线的 7 天现实 TTL 在倍率下会批量丢弃离线消息,属于 #23 的第一梯队迁移项**。
5. "无变更无通信"与连续衰减矛盾 —— 由 #28 推送粒度定义收敛。
6. `/chat` 无状态(客户端回传历史)与会话层有状态并存 —— 由 #27 定义边界。
7. 单写队列(设计)与 RLock 共享连接(现状)与 to_thread(#4 已迁)三模型并存 —— 由 ADR-2 定终态,过渡期不混入新模型。
8. 原始生理浮点经 runtime 块与 life_lab needs_by_role 直接进入 LLM 上下文 —— 由 #29 分桶定性层收敛(硬性约束)。
