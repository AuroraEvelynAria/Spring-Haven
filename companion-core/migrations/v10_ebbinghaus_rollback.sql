-- v10 回滚(ADR-014):intrinsic 倒数重映射回旧语义并退回版本位 9。
-- 倒数变换自反:回滚用同一映射的对称形式 intrinsic' = 1/intrinsic,
-- 旧语义值域上界为 1.0,故钳制 [0.05, 1.0](新值域 [1,4] 的倒数落在
-- [0.25, 1.0],整段可精确还原——旧公式 S=hl/i 与新公式 S=hl×i' 在
-- i'=1/i 时逐条等价)。

UPDATE memory_entries
SET intrinsic = MIN(1.0, MAX(0.05, 1.0 / MAX(0.05, intrinsic)));

UPDATE heartloom_meta SET value = '9' WHERE key = 'schema_version';
