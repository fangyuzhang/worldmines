# 下一步要做什么（交接清单）

> 承接：`HANDOFF_START_HERE.md`（先按它把环境和工程还原好，并跑通门禁）
> 代码基线：`main` @ `a01b324`（异形盘格线修复 `6fea403` + 编辑器左栏三页坞 `f4e2de9`
> + **属性页分段 / 面板内容铺满宽度** `a01b324`；文档更新提交在其后，`git log` 可见）；
> 门禁 **GREEN**（2026-10-09 实测）：unit **215 脚本 / 1658 用例 / 92850 断言**、
> ui **34 脚本 / 232 用例 / 8581 断言**、build **0 警告 0 错误**

---

## A. 已完成到哪（别重复做）

本项目是「世界扫雷」+ 关卡编辑器（Godot 4.7.2 mono / GDScript）。近几轮集中做完：

| 轮次 | 内容 |
|---|---|
| 编辑器数据爆炸防线 | 格子双档预算（事前估算硬阻）、邻接上限、组合熔断、撤销 diff/快照分离、**手绘点数上限 + Douglas-Peucker 抽稀 + 坐标量化（v3 兼容）**、**快照 md5 去重 + 全局配额**、ProofLog 体积上限 + 截断标记、导入总量闸门、存档原子写 |
| 形状与生成 | 环形（annulus）/ 正 N 边形生成器、**栅格化三档精度**（默认档与旧行为**逐格一致**，有测试钉住）、**边缘平滑（腐蚀/膨胀，连通区域守恒是硬闸）**、**Voronoi 不规则镶嵌**（抖动晶格撒种 → 多源 BFS → 矩形化边界；种子 1/65536 量化 + 回显）、**变体×网格矩阵**与**变体×复合格矩阵**均被 `editor_verify` 消费 |
| 编辑器功能接线 | **形状布尔 / 形状 DAG（含环检测拒绝理由显示）/ 修复建议（1~3 修法 + 一键应用）/ 短码分享 / 只读分享 / 认证提交（本地审核队列 + 流转状态）/ 文字→形状 / 四象染色预览 / 行容量侧栏 / 统计直方图 / 配色锁定 / 简单-专家渐进披露 / 重栅格化保留手工格 / 试玩「检查进度」** 接进 UI；快捷键全套 + 绑定表存储；Mega 复合格**下钻 UI**；问题面板**三级**；热力图改用画布叠加 API |
| 新模块（core + 测试齐） | `core/shape_reflow.gd`（重栅格化保留手工格）、`core/domino_model.gd` 骨牌**划分/校验**、`core/text_to_shape.gd`（文字/手绘→形状）、`core/stats_histogram.gd`、`core/editor_disclosure.gd`（渐进披露 + 配色锁定）、`core/file_lock.gd`（存档占用锁）、`core/level_thumbnail.gd`（数据缩略图）、`core/stroke_limits.gd`（笔迹常量单源）、`core/mega_variant_matrix.gd`（复合格 × 变体门禁表） |
| 自定义格形（§3） | 六边形 / 三角形 / **Voronoi** 三族齐；每族**四处登记齐活**才算接线：`to_adjacency_grid` + `EditorDoc.estimate_cells` + `VariantGridMatrix` + `AdjacencyBuilder.from_tiling`；UI 形状下拉 6→8 项（含等轴菱面错觉盘） |
| 拓扑玩法（第五期） | 虫洞配对 → 环绕盘 → 形状安全门 → 不可能几何（等轴菱面）→ 静态折叠 → **折纸族（多折痕顺序折叠）**；`core/fold_model.gd` / `topology_model.gd` 已进加载/呈现/生成器，`fold_01..12` 共 12 张折叠官方关；编辑器属性页已补折痕**加/删**面板与画布折线 |
| 计算内存（§G） | 空间哈希（`core/shape_fill.gd` 只按整数格集做碰撞，无 O(N²) 多边形对；`ShapeBoolean.MAX_CELL_BUDGET` 前置硬阻）、**换形状滑杆去抖**（`ui/level_editor.gd` 的 `SHAPE_COALESCE_MS` / `_on_shape_size_changed` / `_shape_change_due`：拖动只登记待办，`_process` 合并成一次；离散换族立即执行并清空待办 —— 文档 §G4「新任务入队即取消排队中未开始的旧任务」在本仓**同步路径**上的等价实现，有 3 个用例钉住） |
| 编辑器 UI 框架（第九轮） | **常驻顶栏**（关卡名 + 未保存星号 + 撤销/重做/试玩/保存/说明/返回选关，`_build_editor_topbar` / `_refresh_topbar_title`）+ 左右栏统一升级成**可折叠组**（`_wrap_collapsible_group` / `_bind_collapsible` / `_set_props_groups_collapsed`，属性页再给"展开全部/收起全部"）+ 左栏流程按钮 2×2；实测左栏内容 3200→1721px、属性页 5000+→1795px、画布 702×632（1280×720）；左栏里重复的撤销/重做/返回选关已删（全局动作单一来源 = 顶栏） |
| 异形盘线条（2026-10-09） | 用户报「异形关线不连续、有颗粒感，矩形关没有」。根因两层：**格线恒 1px**（斜线落在非整数像素 ⇒ 灰阶 58/75/91/125 四档跳）+ **异形盘跳过 `_draw_board_mat`**（格缝露视口底色 ⇒ 线是「细线+黑带+细线」）。修法：`_shape_grid_line_w()` 按视觉格边长缩放（1~3px，矩形盘零回归）+ `_draw_shape_mat()` 逐格外扩铺不透明板色（外扩量取**真·多边形间距**，缓存持 Board 引用）。实测**只有蜂窝盘真有缝**（kmax≈1.07），其余 8 族逐像素零回归 |
| 编辑器左栏三页坞（2026-10-09） | 用户原话「编辑器太丑了，根本没法用」。左栏 **1754px 长条 → 三页**（流程/工具/分享，实测 537/851/358 vs 视口 611）；左栏加 **PanelContainer 底板**（分页后内容短于视口会露窗口底色）；组框加**左侧强调色竖条**。**不新增 TabContainer**（契约见 B4） |
| 编辑器属性页分段 + 铺满宽度（2026-10-09） | 左栏三页坞之后，右栏属性页 16 个组标题仍排一列（要滚 2.9 屏）⇒ 按「基础 / 形状与盘面 / 高级工具」**切三段**（互斥按钮 + 互斥可见的滚动段，**仍不新增 TabContainer**），搬之前核对「框数 == 组标题数」不许丢组。顺手抓到 **box 只给 `SIZE_FILL` ⇒ `ScrollContainer` 不拉满它**：切到第 3 段整列只剩 186px、组标题折两行；改 `EXPAND_FILL` 后三段 322~330 宽、标题一行。真机三段高 **610 / 616 / 300**（视口 616；改前 637 / 849 / 500） |
| 门禁工具 | `tools/gut_shards.ps1`（**并行分片** + 碰 `user://` 文件自动串行片 + **缺摘要分片定向重跑** + 红时保留证据 + `-SimulateMissingShard` 自测开关）、`tools/ci_quick.ps1`（增量门禁）、`tools/ci_lock.ps1`（跨进程锁） |

