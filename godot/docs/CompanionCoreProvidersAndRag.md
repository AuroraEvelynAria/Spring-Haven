# Companion Core 模型提供商与 RAG

## 模型能力槽位

设置页已经拆为“基础设置 / AI 模型 / 知识库 / 生活模拟 / 互动规则”五类，避免把
所有开发者选项堆在同一滚动页。“AI 模型”提供四个相互独立的能力槽位：聊天、视觉、
嵌入和重排序。
每个槽位都有自己的 Base URL、模型名、协议、启用状态和可选独立 API Key。
每个槽位还提供独立连接测试，只显示模型、协议、延迟、令牌数或向量维度，不显示
Provider 回复正文与密钥。

每个槽位下方都有独立的“故障切换候选链”，最多可按优先级保存 6 个备用项。备用项可
使用不同 Base URL、模型、协议与独立 Key，也可以复用该能力主项最终解析到的 Key。
Core 只会在连接/超时、HTTP 429、HTTP 5xx 或当前候选熔断时继续尝试下一项；HTTP
400、401、403、404、422 等鉴权与请求格式问题会直接显示，不会被静默掩盖。状态区
显示当前实际候选、累计切换次数和最近原因。主项恢复并成功后会自动切回并记录恢复。

聊天和视觉候选可以使用能力兼容但质量不同的模型。Embedding 候选必须保持相同向量
维度，否则已有文档需要重新向量化；Rerank 候选需要选择与服务实际响应一致的 Jina
或 Cohere 协议。候选配置保存在 `provider_settings.json`，各候选独立 Key 与主项 Key
一起进入 DPAPI 凭据包，状态接口始终只返回脱敏元数据。

Base URL 支持 `http://IP:端口/v1`。localhost 和私有网络地址（`10.x.x.x`、
`172.16-31.x.x`、`192.168.x.x`）可以直接保存，适用于局域网中的视觉模型中转站。
公网 IP 的 HTTP 地址默认拒绝；确有需要时，可在对应能力槽位显式勾选“允许 HTTP”。
该模式会让 API Key、图片、提示词和回复以未加密形式经过网络，界面和状态页会显示
明文 HTTP 警告，公网部署仍应优先使用 HTTPS、可信反向代理或 VPN。
若用户未预先勾选，保存公网 HTTP 地址时设置页会显示中文安全确认；确认后只为当前
能力槽位启用明文 HTTP 并自动重试保存，不会降低其他模型槽位的传输要求。

视觉与嵌入默认可以复用聊天 Key，因此一枚 OpenAI API Key 可以同时驱动聊天、
视觉理解和语义检索。重排序服务往往来自不同提供商，默认使用独立 Key，但也可以
手动选择复用。

环境变量部署可以为每个能力设置
`SPRING_HAVEN_<CAPABILITY>_ALLOW_INSECURE_HTTP`，其中 `<CAPABILITY>` 可为
`LLM`、`VISION`、`EMBEDDING` 或 `RERANK`。仅视觉中转时通常只需设置视觉槽位，
不必降低其他 Provider 的传输安全性。

所有 UI 输入的密钥都只提交给 localhost Companion Core。Windows 下 Core 把多个
能力密钥合并成一个版本化 JSON 凭据包，再用当前用户绑定的 DPAPI 加密。状态接口只
返回 `api_key_configured`、`credential_source` 等布尔值和来源，不返回明文。

## 网络代理

“AI 模型”页提供三种 Companion Core 出站模式：

- **直连**：忽略系统代理环境变量；
- **系统代理**：读取 Core 进程的 `HTTP_PROXY`、`HTTPS_PROXY` 与 `NO_PROXY`；
- **自定义 HTTP 代理**：填写 `http://127.0.0.1:7890` 这类 HTTP 代理地址。

