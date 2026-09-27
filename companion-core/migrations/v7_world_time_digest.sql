-- v7(#23 收尾):digest / weekly 切世界时间
-- 实际迁移由 memory.py::_migrate 幂等执行(守卫式 ALTER + 一次性回填),
-- 本文件为契约记录,与 v6_world_time.sql 同角色;升级前强制备份 *.pre-v7.backup。

ALTER TABLE life_events ADD COLUMN world_occurred_at REAL NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_life_events_save_world ON life_events(save_id, world_occurred_at);

-- 数据回填(python 侧执行,stored_version < 7 时一次):
-- 1) life_events.world_occurred_at =
--    MAX(0.0, world_value + (occurred_at_unix - anchor_real) / 86400.0 * rate)
--    (钳 0:补报的早于旅程锚点的事件不落负世界日)
-- 2) digest_state 旧现实日期键(YYYY-MM-DD)按同口径映射出 w{day:04d} 新键
--    (INSERT OR IGNORE,旧键保留作审计;避免升级后同一天被二次 digest)
-- 3) day_key 语义变更:现实日期 → 世界日键 `w{day:04d}`;
--    周键:现实 ISO 周 → 各存档世界周键 `world-w{week:04d}`(见 service.py)
-- SCHEMA_VERSION 6 → 7
