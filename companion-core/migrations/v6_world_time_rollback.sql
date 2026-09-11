-- SCHEMA_VERSION 6 回滚脚本(ADR-001)
-- 首选回滚方式:从迁移前备份恢复(maintenance backup_to 产物),见 HeartloomStore 迁移演练流程。
-- 无备份时才使用本脚本;要求 SQLite >= 3.35(DROP COLUMN)。
-- 注意:回滚会丢失 world_time 列数据与已建边/成就记录,属预期行为。

DROP TABLE IF EXISTS state_events;
DROP TABLE IF EXISTS role_milestones;
DROP TABLE IF EXISTS memory_links;

ALTER TABLE memory_entries DROP COLUMN embedding_model;
ALTER TABLE memory_entries DROP COLUMN embedding_json;
ALTER TABLE memory_entries DROP COLUMN is_second_hand;
ALTER TABLE memory_entries DROP COLUMN lifecycle_changed_world;
ALTER TABLE memory_entries DROP COLUMN lifecycle;
ALTER TABLE memory_entries DROP COLUMN last_recalled_world;
ALTER TABLE memory_entries DROP COLUMN world_updated_at;
ALTER TABLE memory_entries DROP COLUMN world_created_at;

UPDATE heartloom_meta SET value = '5' WHERE key = 'schema_version';
