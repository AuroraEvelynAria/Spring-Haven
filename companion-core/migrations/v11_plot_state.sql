-- v11(ADR-016):故事脊椎运行时状态。纯新增表,executescript 对旧库直建,
-- 零数据回填;本文件为契约记录(与 v6/v7/v8/v9 同角色);
-- 升级前强制备份 *.pre-v11.backup。
-- 实际 DDL 以 memory.py::_migrate 的 schema 字符串为准。

CREATE TABLE IF NOT EXISTS plot_state (
    save_id            TEXT NOT NULL,
    plot_id            TEXT NOT NULL,
    spine_json         TEXT NOT NULL DEFAULT '[]',
    current_beat_id    TEXT NOT NULL DEFAULT '',
    entered_world_day  REAL NOT NULL DEFAULT 0,
    started_world_day  REAL NOT NULL DEFAULT 0,
    history_json       TEXT NOT NULL DEFAULT '[]',
    updated_at         INTEGER NOT NULL,
    PRIMARY KEY (save_id, plot_id)
);

-- SCHEMA_VERSION 10 → 11
