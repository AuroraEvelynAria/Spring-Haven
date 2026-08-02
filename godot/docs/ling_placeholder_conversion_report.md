# 小玲本地占位模型转换报告

日期：2026-07-21（Asia/Shanghai）

## 结论

达妮娅 PMX 已转换为 Godot 4.7 可加载的本地测试 GLB。该产物只用于验证小玲的平移、导航与场景交互，不是可发布角色资产。源 PMX 未被修改，GLB 及 Godot 自动提取的贴图均位于 `local_assets/`，不会进入 Git 或任何导出 PCK。

最终产物：`res://local_assets/ling_placeholder/ling_placeholder.glb`

## 固定工具链

- Blender：2.93.18 portable
- Blender 可执行文件 SHA-256：`fbaab8edf149b4276a1728c163833bb7004af3f2f3d5a8dd3504d83fcc7d6ee1`
- mmd_tools_local：0.7.2
- mmd_tools_local `__init__.py` SHA-256：`8a65d9621f93ed0d357c832241e3e7486b3aadd8c6390dab9f166dc942b40814`
- Godot：4.7.stable.official.5b4e0cb0f
- 渲染验证：OpenGL 3.3 Compatibility，NVIDIA GeForce RTX 4070 Laptop GPU

源 PMX SHA-256 在转换前后均为：

`24ca0155c0679dca8680923636dfb1a917eb6174a09958be39ab705cbfef647b`

## 转换策略

- 以 `0.1 m / PMX 单位` 导入，最终 Godot 包围盒高度约 1.941 m。
- 保留网格、33 个材质、基础贴图、Armature 与 Skin。
- 将 MMD 专用节点组转换为 glTF 可识别的 Principled BSDF。
- 透明材质统一导出为确定性的 alpha clip，避免头发等透明面的排序闪烁。
- 对完整模型根节点做 180° 航向修正，使角色正面遵循 Godot 的 `-Z` 前向约定。
- 不导出 Morph 与动画。源目录没有 VMD/VPD 动作，当前占位需求也只要求整体平移。
- 忽略缺失的 MMD 共享 `toon01/04/05/07.bmp`，用中性粗糙度/高光降级；33 个模型自有基础贴图槽全部成功解析。

## 最终指标

| 指标 | 结果 |
|---|---:|
| GLB 大小 | 27,888,592 bytes |
| GLB SHA-256 | `a41bcc16db7681db6a6da12069df5f8e4802196e7bb7dac7319e5029e9cad0da` |
| 源顶点 | 96,705 |
| 三角面 | 126,960 |
| Mesh / primitive | 1 / 33 |
| 材质 | 33 |
| GLB 图像 / 纹理引用 | 16 / 33 |
| Skin | 1 |
| Skin joints | 807 |
| Godot 包围盒 | 1.261082 × 1.941084 × 0.738743 m |
| 动画 / Morph target | 0 / 0 |

Godot 会按 4.7 的默认嵌入图像策略，把 GLB 内的 16 张图像提取到同一个 `local_assets/ling_placeholder/` 目录。这些生成文件仍受同一 Git/PCK 防护覆盖。

## 验证结果

| 验证 | 结果 |
|---|---|
| Blender 2.93 PMX 导入与 GLB 导出 | PASS |
| 相同输入连续导出 SHA-256 一致 | PASS |
| 源 PMX 前后 SHA-256 不变 | PASS |
| Godot 4.7 编辑器真实导入 | PASS |
| Godot PackedScene 实例化 | PASS |
| 126,960 三角面、33 surfaces/materials | PASS |
| 16 张唯一 albedo texture、807 bones | PASS |
| 1.941 m 高度与脚底原点 | PASS |
| Godot GPU 正面渲染及透明裁剪 | PASS |
| `.gitignore` 本地目录隔离 | PASS |
| EditorExportPlugin 静态检查 | PASS |
| `all_resources` 真实 PCK 中角色与客餐厅路径均不存在 | PASS |

真实 PCK 验证包位于本地 `_source_assets/ling_placeholder/local_asset_guard_test.pck`，不属于项目发布产物。测试时磁盘 `local_assets/` 总量约 241 MB；从 PCK 内运行诊断后，角色与客餐厅两个受保护路径均不可访问。

Godot 控制台仍会输出项目既有的 `Unexpected NUL character` 警告；该警告在加入本模型前已存在，不影响 GLB 的资源加载、骨架、材质或渲染验证。

## 复现与诊断

在项目根目录执行：

```powershell
.\tools\local_assets\Export-LingPlaceholder.ps1
.\tools\local_assets\Test-LocalAssetIsolation.ps1
& 'C:\tmp\Godot-4.7\Godot_v4.7-stable_win64_console.exe' --headless --editor --path . --import --quit-after 2
& 'C:\tmp\Godot-4.7\Godot_v4.7-stable_win64_console.exe' --headless --path . --script res://scripts/diagnostics/LingPlaceholderImportCheck.gd
```

GPU 截图检查由 `LingPlaceholderRenderCheck.gd` 执行，输出保存在本地 `_source_assets/ling_placeholder/godot_render.png`。

正式发布前必须用获得明确发布授权、经过性能整理且带正式动作的角色资产替换此占位模型。
