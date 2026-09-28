# 变更日志 / Changelog

本项目处于 **Alpha(预发布)** 阶段。`companion-core` 当前版本为 `0.1.0`
(见 `companion-core/pyproject.toml`),**尚未打任何 git tag** —— 因此以下条目按
开发时间倒序整理自提交历史,而非来自正式发布记录。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [未发布] / Unreleased

### 新增

- **艾宾浩斯正式化(ADR-014,schema v10)** —— `intrinsic` 正式定义为稳定度系数
  (有效半衰期 = half_life × intrinsic,1.0 = 标称);每次成功召回/复发改为
  **乘法稳定度增长**(×1.5,封顶 4.0);存量按倒数重映射,迁移瞬间逐条保持
  有效半衰期不变;`recall_pool` 输出新增 `recall_decay`(R(t) 可提取性),供
  记忆网络展示衰减曲线
- **夜织巩固蒸馏(ADR-013,零迁移)** —— 世界日关闭后把当天记忆织成主题级
  语义记忆(≤1 条/日、importance ≤0.65、禁止新增事实、失败不用模板兜底);
  周反思并入「本周淡忘」归档清扫(补 archived_sweep 审计边);每 90 世界日
  季织一条「这一季的我」(identity 常驻);已挂调度器,图谱节点绘制弦月 glyph
- **PAD 心境基线(ADR-012,schema v9)** —— `mood_baseline` 表:organizer 输出
  `mood_delta`(±0.3)经 EWMA(α=0.12)汇入,读取时按世界日向稳态锚点连续
  衰减(0.9^Δ世界天,离线推演同步自愈);只以定性词进 prompt(数字不出域),
  响应载荷带原始 PAD 供场景化表达;审计走 state_events
- **BGE 跨编码器重排(ADR-011)** —— 召回拆为无副作用候选池 + 定稿副作用,
  service 层对短名单前 12 条 rerank(0.55×rerank + 0.45×混合分);失败静默
  回落纯混合序,唤醒奖励只落最终入选集;`memory_rerank_enabled` 开关
- **语义救援扫描** —— 词法候选池过薄(<8)且带查询向量时,对池外带向量的
  记忆补余弦扫描(上限 200):修复「那天下雨发生了什么?」类改写提问在
  SQL 阶段被零词法交集滤空的问题(实弹两轮定位)
- **3D 探索阶段①:玩家交互进记忆** —— Exploration 模式新增按 E 交互系统:
  准星射线对准 Perceivable3D 物件(沙发/茶几/餐桌/绿植/玻璃杯)时提示可用动词,
  交互执行最小动词效果(浇水/喝水改水位)并把动作经 LifeSim 既有 `/life/sync`
  recent_events 通道写入 Heartloom(record_life_events → organizer → 记忆/主张);
  事件幂等粒度 = 角色+动词+自然分钟。感知动词从空壳变为可执行,3D 动作首次接入记忆
- **3D 探索 SLG 交互层** —— 按 E 打开**动作菜单**(鼠标点选,打开期间释放鼠标/
  停用移动,右键取消);**小玲 3D 本体可交互** —— 挂 Perceivable3D,走近 2.4m 或
  准星对准即可按 E 选「交谈(切聊天输入)/摸摸头/一起泡茶」,交互事件同通道进心织
- **心织图谱时间游标(ADR-010)** —— `/heartloom/graph` 接受 `as_of_world`(世界天):
  只渲染该时刻已存在的节点与已建立的边,边 payload 自带 `world_created_at`;
  响应新增 `world_now` / `world_range` 供滑杆取值;Godot 🕸️ 面板时间滑杆为
  **纯客户端调光** —— 始终加载全量图谱,拖动零请求零重排,游标后诞生的节点/
  边降为低亮度半透明幽灵,亮度按帧率无关插值平滑过渡,拨到"现在"全部点亮

### 修复

- **衰减护盾方向反转(ADR-014)** —— 唤醒奖励自 v6 起把「越常回忆越慢忘」
  实现成了 `half_life / intrinsic`(越常回忆越快忘),与设计描述和对外对比
  表相反;修正为 `half_life × intrinsic` 并借 v10 迁移无偿还原存量
  (倒数重映射逐条保持有效半衰期,棘轮 0.4667 零漂移实证)
- **provider 失败分类** —— 402 欠费/429 限流/5xx/DeepSeek 过载伪装的 400
  允许 fallback 接管(实弹中官方 key 402 中断两次),401/403 配置错误保持
  原地暴露;claims 写入逐条隔离 + uuid 主键(修复同秒重放主键碰撞导致的
  整批 IntegrityError),降级日志携带异常消息与载荷
- **图谱画布重复函数** —— `MemoryGraphCanvas.gd` 的 `_ghost_target_for_node`/
  `_ghost_target_for_edge` 各残留一份旧二值版本(ENOSPC 重建遗留),GDScript
  直接解析失败并连锁 MemoryNetworkPanel 报错;删除残留,保留软边渐变实现
- **3D 角色比例尺** —— 方块占位角色是「宽体 Q 版」:玩家肩宽 1.16m/头 0.44m,
  站在 0.46m 餐椅旁像巨人。两个角色按真人比例重建(总高 1.70/1.67m,肩宽
  0.44/0.40,头 0.26/0.30,腿长 0.72/0.80),感知射线降至眼高,相机臂 2.7→2.4
  与 FOV 72→68 微调;行走动画节点名全部保留