**关键性能事实**：门禁从早期 **420 s 单进程串行** 降到 **≈160~250 s**（unit 10 片并行 + ui 3 片；`test/ui` 里 15 个有状态文件走串行片独占约 235 s，是时长主因）。

---

## B. 已完成 / 还没做（按优先级；每条都给了落点）

### B1（高）UI 接线余项 —— **已完成**（2026-10-09；下表是留档的落点索引，用户视角已可见）
| 项 | 落地位置（以代码为准） |
|---|---|
| **骨牌划分编辑器** | `ui/level_editor.gd` 的 `_build_domino_panel`（结论常驻，失败给逐格坐标） |
| **文字 / 手绘轮廓 → 形状 入口** | `ui/level_editor.gd` 的 `_build_text_shape_entry` + `ui/editor_canvas.gd` 手绘完成回调（放不下会自动降档并**说出来**） |
| **重栅格化保留手工格** | `ui/level_editor.gd` 的 `_apply_shape_change` / `_reflow_trial`（`ShapeReflow.reflow`；有手工格会掉出盘外时**先还原旧形状**再让用户确认） |
| **直方图面板** | `ui/level_editor.gd` 的 `_build_stats_panel`（雷密度 + 数字分布） |
| **配色锁定提示** | `ui/level_editor.gd` 的 `_build_color_lock_panel`（同色组 ≥2 个不同变体即冲突） |
| **简单-专家渐进披露** | `ui/level_editor.gd` 的 `_apply_disclosure`（未知 id = **fail-visible**，漏列控件不会被误藏） |
| **四象染色预览 / 行容量侧栏** | 预览开关在 `_build_left_bar`、`_toggle_quadrant_preview`（色号走 `ConstraintEngine.quadrant_of`）；行容量在 `_build_props_tab`（可行性走 `ColoringPreview.row_report`，行语义未定义的族由矩阵门禁拒绝） |
| **检查进度（标记插错的旗）** | 试玩态：`ui/hud.gd` 发信号 → `ui/board_view.gd` 标/清（判据 `core/progress_check.gd`；红叉与终局**共用同一支笔**）。**仅试玩态可用**（硬约束） |
| **只读分享 / 认证提交入口** | 短码分享面板（`_export_share_code` / `_import_share_code` / `_enter_read_only_share`）；认证提交 = `SubmissionQueue` 本地队列 + 流转状态（**不假装联网**） |
| **折痕作者入口** | `ui/level_editor.gd` 的 `_build_fold_panel` / `_on_fold_added` / `_on_fold_delete`；画布线段 `ui/editor_canvas.gd` 的 `fold_crease_segments`；非法追加只提示不脏写，序列可撤销、可落盘往返 |

