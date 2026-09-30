# 🧪 测试指引（对外测试者版）

> 谢谢你愿意帮忙测试！这份文档带你从零跑起来，大约需要 15 分钟。
> 项目还处于 **Alpha**：能玩、能存档、核心记忆系统完整，但界面和美术还在迭代。

---

## 1. 这是什么

**春日庭院（Spring Haven）** 是一款**本地优先**的 AI 生活模拟器：你创造的角色拥有持久记忆、生理需求和自主生活。前端是 Godot 4.7，后端是 Python 本地服务。

**隐私**：所有数据（记忆、对话、生活状态）只存在**你自己电脑**的 `companion-core/user_data/` 里；唯一会出网的是你自配的 LLM API 请求。删掉 `user_data/` 目录 = 彻底重置。

## 2. 环境要求

| 项 | 要求 |
|---|---|
| 系统 | Windows 10 / 11（语音输入、TTS、密钥加密按 Windows 设计） |
| Python | ≥ 3.11（[python.org](https://www.python.org/downloads/) 安装时勾选 *Add to PATH*） |
| 引擎 | [Godot 4.7 stable (win64)](https://github.com/godotengine/godot/releases) —— 只要解压版即可，不用安装 |
| LLM Key | 一个 **OpenAI 兼容**接口的 key（DeepSeek / 硅基流动 / LM Studio 本地都行；**不需要**充值官方任何服务，便宜通道即可） |

## 3. 五步跑起来

```powershell
git clone https://github.com/AuroraEvelynAria/Spring-Haven.git
cd Spring-Haven\companion-core
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
```

然后打开游戏（二选一）：

- **方式 A（推荐）**：用 Godot 4.7 打开仓库里的 `godot/project.godot`，按 **F5** 运行。
- **方式 B**：仓库根目录有 `运行游戏.cmd`。如果 Godot 不在默认位置，先 `set GODOT_BIN=你的Godot.exe路径` 再双击它。

**首次启动会自动完成**：创建 `companion-core/user_data/` 运行时目录（配置从模板生成）、生成内部访问密钥、自动拉起后端服务（`127.0.0.1:18340`）。你不需要手动做任何配置。

## 4. 填入你的 LLM Key（唯一要手动做的事）

游戏主界面 → **设置 → 模型提供方**：

1. 粘贴你的 API Key（由 Windows 当前用户加密保存，**永不回显**）；
2. 接口地址 / 模型名按你的渠道改（默认 DeepSeek `deepseek-chat`，任何 OpenAI 兼容端点都可以）；
3. 点「保存并立即应用」。

## 5. 建议体验路线（重点看这些）

1. **开始旅程** → 和角色聊天：打字、动作按钮（🤗💋🍗💧🛏️）、回复流、复述是否记得你说过的话；
2. **心织记忆网络**（招牌功能）：图谱是否好读、点节点看详情卡与**遗忘曲线**、拖动**时间滑杆**回拨过去、搜索与范围筛选；
3. **聊几天（或调世界时间快进）**：看记忆是否沉淀、`夜织` 是否织出总结性记忆、角色心境是否有变化；
4. **3D 探索**：走近角色/物件按 **E** 交互，动作菜单、视角与**比例尺**是否舒服；
5. **归档 / 生活面板**：数值随时间变化是否符合直觉。

## 6. 已知未完成（不算 bug，别报这些）

- 聊天界面会重新设计（当前是过渡形态）；
- 美术全部是**程序化占位**：灰盒房间、几何拼装角色，最终会替换；
- 3D 部分家具仍是灰盒；
- 语音输入 / TTS 仅在 Windows 上完整可用。

## 7. 反馈模板（直接复制填）

```
【环境】Windows 版本 / 显卡
【步骤】我做了什么
【期望】我以为会…
【实际】结果…
【频率】必现 / 偶现
【附件】截图 + companion-core/user_data/logs/companion-core.log 末尾 50 行
```

**顺带一问（很重要）**：心织图谱你**第一眼**能看懂吗？哪里最想先改进？

## 8. 常见问题

- **端口被占**：改 `companion-core/user_data/core_config.json` 的 `port`，游戏内设置里同步改核心地址；
- **连不上后端**：看 `companion-core/user_data/logs/companion-core.log`；游戏重启会自动拉起后端；
- **报 401/认证失败**：内部密钥是首启自动生成的，别手动改 `core_config.json` 里的 `api_key`；
- **想彻底重来**：关游戏 → 删 `companion-core/user_data/` → 重新打开。
