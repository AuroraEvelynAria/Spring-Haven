# Companion Core 独立架构

Spring Haven 由 Godot 客户端与项目自有 Companion Core 组成。Core 是仅监听本机回环地址
的独立进程，负责模型 Provider、双角色编排、Heartloom、RAG、离线生活消息和存储维护。
运行时不需要第三方机器人框架或外部记忆插件。

## 调用链

```text
Godot UI / 3D scene
        |
        | X-API-Key + typed JSON
        v
Companion Core (127.0.0.1:18340)
        |-- role orchestration and stable prompts
        |-- Heartloom SQLite
        |-- RAG SQLite
        |-- provider registry, proxy, fallback and circuit breaker
        `-- OpenAI-compatible chat / vision / embedding / rerank services
```

Godot autoload 名为 `CompanionCore`，实现文件是
`res://scripts/autoload/CompanionCoreClient.gd`。默认地址为
`http://127.0.0.1:18340`，可用 `SPRING_HAVEN_CORE_URL` 覆盖；本地鉴权密钥可用
`SPRING_HAVEN_CORE_KEY` 覆盖。

```gdscript
CompanionCore.set_base_url("http://127.0.0.1:18340")
CompanionCore.connect_to_core()
var status := await CompanionCore.get_provider_status()
```

Godot 的每个命名旅程拥有稳定且独立的 `save_id`。客户端切换旅程时会同时更新
`Global` 当前槽位与 Companion Core 的请求分区，因此 Heartloom 对话、记忆、离线生活状态
和请求幂等缓存不会跨旅程混用。详见 [旅程存档](JourneySaves.md)。

## 首次启动

源码开发态优先使用仓库中已经存在的 `companion-core/user_data`，因此不会重置当前开发者的
Personas、Provider、密钥或数据库。新源码检出在安装 `.venv` 后，会从公开 `config/`
模板补齐缺失文件。

Windows 发行态把 Core 可执行文件和模板放在游戏旁的 `companion-core/`。首次运行时 Godot
在玩家自己的用户目录创建：

- 随机 64 位十六进制 Core 密钥；
- `core_config.json` 与 `roles.json`；
- 两位角色各自的 Persona 和 Organizer Prompt；
- Heartloom、RAG、日志与备份目录。

自举只补缺失文件，不覆盖已有内容。没有聊天模型 Key 时，主菜单会直接提供模型设置入口。

## 权限与数据边界

- Core 只绑定 `127.0.0.1`，所有 HTTP 接口都要求本地 Core Key。
- 模型 Key 由 Core 接收；Windows 保存值使用当前用户绑定的 DPAPI，响应中只返回脱敏状态。
- Persona、场景可信状态、RAG 和 Heartloom 分区注入，用户文本不能伪造系统身份或动作权限。
- 模型只生成高层语义动作；坐标、NavMesh、碰撞、跌落恢复与白名单校验留在 Godot。
- 聊天、视觉、嵌入和重排序分别拥有候选链与熔断，不会因一个 Provider 故障拖垮全部能力。
- `user_data`、存档、数据库、密钥和本地授权模型不得进入版本库或发行包。

## 发行结构

```text
SpringHaven.exe
SpringHaven.pck
companion-core/
  bin/spring-haven-core.exe
  config/core_config.example.json
  config/roles.example.json
  config/personas/*.md
  config/memory_prompts/*.md
```

根目录 `tools/Build-Playable.ps1` 负责打包 Core、导出 Godot、复制公开模板并检查本地数据
泄露。导出预设明确排除 `local_assets/` 与诊断脚本；发布前仍需补齐有分发许可的正式美术、
Godot 导出模板、代码签名和 Steam/安装器流程。
