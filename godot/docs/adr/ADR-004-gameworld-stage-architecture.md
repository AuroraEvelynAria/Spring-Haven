# ADR: GameWorld 舞台架构——「居家舞台 + 游戏 HUD」的 UI 模式约定

- 状态:已落地(2026-09-13,commit `d00959f`;背景子层于 2026-09-15 随 #11 补完)
- 关联:issue #19(ChatPipeline 抽取)、#11(性能三件套之背景 FX 独立子节点化);实施蓝本 `.zcode/plans/plan-sess_21b63887-*.md`
- 决策范围:`godot/scenes/GameWorld/GameWorld.gd`、`BackgroundFX.gd`、`godot/scripts/domain/ChatPipeline.gd`、`godot/shaders/ground_fade.gdshader`

## 背景

GameWorld 原先是「网页三栏仪表盘」形态:对话用气泡、右侧 340px 卡片列、六张描边信息卡。视觉上呈 Web 后台感,与「角色在场的游戏舞台」这一体验目标不符。本轮把它重构为**居家舞台 + 游戏 HUD**。

同时存在两个结构性负担:

1. GameWorld.gd 膨胀到近 3000 行,视觉构建、逻辑编排、绘制全部耦合在单文件。
2. GameWorld 自身 `_draw()` 承担背景底色 + 柔光晕 + 54 粒子的绘制,并在 `_process()` 里**无条件每帧 `queue_redraw()`**,使整块 UI 根节点每帧重绘,且与界面刷新频率强行绑定。

## 决策

### D1 对话去气泡化

- **AI 发言**:角色色名牌(圆点 + 名字 15px)+ 正文 17px **无框块**(半透明底板,无 1px 边框,radius 10),左缘加 3px 角色色竖条作为归属提示。
- **玩家发言**:右对齐浅色引言胶囊(primary @ 0.08,radius 12,14px),刻意**不**与 AI 对称 —— 玩家不是「另一个气泡角色」,而是被引用的发言。
- 「正在思考」不再渲染样式框气泡,改为聊天流内一行轻量文字 + 立绘 thinking 表达 + `thinking_strip` 光带。
- 保留:交付状态行(pending/failed/重试)、打字机、入场动画、72 条上限。

### D2 立绘舞台

- 布局从 `chat | sidebar(340px 卡片列)` 改为 `chat | stage(370px)`。
- 立绘 1.6× 放大(内部已按 size 比例缩放),背后复用 glow 背光,舞台底部加垂直渐隐地影(新增 `ground_fade.gdshader`,6 行 fade)。
- 名字牌并入舞台(立绘下方:角色色大名字 + 一行 mood),取消独立头像卡。

### D3 HUD 仪表化

- 六张描边卡片 → **三块无边框半透明板**:需求仪表 / 生活与周期 / 今日絮语(`_refresh_sidebar` → `_refresh_hud` 语境)。
- 需求条 4px → 7px 圆头仪表,去掉 0/50/100 刻度文字(去除伪精确仪表盘信号),数值内嵌条右侧。

### D4 背景特效独立为专用子层(BackgroundFX)

> 本条为 #11 的落地,是 D1~D3 之后补完的结构性收尾。

- 新建 `godot/scenes/GameWorld/BackgroundFX.gd`(`extends Control`),**独占**负责:背景底色铺色、430px 柔光晕、54 个飘浮粒子的初始化/推进/绘制。
- GameWorld 自身**移除** `_draw()`、`_initialize_background_particles()`、`_particles` 成员,`_process()` 里**移除**每帧 `queue_redraw()`。
- **硬约束:`BackgroundFX` 必须是 GameWorld 的第一个子节点。** 因为 CanvasItem 先绘自身再绘子节点,只有它是首个子节点,背景才落在所有 UI 之下 —— `_ready()` 中 `_build_background_fx()` 必须先于 `_build_interface()` 调用,**不得调换**。
- `_glow`、`_season_tint` 仍作为 BackgroundFX 的子节点(`_background_fx.add_child(...)`),绘制顺序与原实现逐像素等效。
- 主题切换时通过 `_background_fx.call("refresh_theme")` 触发**单次**重绘(配色在 `_draw()` 内实时取自 `ThemeMgr`,本层不缓存颜色)。
- 提供 `set_animating(bool)`:`false` 时 `set_process(false)` 且不再重绘,作为「空闲态零重绘」策略的接线点(当前默认 `true`,以保持粒子常动)。

### D5 逻辑下沉:`ChatPipeline` 纯静态

- 历史查找、角色解析、共享历史构建、多角色提及判定等**纯逻辑**抽到 `godot/scripts/domain/ChatPipeline.gd`(`extends RefCounted`,全 `static`,180 行)。
- 该文件**不持有 UI 引用、不访问 autoload**,运行时输入一律经参数注入,便于脱离场景单测。后续同类逻辑按此模式继续下沉。

### D6 控件路径与诊断契约不变

以下成员名是**诊断脚本依赖的契约**,重构中不得重命名:

```
_chat_input  _send_button  _settings  _ling_button  _nai_button
_sidebar  _sidebar_content  _portrait_rig  _stat_widgets  _message_views
```

`GameWorldUIRenderCheck` / `GameWorldChatFlowCheck` / `GameWorldDualReplyCheck` / `GameWorldStageCheck` 均按这些路径取控件。

### D7 主题适配方式

所有新样式从 `get_current_theme_data()` 派生并存储引用,`_on_theme_changed` 全量重涂(沿用既有模式);明暗主题分别校准底板透明度。字号体系:对话 17 / 名牌 15 / HUD 标题 13 / HUD 标签 12 / 注释 10 / 输入 15。

## 备选方案(已否决)

| 备选 | 否决理由 |
|------|----------|
| 保留气泡,只改配色与圆角 | 气泡本身承载「聊天软件」语义,与舞台感冲突;换皮不解决隐喻问题 |
| 引入美术资源做舞台背景 | 项目要求程序化实现、无美术依赖;且会增加打包体积与导入流程 |
| 用 SubViewport 独立渲染背景以隔离重绘 | 多一层视口合成与尺寸同步成本,收益与「首子节点 + 自绘」相同 |
| 保留 GameWorld 自绘背景,仅把 `queue_redraw()` 改为按需触发 | 粒子本身需要每帧重绘,无法真正按需;成本会继续压在 UI 根节点上 |
| 把粒子改用 CPUParticles2D/GPUParticles2D 节点 | 需引入粒子纹理资源(违反无美术依赖);且纯色圆点自绘成本已足够低 |
| 把 ChatPipeline 做成 autoload 单例 | 会重新引入全局状态与隐式依赖,破坏「可脱离场景单测」的目标 |

## 正面后果

- 视觉从「Web 后台」转为「角色在场的舞台」,对话流不再有软件感边框。
- 逐帧重绘成本从**整个 UI 根节点**收敛到 `BackgroundFX` 小子树;界面刷新(主题切换、HUD 刷新)与背景动画**解耦**,背景重绘只为背景发生。
- `BackgroundFX.gd` 自带注释钉死「必须首子节点」的原因,降低后续被无声改坏的概率。
- 逻辑下沉 `ChatPipeline` 使对话管线可单测,GameWorld.gd 净减约 180 行。
- 控件命名契约显式记录,诊断脚本不会因重构而失效。

## 负面后果

- 绘制顺序变为**隐式的调用顺序依赖**:若后续有人在 `_build_background_fx()` 之前插入新的 `add_child`,背景会被压到该节点之上。目前仅靠注释防呆,无运行时断言。
- 「空闲态零重绘」只完成了**能力预留**(`set_animating`),尚未接入任何空闲判定策略;粒子默认仍在每帧重绘。
- 无框半透明底板在极端壁纸/高对比主题下的可读性未做穷举验证,目前只覆盖浅/深两套主题。
- 立绘 1.6× 放大依赖 `PortraitRig2D` 内部按 size 比例的缩放假设;若该内部约定变化,舞台会静默变糊或溢出。
- `_refresh_sidebar` 命名与 `_refresh_hud` 语义并存,历史命名残留需要一次清理。

## 验收

- `GameWorldUIRenderCheck` 通过(真实渲染截图,headless 下跳过截图但保留全部结构断言)。
- `GameWorldStageCheck` 通过:断言舞台布局与 HUD 三块板存在、旧描边卡片列不再出现。
- `GameWorldChatFlowCheck` / `GameWorldDualReplyCheck` 通过(控件路径契约未变)。
- 全项目 `--import` 退出码 0(所有改动脚本在完整项目上下文编译通过)。
- **#11 背景子层验收(2026-09-15 实测)**:与未修改基线做窗口化渲染截图对比,均值 RGB 偏差 ≤ 0.05/255、亮度标准差偏差 0.01、最低/最高亮度完全一致;逐像素采样 13636 点一致 / 764 点不同,差异全部来自 `_rng.randomize()` 的粒子随机分布。
