
<div align="center">
  <img src="https://github.com/user-attachments/assets/dc30093f-df9c-4ad8-9225-73855975d766" alt="春日庭院" width="100%"/>
  
  # 🌿 春日庭院
  
  <p>
    <strong>创造属于你的 AI 角色。她们拥有生命，会记得你，也会想念你——即使你不在线。</strong>
  </p>
  
  <p>
    <img src="https://img.shields.io/badge/状态-Alpha-FFA726?style=flat-square" alt="状态"/>
    <img src="https://img.shields.io/badge/引擎-Godot_4.7-478CBF?style=flat-square&logo=godotengine" alt="引擎"/>
    <img src="https://img.shields.io/badge/语言-Python_3.11-3776AB?style=flat-square&logo=python" alt="语言"/>
    <img src="https://img.shields.io/badge/许可证-MIT_&_CC--BY--NC-8B8B8B?style=flat-square" alt="许可证"/>
    <img src="https://img.shields.io/badge/无成人内容-是-4CAF50?style=flat-square" alt="无成人内容"/>
  </p>
  
  <p>
    <a href="#-这是什么">关于</a> •
    <a href="#-功能特性">功能</a> •
    <a href="#-架构设计">架构</a> •
    <a href="#-路线图">路线图</a> •
    <a href="#-快速开始">快速开始</a> •
    <a href="README.md">English</a>
  </p>
</div>

---

## 💭 这是什么？

**春日庭院** 是一款**本地优先的 AI 生活模拟器**——一个沙盒世界，你可以在其中创造、定制并陪伴那些真正“活着”的 AI 角色。

她们不是写死的 NPC。她们拥有**持久的记忆、生理需求，以及自主的日常生活**。饿了会吃，困了会睡，无聊了会四处闲逛——你说的每一句话，她们都会记得。

**你赋予她们性格。她们活出自己的人生。即使你不在，她们的世界也在继续。**

---

## 🎯 它有什么不同？

|         | 春日庭院                    | 聊天机器人 / AI 伴侣 |
| ------- | ----------------------- | ------------- |
| **角色**  | 由**你**创造和定制             | 预设、固定         |
| **记忆**  | 长期记忆 + 自然衰减 + 语义触发      | 仅短期上下文        |
| **生命感** | 会饿、会困、会闲逛——**即使离线也在生活** | 只有你说话时才回应     |
| **世界**  | 3D 空间，角色真实生活在其中         | 纯文字或静态 2D     |
| **数据**  | **本地优先**，你拥有全部数据        | 依赖云端          |
| **模组**  | Steam 创意工坊，支持角色和世界分享    | 通常封闭          |

---

## ✨ 功能特性

### 🧠 你的角色，由你定义

- **从零创建角色**——人格就是普通的 Markdown 文件：姓名、性格、背景故事、声音和外貌
- **定制知识库**——本地 RAG 引擎，支持按角色划分知识范围，带嵌入与重排序
- **通过 Steam 创意工坊**与社区分享你的创作（规划中）
- **可视化角色编辑器**（规划中）——定制服装、表情和动作

### 💬 持久记忆与情感

- **心织（Heartloom）**：带时间戳的本地记忆引擎，自然衰减、召回强化，还有可交互探索的**记忆网络图**（每条链接都可解释）
- **每日总结、每周自我反思、关系里程碑**——她们会记住、会回顾、会成长
- 角色之间会分享彼此的生活——重要的瞬间会在她们之间自然流传
- 情绪、压力、饥饿、口渴、体力、经期完整生理周期
- **她们会想念你**——想念时会主动给你发消息

### 🌍 她们生活的世界

- 自主日常生活——吃饭、喝水、休息、做饭、照料绿植、排练、社交——**完全自主，即使离线也在继续**
- 可选的**真实天气**会影响她们的一天：下雨天宅在家里，晴天午后出门走走
- 3D 探索场景，自主导航与障碍规避（原型）
- **开放世界编辑**，基于 GridMap 的地编工具（规划中）