> ⚠ 两个已定口径，**已接线**但仍不许改：① `shape_reflow` 的 `grid` = 新形状盘；② `ShapeDag` 的 `ring` = **annulus**，而 `to_adjacency_grid` 的 `"ring"` = **同心环盘**（同名不同义！UI 必须**按 `builder_name` 派发**，见 `ui/level_editor.gd` 的 `_call_shape_builder`）。

### B2（已决策：不动）`probe40` 类重用例的优化
`test/ui/test_probe40_roundtrip.gd` 单文件 180~390 s（负载敏感），它是 `test/ui` 串行片的主要耗时。
- 可动的地方：每关"双生成"改"首关双生成 + 其余单生成"、60 s 预算改 20 s 超时即记 pending、`ui_9x9_timeout_budget` 3 seed 改 1 个等；
- **代价**：这些都是**验证强度取舍**（60 s 预算是当初为消除"机器忙就随机红"故意放宽的），属验证强度取舍。
- **决策（2026-10-09）**：**不削弱**。用户虽已授权自行拍板，但本项与 code.md 功能清单无关（只是门禁时长优化），
  而降低预算会把"机器忙就随机红"重新引回来 —— **维持现状**；若将来 CI 时长成为瓶颈，再按上面三个旋钮单独评估。

### B3（低）其它
- 门禁里 `dotnet build` 每次都跑（约 3.5 s）：可改成"仅 `.cs` 变更时跑"（收益小，我判断不值得）；
- Windows Defender 排除（见 `START_HERE.md` §4）；
- `core/domino_model.gd` 的 `place()` 已统一为**正交 1×2/2×1**（对角不再算合法骨牌）——若有历史存档含对角骨牌，`validate` 会报 `not_adjacent`，属**预期**（脏数据现形，而非静默放过）。

