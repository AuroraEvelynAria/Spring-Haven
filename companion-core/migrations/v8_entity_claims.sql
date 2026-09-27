-- v8(ADR-009):实体-主张层。纯新增表,executescript 对旧库直建,零数据回填;
-- 本文件为契约记录(与 v6/v7 同角色);升级前强制备份 *.pre-v8.backup。
-- 实际 DDL 以 memory.py::_migrate 的 schema 字符串为准。

CREATE TABLE IF NOT EXISTS entities (
    entity_id    TEXT PRIMARY KEY,
    save_id      TEXT NOT NULL,
    kind         TEXT NOT NULL DEFAULT 'concept',
    name         TEXT NOT NULL,
    name_norm    TEXT NOT NULL,
    aliases_json TEXT NOT NULL DEFAULT '[]',
    world_created_at REAL NOT NULL DEFAULT 0,
    world_updated_at REAL NOT NULL DEFAULT 0,
    UNIQUE (save_id, name_norm)
);
CREATE INDEX IF NOT EXISTS idx_entities_save_norm ON entities(save_id, name_norm);

CREATE TABLE IF NOT EXISTS claims (
    claim_id    TEXT PRIMARY KEY,
    save_id     TEXT NOT NULL,
    subject_entity_id TEXT NOT NULL,
    predicate   TEXT NOT NULL,
    object_entity_id  TEXT,
    object_text TEXT NOT NULL DEFAULT '',
    source_memory_id  TEXT NOT NULL DEFAULT '',
    confidence  REAL NOT NULL DEFAULT 0.8,
    world_from  REAL NOT NULL DEFAULT 0,
    world_to    REAL,
    superseded_by_claim_id TEXT,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_claims_subject
    ON claims(save_id, subject_entity_id, predicate);
CREATE INDEX IF NOT EXISTS idx_claims_current
    ON claims(save_id, subject_entity_id) WHERE world_to IS NULL;
CREATE INDEX IF NOT EXISTS idx_claims_source
    ON claims(save_id, source_memory_id);

-- SCHEMA_VERSION 7 → 8