### 💬 主动交互

- 角色之间会在后台互相聊天
- 她们会**主动发起对话**——不只是被动回复
- 离线消息支持 Windows 通知
- **会观察环境并主动评论**

### 🎙️ 语音就绪

- 语音输入输出通过可插拔协议适配器接入
- 支持 **GPT-SoVITS、Voicebox 与 CozyVoice** 端点，以及任何 OpenAI 兼容语音接口

### 🔒 本地优先 & AI 自由

- 所有数据保存在本地——不依赖云端
- **自带模型密钥 (BYOK)**：任何 OpenAI 兼容接口——DeepSeek API、LM Studio、Ollama 等
- 对话、视觉、嵌入、重排序均有独立的**故障转移链**
- API Key 使用 **Windows DPAPI 加密**保存，保存后永远不会回传给游戏
- 无追踪、无遥测
- 隐私优先的诊断包——用于问题反馈，绝不包含聊天记录或数据库

### 🧩 Steam 创意工坊 & UGC（规划中）

- 分享角色、世界和故事
- 下载社区创作
- 内置地编系统

---

## 🏗️ 架构设计

Spring Haven 采用前后端分离架构：

Godot 4.7 客户端  
├── 2D 立绘舞台 / 3D 探索场景  
├── 聊天界面 / 心织记忆网络 / 生活实验室  
└── 多存档旅程管理  
│  
▼ 本地 HTTP REST（localhost + 访问密钥）  
Companion Core（Python，自研、独立运行）  
├── 对话与角色编排（双角色共享上下文）  
├── 心织记忆引擎（Heartloom，SQLite）  
├── 本地 RAG 知识库  
├── AI 供应商层（多后端 + 故障转移：对话 / 视觉 / 嵌入 / 重排序）  
├── 生活调度器（需求、周期、天气、每日总结）  
├── 语音适配器（ASR / TTS）  
└── DPAPI 加密的密钥管理  
│  
▼  
本地存储  
├── SQLite（记忆、知识库）  
└── JSON（角色、存档、配置）


---

## 🎭 内置示例角色

春日庭院默认包含两个完整的示例角色，方便你快速上手：

- **小玲 (Suzune)** —— 21 岁的猫娘，性格慵懒、傲娇，偶尔毒舌。慢热但极其忠诚。
- **雪奈 (Yukina)** —— 19 岁的兔娘，性格主动、黏人，对自己的感情非常坦诚。

**她们只是示例。** 你可以修改她们、从零创造自己的角色，或者通过创意工坊下载社区创作的角色。

---

## 🗺️ 路线图

### ✅ Alpha（当前阶段）
- 双角色人格、共享上下文与命名多存档旅程
- 心织记忆：时间戳召回、记忆网络可视化、每日总结与里程碑
- 本地 RAG 知识库（按角色划分范围）
- 生理需求、经期、真实天气、自主日程与主动消息
- DeepSeek API 集成，缓存命中率 76%+
- ASR / TTS 语音输入输出
- 2D 分层立绘：注视、眨眼、呼吸、表情与说话动画
- 3D 探索原型与双人生活实验室

### 🚧 第二阶段（进行中）
- 资源版权审查与占位模型替换
- 20-30 分钟完整体验切片
- 角色创建系统（基于 JSON）
- Watchdog 自动恢复机制

### 🌟 第三阶段（规划中）
- Steam 创意工坊集成
- 可视化角色编辑器
- 地编系统（基于 GridMap）
- DLC 系统：角色、场景、服装
- 视频通话与屏幕共享视觉感知

### 🔮 第四阶段（未来展望）
- 完整的 UGC 创作市场
- 多角色共同生活
- 程序化世界生成
- 社区驱动的内容扩展

---

## 🚀 快速开始

### 环境要求