### B4（低）编辑器 UI 还能再往前一步（结构 + 观感都已做完，下面是余量）
> 结构在 `b4705c4` 解决（全局动作进顶栏、左右栏可折叠组、属性页默认只展开核心 6 组）；
> **观感/可用性**在 `f4e2de9` 解决（左栏三页坞 + 底板 + 组框强调条）。剩下的是便利层面，
> 不是「能不能用」层面；动它们前先跑 `tools\ci_quick.ps1`（`level_editor` 已映射 4 个用例文件）。
- **契约：全编辑器只允许一个 `TabContainer`**（右侧 4 页）。`test_level_editor_smoke.gd:49`
  按 `tabs.size() == 1` 断言、`test_editor_ux.gd:_tabs_of` 取 `find_children(...)[0]`。
  左栏分页因此用「互斥按钮 + 互斥可见的滚动页」（`_build_left_dock_switcher` / `_show_left_page`）
  —— **想加第二个 TabContainer 必须先改这两条契约**；
- **契约：左栏组宿主是复数**。分页后组宿主从一个变三个，套框后处理必须走
  `_collect_group_hosts`（遍历全部）而不是只认第一个；`_find_group_host` 只在属性页用；
- **属性页再分层 —— 已完成**（`a01b324`）：三段 = 基础 / 形状与盘面 / 高级工具，
  落点 `_paginate_props` / `_group_title_of` / `_props_page_of` / `_show_props_page`，
  做法同左栏（互斥按钮分页），**仍不新增 TabContainer**。要再动它先看 C4 的两条同名血泪：
  ① 隐藏的兄弟节点**不参与排版** ⇒ 量它的 `get_combined_minimum_size()` 是**假数字**；
  ② `ScrollContainer` 只在子节点带 **EXPAND** 时才把它拉满宽度；
- **记住展开状态**：现在每次打开都是「核心展开、高级收起」。若用户授权，可以把每个组的开合状态
  存进 `user://` 下的 editor 配置（与 `_dirty` 无关，别写进关卡存档）；
- **工具页 851px vs 视口 611px**：还要滚 1.4 屏。真要再省得把「工具 / 格型」改成两列图标按钮 ——
  有测试按按钮宽度 ≥60px 兜底（`test_no_button_is_squeezed_into_an_empty_box`），
  且本项目踩过「`clip_text` 把按钮压成小方块（用户报告"有些按钮没有内容"）」的坑，改前先看那条测试。

---

## C. 在这个仓库上工作的规则（血泪版，建议照做）

### C1 用哪些 Agent、怎么用
- **并发子 Agent 上限 ≈ 4**：实测 **2 路 ✅、4 路 ✅、6 路与 8 路都触发 CodeBuddy 扩展宿主崩溃**（机器资源充足，是宿主侧问题）。派发前先想清楚这波要不要 4 路以上。
- **文件所有权必须互斥**：`ui/level_editor.gd` 是最大热点，**同一时刻只允许一个 Agent 写它**；其余路做**新文件**（core 切片），交付时附"接线契约"，UI 由单独一路（或你自己）接。
- **别让每个 Agent 都跑全量门禁**：会互相拖垮（见 C2）。要求它们只跑自己的 GUT 用例 + `ci_quick.ps1`。

### C2 测试纪律
- **一切 Godot 运行必须持 `tools/.ci_lock`**（Godot 无 `--user-data-dir`，并发抢 `user://` ⇒ 有状态用例假红）。
- **红了不许删日志**；先 grep `[Failed]` 定位。
- **`--check-only --script` 无效**（不注册 autoload），要验就真跑。
- **改完必须 grep 落点**：`replace_in_file` 出现过"报成功但磁盘未变"的情况。

### C3 验收纪律（对 Agent 的交付）
- **不采信自述**：每轮至少独立复跑它声明的新测试，并抽查它给的 `文件:行`。本轮就抓到过"自报 4/4 全过、实际 5 用例 1 失败"。
- 交付物要求含：改动 `file:line`、**真实数字**（用例数/断言数/EXIT）、与描述不符之处（**以代码为准**）。
- 若 Agent 说"我的现状描述与代码不符" ⇒ **以代码为准**，并让它把纠正写进结论（本轮共纠正了我 6 处）。

