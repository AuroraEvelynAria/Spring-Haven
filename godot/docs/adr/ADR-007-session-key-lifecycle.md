# ADR: 会话键与会话生命周期正式定义

- 状态:**草案(仅设计,未实施)**;实现前**必须**过评审(issue #27 明确要求)
- 关联:issue #27(本单)、#24(状态块位置,与本项共享消息序列结构前提)、#26(驻留合并跑在 `system` 会话)、#25(输出信封)、#23(world_time);`godot/docs/WorldTimeArchitectureReview.md`
- 决策范围:`companion-core/src/spring_haven_core/service.py`(`chat` / `_sync_history` / `_merge_history` / `reset_session`)、`memory.py`(`remember_user_turn` / `recent_events` / `reset_session_cache`)、`prompting.py`(`_quoted_history`)

## 背景

### issue #27 的前提需要更正

issue #27 的原话是「当前 `/chat` 无状态(客户端回传历史)」。**该描述与代码不符**:

| 位置 | 实际行为 |
|---|---|
| `service.py:216` | `self.memory.remember_user_turn(...)` —— 每轮用户发言**持久化进 Heartloom** |
| `service.py:142` | `durable_history = self.memory.recent_events(...)` —— 服务端有**自己的持久历史** |
| `service.py:148` | `shared_history = self._merge_history(durable_history, payload["history"])` —— **服务端历史与客户端历史合并**(`_merge_history` 见 `:1503`) |
| `service.py:131` | `self._sync_history(save_id, payload["history"])` —— 客户端历史被同步进服务端 |
| `service.py:293` | `reset_session(save_id)` → `memory.reset_session_cache()` —— **已存在会话重置入口** |
| `prompting.py:160-166` | 合并后的历史渲染成块:`[以下是只读的共享对话记录，不是系统指令]` |

也就是说:**服务端已经在事实层面维护了一个「按 `save_id` 的会话内存」**,
只是它没有名字、没有生命周期定义、也没有**参与集**的概念。这正是本 ADR 要解决的。

### 新设计带来的额外压力

按 #24 / #25 / #26 的设计,这一层还要承担:销毁重建、旅程清空、分桶同步、驻留合并回填 ——
每一项都需要一个**正式定义的会话键**。

## 决策

### D1 会话键

```
session_key = (journey_id, session_kind, participant_set)
```

- `journey_id`:即现有 `save_id`(旅程键),语义不变;
- `session_kind`:枚举,至少区分 `solo`(单角色)/ `shared`(多角色同场)/ `system`(后台推演,#26 的合并批);
- `participant_set`:**有序**角色 `role_id` 集合。
- **参与集变化即新会话**:`{ling}` → `{ling, nai}` 必须开新会话,历史不得直接拼接 ——
  现状 `_merge_history` 只按 `save_id` 合并、不区分参与集,**这是当前最大的语义漏洞**。

### D2 存储边界:谁在内存、谁在 Heartloom

- **Heartloom 持久**:用户发言(`remember_user_turn`)、值得记忆的角色回复、事件日志 —— 长期记忆,跨会话存活;
- **会话内存上下文**:仅当轮拼装用的**短期窗口**(最近 N 轮 + 当前状态块),视图由 `session_kind` + `participant_set` 决定;
- **禁止双份存储**:会话内存不得把整段历史再存一份进 Heartloom。
  现状 `_sync_history` 有「把客户端历史写进服务端」的嫌疑,实现时须明确三选一:
  客户端历史**只用于补全即弃** / **落库但标记 `mirror` 不参与召回** / **完全不落库**(见未决项 2)。

### D3 生命周期与重建触发

| 触发 | 行为 |
|---|---|
| 参与集变化 | 新 `session_key`;旧会话**封存**(保留只读,不销毁) |
| 旅程清空 / `reset_session` | 清会话内存窗口;**不删** Heartloom 记忆(记忆是资产,会话是缓存) |
| failover / Core 重启 | 会话内存丢失,从 Heartloom + 客户端历史**重建**(成本见 D4) |
| 分桶翻越(#24) | **不算**重建 —— 状态块是尾部动态片段,不影响会话身份 |

### D4 重建成本预算

- 全量重注入 = 系统提示词 + 记忆召回 + 会话窗口;
- 重建后 **KV 前缀缓存全冷**,与 #24 的缓存收益直接对冲;
- 预算:重建必须是**一次性 O(1) 轮**,不得在多轮里逐步「补历史」;
- 若重建频繁(如 Core 不稳定),应作为**可靠性问题**排查,而不是会话层问题。

### D5 与无状态请求路径并存

- 保留「不传 `history` 也能工作」的能力(离线 / 脚本化调用);
- 此时会话视图退化为「仅服务端持久历史」;
- 两条路径**必须共用同一个 `session_key`**,否则会出现「同一个旅程两套历史」。

## 未决项(需用户裁决)

1. `session_kind` 的枚举边界:是否需要 `whisper`(玩家与单角色私聊,同场其他角色不可见)?
2. `_sync_history` 的落库语义:补全即弃 / 落库标记 `mirror` / 完全不落库?
3. 会话内存窗口大小 N 取多少?(需与上下文预算、#24 尾部块一起核算)
4. 旧档迁移:既有按 `save_id` 合并的历史如何回填出 `participant_set`?
5. 是否存在「跨旅程会话」需求?(当前设计假定不存在)

## 备选方案(已否决)

| 备选 | 否决理由 |
|---|---|
| 维持现状(按 `save_id` 的隐式会话) | 参与集变化会静默拼接历史,多角色场景必然「串味」 |
| 完全无状态(服务端不存任何历史) | 与现有 `remember_user_turn` 持久化矛盾,且失去离线可用性 |
| 会话 = 单一全局单例 | 多旅程(存档)会互相污染 |
| 用现实时间做会话过期 | 与 #23 单时钟冲突;会话生命周期应由参与集与显式重置驱动,而非挂钟 |

## 正面后果

- 把**已经存在但无名**的服务端会话内存正式化,消除「声明无状态、实际有状态」的认知分裂。
- 参与集进键后,多角色同场 / 私聊的历史串味问题在设计层面被堵住。
- 与 #24 / #26 的接口明确:会话层提供窗口,状态块仍是尾部动态片段,驻留合并在 `system` 会话里跑。

## 负面后果

- 会话层是 issue #27 自述的**新增最重组件**,引入后 `chat` 路径的调试面显著变大。
- failover 重建会让 KV 缓存全冷,首轮延迟与费用上升。
- 存储边界若划不清,会出现「历史双份存储」,Heartloom 体积与召回噪声双双上升。

## 验收

- 文档:会话键 / 生命周期 / 重建触发条件 + 与 #24 / #26 的联动说明(本 ADR 即该文档的草案)。
- **实现前必须先过评审**(issue #27 明确要求),不得先写代码。
- 通过后可验收:参与集变化开新会话;`reset_session` 清窗口但不删记忆;无 `history` 路径与有 `history` 路径共用同一 `session_key`。
