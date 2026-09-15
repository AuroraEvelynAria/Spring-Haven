# 变更日志 / Changelog

本项目处于 **Alpha(预发布)** 阶段。`companion-core` 当前版本为 `0.1.0`
(见 `companion-core/pyproject.toml`),**尚未打任何 git tag** —— 因此以下条目按
开发时间倒序整理自提交历史,而非来自正式发布记录。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [未发布] / Unreleased

### 新增

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
