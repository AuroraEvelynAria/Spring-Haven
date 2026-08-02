# 客餐厅 Lightmap 与角色比例报告

日期：2026-07-22（Asia/Shanghai）

## 最终配置

- 客餐厅本地场景：`res://local_assets/living_dining/living_dining_baked.tscn`
- Lightmap 数据：`res://local_assets/living_dining/living_dining_baked_v9.lmbake`
- Lightmap 纹理：`res://local_assets/living_dining/living_dining_baked_v9.exr`
- 角色与房间资产继续位于 `local_assets/`，不会进入 Git 或导出 PCK。

Godot 导入使用 `meshes/light_baking=2`（Static Lightmaps）和 `0.1 m/texel`，确保 120/120 个房间网格、149 个表面均生成 UV2。最终缓存包含 5 层 512 x 512 光照图集，LightmapGIData 记录 120 个用户。

为避免复杂隔断阴影和高纹理材质造成彩色斑驳，最终烘焙采用高质量、无方向编码、关闭纹理反弹的一次中性间接光；三盏静态灯不烘焙硬阴影。运行时优先加载该场景，缓存缺失或无效时自动回退普通 GLB，并重新启用外层实时补光。

## 角色比例

- 玩家方块人：约 1.65 m，碰撞胶囊 1.66 m。
- 小玲本地占位模型：约 1.59 m，碰撞胶囊 1.62 m。
- 小玲方块回退视觉：约 1.61 m。
- 相机、NavigationAgent3D 与运行时 NavMesh 参数已同步缩小。

## 验证

- `LIGHTMAP_BAKE_CHECK passed=9`
- `ROOM_VISUAL_INTEGRATION_CHECK passed=8`
- `EXPLORATION_WORLD_CHECK passed=33`
- `NAVIGATION_STRESS_CHECK passed=42 cycles=4`
- `EXPLORATION_AI_FLOW_CHECK passed=15`
- 1280 x 720、关闭垂直同步：平均 165 FPS，P95 帧时间 6.826 ms。

最终截图：`_source_assets/ling_placeholder/exploration_scaled_lightmap_v9.png`

重新烘焙可运行 `res://scripts/diagnostics/LightmapBakeAutomation.gd`。脚本输出 `LIGHTMAP_BAKE_AUTOMATION=PASS` 后即表示缓存和场景引用已经保存；编辑器进程快速退出时出现的 RID/progress dialog 清理日志不影响烘焙产物。
