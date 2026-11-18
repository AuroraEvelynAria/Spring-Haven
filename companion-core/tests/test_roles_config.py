"""配置守卫:config/roles.example.json 的三角色模板必须能被 RoleRegistry 完整加载。

新角色入库时模板缺文件、字段超界或 prompt 文件丢失会在这里先红,
而不是等到运行时 Core 启动才失败。
"""
import unittest
from pathlib import Path

from spring_haven_core.roles import RoleRegistry

COMPANION_CORE_ROOT = Path(__file__).resolve().parents[1]
EXAMPLE_ROLES_PATH = COMPANION_CORE_ROOT / "config" / "roles.example.json"


class RolesExampleConfigTests(unittest.TestCase):
    def test_example_registry_loads_all_three_roles(self) -> None:
        registry = RoleRegistry.load(EXAMPLE_ROLES_PATH)
        self.assertEqual(registry.ids(), ["ling", "nai", "xixi"])

    def test_xixi_role_definition_resolves(self) -> None:
        registry = RoleRegistry.load(EXAMPLE_ROLES_PATH)
        role = registry.get("xixi")
        self.assertEqual(role.display_name, "汐汐")
        # 正式姓名待主人定夺,先以显示名占位;定名后同步 roles.json 与客户端展示表。
        self.assertEqual(role.full_name, "汐汐")
        self.assertEqual(role.age, 20)
        self.assertEqual(role.aliases, ("汐汐", "小汐"))
        self.assertEqual(role.mood_home, (0.2, -0.05, 0.05))
        self.assertIn("鲸鱼兽娘", role.persona_prompt)
        self.assertIn("汐汐专属 Heartloom Organizer", role.memory_prompt)

    def test_ling_and_nai_definitions_unchanged(self) -> None:
        registry = RoleRegistry.load(EXAMPLE_ROLES_PATH)
        for role_id, display_name in (("ling", "小玲"), ("nai", "小奈")):
            role = registry.get(role_id)
            self.assertEqual(role.display_name, display_name)
            self.assertEqual(role.mood_home, (0.0, -0.1, 0.05))
