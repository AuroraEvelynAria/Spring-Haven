-- v9(ADR-012):PAD 心境基线。纯新增表,executescript 对旧库直建,零数据回填;
-- 本文件为契约记录(与 v6/v7/v8 同角色);升级前强制备份 *.pre-v9.backup。
-- 实际 DDL 以 memory.py::_migrate 的 schema 字符串为准。

CREATE TABLE IF NOT EXISTS mood_baseline (
    save_id          TEXT NOT NULL,
    role_id          TEXT NOT NULL,
    pleasure         REAL NOT NULL DEFAULT 0,
    arousal          REAL NOT NULL DEFAULT 0,
    dominance        REAL NOT NULL DEFAULT 0,
    world_updated_at REAL NOT NULL DEFAULT 0,
    updated_at       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (save_id, role_id)
);

-- SCHEMA_VERSION 8 → 9