- **爱心粒子越界** —— 生命状态变化 spawn 的 ♥/✦ 粒子原先以 `z_index=100`
  挂在世界根节点上,浮在记忆网络等一切遮罩面板之上;改挂到各状态条的
  fx_layer 内(局部坐标,z 归零),叠层交还树序
- **实体-主张层与信念修订(ADR-009,schema v8)** —— `entities` + `claims` 两张新表
  (纯新增零回填,pre-v8 强制备份);organizer 契约扩展 `entities[]`/`claims[]`;
  同 (subject, predicate) 宾语相同则强化、不同则顶替(旧主张 world_to=现在、
  superseded_by 回链,新旧来源记忆间补 conflict 审计边);召回后按查询命中与
  来源记忆挂靠水合当前事实,注入有界 `<heartloom_current_facts>` 块(markers 转义)
- **#23 world_time 收尾(schema v7)** —— digest 分桶/窗口、周反思周键与窗口、
  里程碑扫描范围全部切世界时间;旧档 `life_events` / `digest_state` 幂等映射回填,
  `pre-v7` 强制备份;周反思以「世界周桶内已有 weekly_insight 即跳过」防重复生成
- **召回评测基建** —— `tools/recall_eval.py` + `tests/test_recall_eval.py` 驱动
  `recall_eval_set.json`(此前评测集无任何 runner);冻结语料模式做可复现回归,
  `--no-freeze` 诊断活档老化;冻结基线已记为棘轮下限
- **检索质量修复(冻结基线 2/15 → 7/15)** —— ① always_active 里程碑保底分
  改为仅在词法相关时生效,不再无条件霸占每次召回头部;② 词法通道引入候选池
  局部 IDF,全库高频词贡献被压低;③ 移除触发词命中的平面 1.0 削平,策展词与
  普通 gram 一同经 IDF 归一排序(ADR-001 D1/D2 修订)
- **embedding 换模型自愈** —— `memories_without_embedding` 支持模型指纹匹配,
  换 embedding 模型后不匹配存量自动进入限速重嵌,语义通道不再静默失效
- **Heartloom 记忆系统** —— 带时间戳的召回、记忆网络可视化、离世整理(digest)与里程碑;
  检索走混合召回 + 生命周期管理,并开放 `/heartloom/graph` 查询接口
  (`12e1a4c`、`27395ff`、`15fe581`)
- **本地 RAG 知识库** —— 角色作用域文档、嵌入与重排支持(`e5089d9`)
- **世界时间单时钟** —— `journey_clock` 落地 + schema v6 迁移;记忆衰减 / recency / outbox TTL
  改为按世界天计算(`245600e`)
- **生理衰减引擎** —— 双参数内在衰减与冲突检测(`714a2f3`、`2afb36b`)
- **后端真相源开关** —— `state_truth_source`、逐角色 world-time 水位线、客户端增量上报
  (`5013221`、`6dc8921`)
- **3D 探索原型与双角色 Life Lab**
- **CI** —— GitHub Actions 运行后端测试(Windows,含依赖 DPAPI 的凭据持久化)
  (`16d3cf4`、`8b1fafc`)
- **架构决策记录(ADR)** —— `godot/docs/adr/` 下的 ADR-001(检索与记忆网络)、
  ADR-002(数值卫生)、ADR-003(真相源)、ADR-004(舞台架构),以及 ADR-005~008 设计草案
  (`8f31a9b`、`b53d000`、`5e8bb87`、`6574ed7`)
- **视觉动效** —— `UIBreath` 呼吸动效接入主菜单、花瓣飘落与按钮层级(`07afc38`、`779e39b`)

### 变更

- **GameWorld 舞台化重构** —— 去气泡化、立绘舞台、HUD 仪表化,背景 FX 独立为子层
  (`d00959f`、`5e8bb87`)
- **大文件拆分** —— `SettingsPanel` 六步拆分(4627 → 415 行),并抽出 `ChatPipeline`
  与设置区控制器(`9eb396e`)
- **命名统一** —— `project.godot` 应用名改为 `Spring Haven`;旧 `SPRING_HEAVEN_*`
  环境变量保留为兼容别名(`SPRING_HAVEN_*` 优先)
- **README** —— 头部换用 Spring Haven 横幅(`2a9dc48`、`c57115f`)

### 修复

- **对话复读** —— 记忆去重三层 + 提示词新鲜度策略(`3cb89cc`)
- **记忆链接调度器** —— 关键字参数被位置调用导致的 `TypeError`(`3d2ba5c`)
- **主菜单抖动** —— 呼吸动效改用 `modulate` 亮度而非缩放(`a4c5c71`)
- **缺失的属性动作** —— `LIFE_PERSONALITY_PROFILES` 补齐如厕 / 喝水 / 进食 / 休息(`218f3ed`)
- **reindex 部分失败** —— 跳过失败批次并保持一致文档状态(`fb10ef0`)
- **请求生命周期与 outbox 饥饿**(`8b1fafc`)
- **缺失的 `.uid`** —— 补齐 3 个,避免全新 clone 后工作区出现脏文件(`6574ed7`)

### 移除

- **NSFW 内容生成** —— 应用级永久策略,Godot 客户端与后端一并对齐(`c52f727`)
- **孤儿 `ChatCoreClient.gd.uid`** —— 其配套 `.gd` 在 git 全历史中从未存在,全库零引用(`422a3c5`)

---

## 说明

- 本文件不替代 issues 与 [`godot/docs/adr/`](godot/docs/adr/) 中的决策记录;
  架构决策以 ADR 为准,问题追踪以 issues 为准。
- 版本号策略与首个 tag 将在发布流程确定后补充。
