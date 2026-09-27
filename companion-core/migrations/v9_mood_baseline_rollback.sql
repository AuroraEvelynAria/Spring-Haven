-- v9 回滚:drop 心境基线表,版本位退回 8(ADR-012)。
-- 仅在从 v9 降级到 v8 构建时手工执行;正常运行永不触发。

DROP TABLE IF EXISTS mood_baseline;

UPDATE heartloom_meta SET value = '8' WHERE key = 'schema_version';
