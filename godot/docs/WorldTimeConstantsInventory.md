# 世界时间常量清点清单（#23 验收物）

> 本文件是 issue **#23「world_time 单时钟落地」** 的验收物之一，对应其验收条款
> *「时间常量全局清点清单入文档」*。
>
> 清点依据：`companion-core/src/spring_haven_core/` 全量检索（`time.time()` /
> `real_unix` / `since_unix` / 命名常量）。
> 设计依据：[`WorldTimeArchitectureReview.md`](WorldTimeArchitectureReview.md)（ADR，三项折中裁决）。

## 0. 判定口径

| 归类 | 含义 |
|---|---|
| 已迁移（世界时间） | 语义已由 `journey_clock.world_now(save_id)` 驱动，倍率（rate≠1）下行为正确 |
| 待迁移 | 语义仍是现实时间，倍率下会失真 —— **#23 剩余工作** |
| 合法现实时间 | 本质就应使用现实时钟（运维、外部 API、缓存 TTL、运行时防抖），不随世界倍率缩放 |

换算入口（唯一语义读时钟点）：`HeartloomStore.world_now()` / `world_from_real()`
（`memory.py:232-237`，注释自述「唯一读取现实时钟的位置」）。

## 1. 命名常量（已迁到世界时间）

| 常量 | 值 | 单位 | 位置 |
|---|---|---|---|
| `LIFE_OUTBOX_TTL_WORLD_DAYS` | 7.0 | 世界天 | `memory.py:20` |
| `DORMANT_AFTER_WORLD_DAYS` | 14.0 | 世界天 | `memory.py:22` |
| `USER_TURN_REINFORCEMENT_WINDOW_WORLD_DAYS` | 2.0 | 世界天 | `memory.py:28` |
| `ARCHIVE_CONFIDENCE_THRESHOLD` | 0.15 | 非时间量 | `memory.py:23` |
| `WAKE_REWARD_PER_RECALL` / `WAKE_REWARD_CAP` | 0.05 / 1.0 | 非时间量 | `memory.py:25,29` |

- 记忆衰减与 recency：`memory.py:1148` ——「衰减/recency 全部基于 world_time（世界天），不再读取现实时间」。
- outbox TTL 计算：`memory.py:2434,2583` —— 按世界天，现实时间仅经 `journey_clock` 换算。
- 冻结测试：`tests/test_world_time.py::WorldClockTests::test_constants_are_frozen`。

## 2. 待迁移（#23 剩余工作）—— ✅ 已全部完成（2026-09-27，schema v7）

原四项遗留已随 **schema v7**（`migrations/v7_world_time_digest.sql`）收尾：

| 项 | 原位置/现状 | 迁移后 |
|---|---|---|
| **周反思周键** | `service.py _iso_week_key()` 现实 ISO 周 | 已删除；改为**各存档自己的世界周键** `world-w{week:04d}`（`run_due_weekly_insights`） |
| **周反思 7 天窗口** | `timestamp - 7 * 86_400` 现实秒 | 窗口 = 当前世界周桶 `[7n, 7n+7)` 世界日（`recent_digest_memories(since_world=…)`） |
| **digest 查询/分桶窗口** | `recent_digest_memories(since_unix=…)` 现实 unix | `digest_day_events(world_day=…)` / `digest_pending_saves` 全按 `life_events.world_occurred_at`（世界日键 `w{day:04d}`）；原 12h 现实冷却由「该世界日已结束」判定取代 |
| **milestone first_digest 范围** | `recent_digest_memories(since_unix=0)` 现实 created_at | `since_world=-1.0`，按 world_created_at 判定 |

**旧档幂等映射（v7 回填，两项）**：
1. 既有 `life_events` 按当前时钟线性映射出 `world_occurred_at`（钳 0，防补报旧事件落负世界日）；
2. 既有 `digest_state` 的现实日期键按同口径映射出 `w{day:04d}` 新键（`INSERT OR IGNORE`，旧键保留）。

周反思的重复生成防护**不靠改写旧 `weekly-*` source_event_id**：新增
`weekly_insight_exists_in_world_week()`，当前世界周桶内已存在任何 `weekly_insight`
记忆（含旧现实周键存量，其 `world_created_at` 已由 v6/v7 映射）即跳过本周期。

## 3. 合法现实时间（不应迁移）

| 用途 | 位置 | 说明 |
|---|---|---|
| 迁移 / 备份时间戳 | `maintenance.py:54` | 运维动作，现实时钟正确 |
| `real_unix` 列 | `memory.py:460,921,1642` | schema 明确保留的双时间戳之一，仅调试用 |
| 旅程锚点 | `memory.py:253 anchor_real` | 现实锚点 + 世界值，是换算基准本身 |
| provider 熔断时间 | `provider.py:861,980` | 外部服务健康度，不应随游戏倍率缩放 |
| 天气缓存 TTL | `weather.py:36 CACHE_SECONDS = 30 * 60` | 外部 API 配额保护 |
| 组织器 / 召回节流 | `memory.py:2965,2977` | 30s / 60s 运行时防抖，现实秒正确 |
| 记忆 / 事件写入时间戳 | `memory.py` 多处 `int(time.time())` | 写入 `real_unix` 或日志列，不影响模拟语义 |

## 4. 旧档迁移与演练

- `SCHEMA_VERSION = 7`（`memory.py:18`）；v6：`migrations/v6_world_time.sql`，v7：`migrations/v7_world_time_digest.sql`（各带回滚稿）。
- 回填约定：世界时钟零点 = 迁移时刻；旧记忆按存档内最早 `real created_at` 的相对偏移（天）映射；v7 起旧 `life_events` / `digest_state` 按当前时钟线性映射（钳 0）。
- 演练覆盖：`tests/test_world_time.py::MigrationDrillTests`（9 例：v6 旧档回填、备份幂等、前向兼容守卫、v7 世界日回填、digest_state 键映射、v7 幂等）。
- TTL / 倍率行为：`WorldTtlTests`（3 例）+ `WorldClockTests::test_rate_scaling_advances_world_time_faster`。

## 5. 结论

**#23 完成（2026-09-27）。** 记忆衰减 / recency / outbox TTL / 迁移链 / 时钟换算 /
**digest 分桶与窗口 / 周反思周键与窗口 / 里程碑扫描范围**已全部切到 world_time，
旧档映射回填与演练齐备。仅存的现实时间使用见第 3 节（均为合法用途）。

建议迁移顺序：**周键 → 7 天窗口 → digest 查询**，并为既有 `weekly-*` 记忆补一次幂等回填测试。
