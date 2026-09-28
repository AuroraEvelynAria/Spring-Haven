-- v10(ADR-014):艾宾浩斯正式化。纯数据迁移,无 DDL、无新表;
-- 本文件为契约记录(与 v7/v8/v9 同角色);升级前强制备份 *.pre-v10.backup。
-- 实际语句以 memory.py::_migrate 的 v10 块为准。

-- intrinsic 语义:稳定度系数,有效半衰期 = half_life × intrinsic(1.0 = 标称)。
-- 旧实现为 half_life / intrinsic,护盾方向反转;存量按倒数重映射,
-- 在迁移瞬间逐条保持有效半衰期不变:
UPDATE memory_entries
SET intrinsic = MIN(4.0, MAX(1.0, 1.0 / MAX(0.05, intrinsic)));

-- SCHEMA_VERSION 9 → 10
