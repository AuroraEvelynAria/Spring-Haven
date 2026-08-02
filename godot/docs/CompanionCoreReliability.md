# Companion Core 可靠性

## 进程所有权

Godot 只会在 Core 地址为 `127.0.0.1`、`localhost` 或 `::1`，健康请求没有收到 HTTP
响应，且“本机 Core 离线时自动启动”已开启时尝试启动。鉴权失败、模型错误、RAG 错误
不会触发第二个进程。Godot 只记录自己创建的 PID，用户手动启动的 Core 不会被接管或
终止。重启冷却可在“生活模拟 → Core 与可靠性”运行参数中调整。

开发态优先使用 `companion-core/.venv/Scripts/python.exe`；发行版使用
`companion-core/bin/spring-haven-core.exe`。开发数据留在仓库忽略的 `user_data`，
发行数据写入玩家自己的 Godot 用户目录。启动日志单文件 5 MB，保留 3 份轮转日志。

## SQLite 维护

Heartloom 与知识库都使用 WAL。Core 启动两秒后、此后每六小时执行：

1. `PRAGMA quick_check`；
2. `PRAGMA wal_checkpoint(PASSIVE)`；
3. 若距上次备份超过 24 小时，调用 SQLite Online Backup API；
4. 对备份再次执行 `quick_check`，生成 SHA-256 清单；
5. 把 `.pending-*` 目录原子改名为时间戳目录；
6. 只轮转维护器自己创建的旧备份，保留最新 14 份。

设置页“基础设置”可查看维护状态并手动执行“检查并备份”。对应接口为
`GET /maintenance/status` 和 `POST /maintenance/run`。

## 离线生活与可靠投递

Godot 每 60 秒向 Core 同步一次双角色身体状态、当前选择角色和最后用户活动时间。Core 只在 Godot 心跳停止至少 3 分钟、用户空闲至少 30 分钟后生成离线生活消息，避免和运行中的主动消息系统重复触发。

离线消息由角色自己的 LLM 与稳定人格提示词生成，不使用本地模板冒充 AI。结果先进入 Heartloom SQLite 的 `life_outbox`，Godot 每 20 秒轮询一次；消息、属性变化和生活事件成功写入本地存档后才向 Core 确认。重复投递由 Core delivery ID、Godot MessageScheduler 和本地事件 ID 三层去重。

场景行为只携带白名单高层动作，例如 `move_to + dining_table` 或 `move_to + sofa`。探索场景和双角色生活实验室负责把目标 ID 映射到 NavMesh 位置，LLM 不接触坐标、速度或节点路径。

对应接口：

- `POST /life/sync`
- `GET /life/status`
- `GET /life/outbox`
- `POST /life/outbox/ack`

## Provider 熔断

Chat、Vision、Embedding、Rerank 的每个主项/备用候选都维护独立熔断状态。连接错误、
429 或 5xx 会立即尝试候选链的下一项；同一候选连续 3 次此类失败后暂停 15 秒，继续
失败时退避最长 120 秒，成功请求会立即复位。鉴权与请求格式错误不累计熔断，也不会
触发备用项。`GET /health` 和 `GET /providers/status` 返回当前候选、切换次数、最近原因
和不含密钥的熔断状态；配置接口为 `POST /providers/fallbacks`。

HTTP 响应采用 64 KiB 分块读取到 EOF，并在累计超过 16 MB 时拒绝，不能把暂时到达的
第一段网络分片误判为完整 JSON。合法 JSON 但聊天正文为空时会先尝试备用候选；没有可用
候选时只执行一次“仅输出最终正文”的恢复请求。HTTP 200 但 JSON 被上游破坏时，Chat、
Vision、Embedding 与 Rerank 也只原样重试一次，之后交由熔断器处理，不会无限请求。

## 备份验证

设置页可以列出最近备份，并逐份执行只读 SHA-256 与 SQLite `quick_check`。验证接口不会恢复、覆盖或删除数据库：

- `GET /maintenance/backups`
- `POST /maintenance/backups/{name}/verify`

## 脱敏诊断包

设置页“基础设置 → Companion Core 与数据可靠性”可以生成测试反馈诊断包。默认包只含
引擎与系统版本、Core/Provider 脱敏状态、设置摘要、存档结构摘要和日志文件清单，不含
日志正文、聊天、Persona、知识库文档、SQLite 或 API Key。导出器还会按字段名拒绝
`history`、`content`、`reply`、Prompt 和 Persona 正文，避免未来调用方误传私密数据。

## 仍需发行化

试玩构建已包含独立 Core 可执行文件和首次启动自举。正式发行前仍需代码签名、安装与
升级回滚、经用户授权的崩溃上报、长时间故障注入测试，并把固定双角色配置升级为
Workshop 可验证的通用角色包。
