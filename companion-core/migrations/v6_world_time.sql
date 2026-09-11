-- SCHEMA_VERSION 6: world_time 单时钟 + 记忆网络底层(ADR-001,2026-09-12 冻结)
-- 执行方式:#23 实施时由 HeartloomStore._migrate 吸收执行(本文件为冻结稿与演练基准)。
-- 前提:迁移前必须先做备份(maintenance backup_to),回滚见 v6_world_time_rollback.sql。
-- world_time 类型:REAL,单位 = 世界天(floor(world_time) 派生世界日)。
-- 回填约定:世界时钟零点 = 迁移时刻;旧记忆按存档内最早 real created_at 的相对偏移(天)映射。

-- ===== 1) memory_entries 扩充列 =====
ALTER TABLE memory_entries ADD COLUMN world_created_at REAL NOT NULL DEFAULT 0;
ALTER TABLE memory_entries ADD COLUMN world_updated_at  REAL NOT NULL DEFAULT 0;
ALTER TABLE memory_entries ADD COLUMN last_recalled_world REAL NOT NULL DEFAULT 0;
ALTER TABLE memory_entries ADD COLUMN lifecycle TEXT NOT NULL DEFAULT 'active'
    CHECK(lifecycle IN ('active','dormant','archived'));
ALTER TABLE memory_entries ADD COLUMN lifecycle_changed_world REAL NOT NULL DEFAULT 0;
ALTER TABLE memory_entries ADD COLUMN is_second_hand INTEGER NOT NULL DEFAULT 0;
ALTER TABLE memory_entries ADD COLUMN embedding_json TEXT;
ALTER TABLE memory_entries ADD COLUMN embedding_model TEXT NOT NULL DEFAULT '';

-- ===== 2) 回填 =====
-- 二手传闻:传播链记忆(heard_from_*)标记为二手
UPDATE memory_entries SET is_second_hand = 1
    WHERE source LIKE 'heard_from_%' AND is_second_hand = 0;
-- 世界时间回填:按存档内最早 real created_at 的相对偏移(天)
UPDATE memory_entries
    SET world_created_at = ROUND(
        (created_at - (SELECT MIN(created_at) FROM memory_entries AS m0
                       WHERE m0.save_id = memory_entries.save_id)) / 86400.0, 4)
    WHERE world_created_at = 0;
UPDATE memory_entries
    SET world_updated_at = ROUND(
        (updated_at - (SELECT MIN(created_at) FROM memory_entries AS m0
                       WHERE m0.save_id = memory_entries.save_id)) / 86400.0, 4)
    WHERE world_updated_at = 0;
UPDATE memory_entries
    SET last_recalled_world = ROUND(
        (last_recalled_at - (SELECT MIN(created_at) FROM memory_entries AS m0
                             WHERE m0.save_id = memory_entries.save_id)) / 86400.0, 4)
    WHERE last_recalled_at > 0 AND last_recalled_world = 0;

-- ===== 3) memory_links(ADR-001 D4:增量建边,四类型,单向 src=new→dst=old) =====
CREATE TABLE IF NOT EXISTS memory_links (
    link_id          TEXT PRIMARY KEY,
    save_id          TEXT NOT NULL,
    src_memory_id    TEXT NOT NULL,
    dst_memory_id    TEXT NOT NULL,
    link_type        TEXT NOT NULL
                     CHECK(link_type IN ('causal','association','spread','milestone')),
    link_strength    REAL NOT NULL DEFAULT 0.5,
    reason           TEXT NOT NULL DEFAULT '',
    world_created_at REAL NOT NULL,
    UNIQUE(src_memory_id, dst_memory_id, link_type)
);
CREATE INDEX IF NOT EXISTS idx_links_src  ON memory_links(save_id, src_memory_id, link_strength DESC);
CREATE INDEX IF NOT EXISTS idx_links_dst  ON memory_links(save_id, dst_memory_id);
CREATE INDEX IF NOT EXISTS idx_links_type ON memory_links(save_id, link_type);

-- ===== 4) role_milestones(ADR-001 D6:成就档案,规则解锁 + LLM 异步文案) =====
CREATE TABLE IF NOT EXISTS role_milestones (
    milestone_id      TEXT PRIMARY KEY,
    save_id           TEXT NOT NULL,
    role_id           TEXT NOT NULL,
    rule_id           TEXT NOT NULL,
    title             TEXT NOT NULL DEFAULT '',
    description       TEXT NOT NULL DEFAULT '',
    icon              TEXT NOT NULL DEFAULT '',
    source_memory_id  TEXT NOT NULL DEFAULT '',
    unlocked_world_at REAL NOT NULL,
    created_at        INTEGER NOT NULL,
    UNIQUE(save_id, role_id, rule_id)
);
CREATE INDEX IF NOT EXISTS idx_role_ms_save
    ON role_milestones(save_id, role_id, unlocked_world_at DESC);

-- ===== 5) state_events(#22 事件日志空表;写入代码在 #22 实施时启用) =====
-- 启用前字段可扩充;启用后本表结构冻结。
CREATE TABLE IF NOT EXISTS state_events (
    event_id     TEXT PRIMARY KEY,
    save_id      TEXT NOT NULL,
    role_id      TEXT NOT NULL,
    kind         TEXT NOT NULL,              -- interaction | decay | cycle | manual
    delta_json   TEXT NOT NULL DEFAULT '{}', -- {stat: delta} 记录用,不进 prompt(#29)
    world_time   REAL NOT NULL,
    real_unix    INTEGER NOT NULL,
    note         TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_state_events_save_world
    ON state_events(save_id, role_id, world_time);

-- ===== 6) 版本登记(_migrate 执行时写入) =====
-- UPDATE heartloom_meta SET value = '6' WHERE key = 'schema_version';