- Windows 10 / 11（DPAPI 密钥加密与 Windows 通知目前仅支持 Windows，其他平台在计划中）
- Python 3.11+
- Godot 4.7（标准版）
- （可选）OpenAI 兼容的 API Key（如 DeepSeek）或本地 LM Studio

### 快速启动

```bash
# 克隆仓库
git clone https://github.com/AuroraEvelynAria/Spring-Haven-Core.git
cd Spring-Haven-Core

# 配置 Python 后端
cd companion-core
py -3.11 -m venv .venv
.venv\Scripts\python -m pip install -e .

# 启动
# 用 Godot 4.7 打开 godot/project.godot 并运行。
# 首次启动时，客户端会自动生成本地访问密钥、启动 Companion Core，
# 并打开 AI 设置页，填入你的模型服务凭据即可。
```

> 🔐 模型 API Key 使用 Windows DPAPI 加密保护，保存后永远不会回传给游戏。玩家数据库、导入的知识、对话归档与密钥均不进入版本控制与发行包。

## 🤝 参与贡献

我们欢迎任何形式的贡献！春日庭院目前处于 **Alpha** 阶段，正在快速演进中。

1. 查看 [Issues](https://github.com/AuroraEvelynAria/Spring-Haven-Core/issues) 中带 `good-first-issue` 标签的任务
    
2. 在 Issue 下留言，或提交新的 Issue 描述你的改动
    
3. 确保代码通过现有测试
    
4. 遵循 PEP8（Python）和 GDScript 代码风格规范
    

> 💬 关于架构设计的讨论，请先提交 Issue。

---

## ⚠️ 关于成人内容

**春日庭院不包含、也无意设计成人/NSFW 内容。**

这不只是理念——它由应用本身强制保证。成人内容生成功能已在**应用层被彻底移除**：不存在任何设置、按钮或提示词可以重新启用它。运行时对每一次请求都施加全年龄向内容策略，互动动作也被限定为一份固定的保守白名单。

本项目聚焦于：

- 有意义的陪伴与情感连接
    
- 创造性的角色表达
    
- 真正“活着”的 AI 角色
    

所有互动内容均为健康、全年龄向。任何违反此原则的内容将不被支持。

---

## 🛠️ 开发

### 仓库结构

- `godot/`：Godot 4.7 游戏本体、UI、模拟、存档与 3D 场景
- `companion-core/`：本地 HTTP 运行时、心织记忆、RAG 与供应商层
- `tools/Build-Playable.ps1`：可重复的 Windows 试玩打包脚本

### 构建 Windows 试玩包

安装 Godot 4.7 导出模板后运行：

```powershell
.\tools\Build-Playable.ps1 `
  -GodotExecutable "C:\path\to\Godot_v4.7-stable_win64.exe" `
  -InstallBuildDependencies `
  -CreateArchive
```

产物输出到 `build/SpringHavenPlaytest/`——包含 Godot 游戏与独立的 `spring-haven-core.exe`。本地数据库、密钥、导入的知识与无分发许可的占位模型都会被构建的发行守卫拒绝。

### 实现文档

- [Companion Core](companion-core/README.md)——本地运行时、供应商层与内容策略
- [架构](godot/docs/CompanionCoreArchitecture.md)——客户端与运行时如何通信
- [心织](godot/docs/HeartloomMemory.md)——记忆引擎
- [旅程存档](godot/docs/JourneySaves.md)——存档槽行为与恢复边界
- [表现层架构](godot/docs/PresentationArchitecture.md)——一套角色核心贯穿 2D/Live2D/3D
- [Voicebox 集成](godot/docs/VoiceboxIntegration.md)——语音服务器配置与桌面端限制

---

## 📄 许可证

- **源代码**：MIT
    
- **美术资源（模型、立绘、UI、音乐）**：CC BY-NC 4.0
    

> ⚠️ 当前部分占位资源来源于第三方（MMD 等），商业发布前将完成替换。

---

<div align="center"> <sub>☕ 由 <a href="https://github.com/AuroraEvelynAria">NachoNeko</a> 构建</sub> </div>