代理统一作用于聊天、视觉、嵌入、重排序和网页知识导入，但不会代理 Godot 到
`127.0.0.1:18340` 的本地通信。自定义地址不接受内嵌用户名密码，也不把凭据明文写入
配置文件；原生 SOCKS5 端口不能直接填写，应使用代理软件提供的 HTTP/mixed 端口。
保存后立即生效，不需要重启 Core。环境变量 `SPRING_HAVEN_PROXY_MODE` 与
`SPRING_HAVEN_PROXY_URL` 可在启动时覆盖 UI 保存值。

## 视觉链路

`LMStudioVisionClient` 会优先检查 Companion Core 的视觉槽位。视觉槽位启用后，
截图通过本地鉴权接口 `/vision/analyze` 发送给 Core，再由 Core 使用视觉 Provider
的 Key 调用 OpenAI-compatible `chat/completions`。Godot 不接触 Provider Key。

可信射线感知和 Godot 符号状态仍具有更高优先级；视觉模型负责补充像素层面的观察，
不能覆盖场景白名单、角色身份或可信物体状态。若 Core 视觉未配置，原 LM Studio
本地视觉链路仍可作为兼容回退。

视觉请求先在 Companion Core 内按视觉候选链切换；整个 Core 视觉链都失败后，Godot
的 `auto` 模式才尝试直接访问本地 LM Studio。因此可以把在线 Qwen/OpenAI-compatible
服务设为主项，把另一个在线服务或本地 LM Studio 设为 Core 备用项，同时仍保留旧的
Godot 本地兜底。

视觉路由支持三种诊断模式：`auto` 默认先调用 Companion Core API，失败后探测本地
LM Studio；`api` 只测试 API，不做本地回退；`local` 只测试本地模型。可通过环境变量
`SPRING_HEAVEN_VISION_BACKEND=auto|api|local` 选择。LM Studio 地址和模型可分别使用
`SPRING_HEAVEN_LM_STUDIO_URL`、`SPRING_HEAVEN_LM_STUDIO_MODEL` 指定；未指定模型时会从
本地 `/models` 自动选择 Gemma、LLaVA、Pixtral、Vision 或 VL 类模型。

## RAG 链路

RAG 数据保存在 `companion-core/user_data/knowledge.sqlite3`，与心织记忆数据库分离。

1. 用户可以粘贴正文、批量选择文件或输入网页 URL，并选择共享、小玲私有或小奈私有作用域。
2. Markdown 先按标题层级隔离章节并保存 `section_path`；只有超长章节才按字符数和重叠量继续切分。
3. 若嵌入槽位启用，Core 批量生成向量；失败时文档仍会保存并使用本地关键词召回。
4. 对话前先得到候选片段，再可选调用重排序槽位。
5. 最相关片段作为动态、只读、不可信知识块加入本轮消息，不修改稳定 System Prompt。

“知识库”页可以控制 RAG 开关、语义嵌入、重排序、注入数量、候选数量、分块大小和
重叠量，并显示文档数、分块数与向量覆盖数。文档列表支持筛选、查看原文、覆盖编辑、
删除、新建、检索测试和重新向量化。
文档列表支持多选后批量修改作用域、按当前章节规则重新分块和确认删除。重复导入同一
来源会更新原文档，相同作用域下完全一致的正文会去重。

文件导入支持 TXT、Markdown、JSON/JSONL、CSV/TSV、HTML、DOCX 与 PDF。DOCX 使用
标准 Office XML 提取，PDF 使用 `pypdf` 读取文本层；纯扫描 PDF 不会静默导入空内容，
需要先经过 OCR。网页导入只允许远程 HTTPS，本机 localhost 调试可使用 HTTP；URL 中
不能嵌入账号密码、服务端不跟随重定向，并限制下载体积和最终正文长度。

## 当前边界

- PDF 暂不提供 OCR，扫描件需先转换为带文本层的 PDF 或纯文本。
- 网页导入提取当前响应正文，不执行 JavaScript，也不自动爬取站内链接。
- 尚未加入文件夹监听、文档版本历史与 Workshop 包签名；这些属于发行版导入治理层。