### C4 代码偏好（这几轮反复用到的形态）
- **判界一律问网格**（`grid().in_board()`），**禁止** `cols/rows` 包围盒 —— 形状盘有洞格，包围盒会把洞格/负坐标当盘内（已修 3 处：粘贴、复制、修复建议目标判定）。
- **单一事实来源**：能收口的判据/常量都收进 core（如 `can_apply()`、`stroke_limits.gd`、`TIER_OF` 表），UI 只转发；**禁止 core → ui 依赖**（已消除，`core/` 下不得再出现 `res://ui/`）。
- **双实现必须有对拍测试**（如两份 Douglas-Peucker：36 组输入逐位对拍）。
- **必写的不变量**：守恒（`sum(buckets)==n`）、子集（专家可见 ⊇ 简单可见）、`默认档 == 旧行为`、"改完不许静默丢"（手工格/问题条目）。
- **相邻格「缝宽」只能用真·多边形间距算，不能用格心距**：`格心距/2 − 内切半径` 只在相邻同尺寸时成立，扇形格（`ring_01`）会算出 1.8× 假缝、三角+十二边形（`t31212_01`）算 3.7× ⇒ 垫色糊到盘轮廓外。`ui/board_view.gd` 的 `_polygon_gap`（含「顶点落进对方 ⇒ 0」的包含判定）才是判据；
- **RefCounted 做缓存键必须持引用，不能用 `instance_id`**：`Board` 是 `RefCounted`，旧对象被回收后 id 会被复用 ⇒ 缓存会命中到**另一个盘**上。`_seam_ratio_board` 就是这么修过来的；
- **UI 高度别信「隐藏页 + autowrap 组标题」的 `get_combined_minimum_size()`**：隐藏的兄弟节点 Godot **根本不排版**，
  它在 min-size 里的宽度是 1px；`autowrap` 的 Label 在 1px 宽下会被折成 47 行、报出几千像素的**假高度**
  （上一轮属性页那条 7248px 的红灯就是这么来的 —— 切过去实测只有 849px）。量版式要么**先切到那一段再量 `size.y`**，
  要么给足真实宽度；已经按这个口径写进 `test_props_page_stays_short_enough_to_use`；
- **`ScrollContainer` 的横向拉满靠 `SIZE_EXPAND`，不是 `SIZE_FILL`**：子节点只给 FILL 时它会缩到「内容最小宽」
  （属性页 `box` 少写一个 EXPAND ⇒ 切到第 3 段整列只剩 186px、组标题折两行；左栏 `outer` 一直是 `EXPAND_FILL` 才没踩到）。
  改版式前先对照同级容器的 `size_flags_horizontal`；
- **清空容器必须 `remove_child` 再 `queue_free`**（`queue_free` 延迟到帧末 ⇒ 同帧重填会让 `get_child(0)` 是过期节点；`ui/level_editor.gd` 已修 3 处，`_replay_rows` 早有正解可参考）。

---

## D. 常用命令速查

```powershell
# 全量门禁（判定：CI GREEN + unit 215/1658 + ui 34/232 + build 0 警告 0 错误）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci_check.ps1

# 增量门禁（日常迭代）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci_quick.ps1

# 单跑某个测试（务必持锁）
. tools\ci_lock.ps1
$G = "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"
$lk = Enter-CiLock -Path tools\.ci_lock -TimeoutSeconds 900
try { & $G --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_xxx.gd -gexit } finally { Exit-CiLock -Lock $lk }

# 分片跑（可只跑/跳过某批）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\gut_shards.ps1 -Dir res://test/unit -Shards 10 -Log tools\_ci_gut.log -Godot $G
#   -Only '正则' 只跑匹配的文件；-Skip '正则' 跳过匹配的文件

# 提交风格（每轮一件事，正文写清"做了什么 + 为什么 + 数字"）
git add -A; git commit -m "perf(ci): ...；实测 unit 6 片 134s -> 10 片 92.3s"
```

---

## E. 一句话给下一个接手的 AI

> 先把 `tools\ci_check.ps1` 跑绿；任何"新增能力"都要 **core 实现 + 测试 + UI 接线**三件齐（本项目历史上最大的病就是"core 有、测试有、UI 零引用 ⇒ 用户视角等于没有"）；改完用**独立复跑 + grep 落点**验证，不要采信任何自述（包括你自己的判断）。
