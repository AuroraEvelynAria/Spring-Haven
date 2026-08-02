# 双团子生活实验室

入口位于主菜单的“🍡 团子生活实验室”。该场景是独立测试沙盒，不会把加速后的饥饿、口渴和体力写入正式存档，也不会生成正式心织记忆。

## 可验证行为

- 小玲与小奈同时寻路、动态避让、绕过中央障碍和窄通道。
- `planned -> moving -> interacting -> completed/failed` 生活任务状态。
- 喝水、吃饭、共同用餐、做饭、泡茶、阅读、影视、游戏、音乐、清洁、拍照、依偎、分享今天、休息、如厕、照料绿植、排练、聊天和自由探索。
- “小奈过来我这”“小玲跟着小奈”“她们一起喝水”等高层文字指令。
- 主人位置跟随、角色互相跟随、卡住重规划和跌落安全恢复。
- 六轮双角色导航压力测试；诊断脚本可扩展到最多四十轮。
- 手动角色视角观察：从所选团子的眼部方向截取 512×320 场景帧，结合 Godot 可信状态进行视觉转述；支持 Companion Core API、本地 LM Studio 以及 API 失败后的自动本地回退，并把实际 Provider 缓存到角色场景上下文。
- 社会生活事件会进入独立的 `_life_lab` 会话，由小玲和小奈按顺序回复；第二位角色能看到第一位角色刚生成的回复。事件队列有限长并带调用冷却，导航压力测试不会请求真实 LLM。

## 观察操作

- `WASD`：移动场景里的主人位置标记。
- 鼠标中键拖动：平移俯视镜头。
- 鼠标右键拖动：旋转与调整俯角。
- 鼠标滚轮：缩放。

## 模型与发布隔离

默认只加载 `local_assets/life_lab/ling_chibi.glb` 和 `nai_chibi.glb`。小奈完整模型仅用于对照，可从实验室面板手动切换，默认不会加载。

所有 PMX 转换产物都位于 `.gitignore` 覆盖的 `local_assets/`，发布保护插件会阻止它们进入导出包。源 PMX 不会被修改，转换报告保存在项目外层 `_source_assets/life_lab/`。

这些模型仅用于本地普通生活与导航测试，不得进入成人内容或对外发布包；具体使用限制仍以各模型随附 Readme 为准。

## 自动诊断

```powershell
Godot_v4.7-stable_win64_console.exe --path . --headless --scene res://scripts/diagnostics/LifeLabWorldCheck.tscn
Godot_v4.7-stable_win64_console.exe --path . --scene res://scripts/diagnostics/LifeLabVisualCheck.tscn
Godot_v4.7-stable_win64_console.exe --path . --scene res://scripts/diagnostics/LifeLabGemmaVisionCheck.tscn
Godot_v4.7-stable_win64_console.exe --path . --headless --scene res://scripts/diagnostics/LifeLabSocialDialogueCheck.tscn
```

第一项执行双角色任务、文本解析和跌落恢复测试；第二项加载两只本地团子并做 1280×720 截图与非空像素检查。
第三项虽然保留旧文件名以兼容现有脚本，但已是通用视觉测试；可在运行前设置
`SPRING_HEAVEN_VISION_BACKEND=api` 或 `local` 强制验证指定后端。
第四项使用隔离的诊断存档验证生活事件会依次生成小玲、小奈两条回复，并在结束后
重置诊断会话，不写入正式聊天存档。
角色眼位截图依赖窗口渲染，不能在纯 `--headless` 模式中等待
`RenderingServer.frame_post_draw`；外部 API 离线时使用 Life Lab 的窗口观察按钮配合
`SPRING_HEAVEN_VISION_BACKEND=local` 验证完整截图链路。
