-- v7 回滚稿:回滚会丢失 life_events 世界日列与 digest_state 世界日映射键,属预期行为。
-- (与 v6_world_time_rollback.sql 同为演练草案;ALTER DROP COLUMN 需 SQLite ≥ 3.35)

DROP INDEX IF EXISTS idx_life_events_save_world;
ALTER TABLE life_events DROP COLUMN world_occurred_at;
DELETE FROM digest_state WHERE day_key GLOB 'w[0-9]*';
UPDATE heartloom_meta SET value = '6' WHERE key = 'schema_version';
