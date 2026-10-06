# 下一步要做什么（交接清单）

> 承接：`HANDOFF_START_HERE.md`（先按它把环境和工程还原好，并跑通门禁）
> 基线：`main` @ 备份前最后一次提交（`git log -1` 可见）；门禁 **GREEN**：unit 201 脚本/1473 用例、ui 33/212、build 0 警告 0 错误

---

## A. 已完成到哪（别重复做）

本项目是「世界扫雷」+ 关卡编辑器（Godot 4.7.2 mono / GDScript）。近几轮集中做完：

| 轮次 | 内容 |
|---|---|
| 编辑器数据爆炸防线 | 格子双档预算（事前估算硬阻）、邻接上限、组合熔断、撤销 diff/快照分离、**手绘点数上限 + Douglas-Peucker 抽稀 + 坐标量化（v3 兼容）**、**快照 md5 去重 + 全局配额**、ProofLog 体积上限 + 截断标记、导入总量闸门、存档原子写 |
| 形状与生成 | 环形（annulus）/ 正 N 边形生成器、**栅格化三档精度**（默认档与旧行为**逐格一致**，有测试钉住）、腐蚀/膨胀、**变体×网格矩阵**被 `editor_verify` 消费、`ngon/annulus` 登记进 `estimate_cells` 与矩阵 |
| 编辑器功能接线 | **形状布尔 / 形状 DAG（含环检测拒绝理由显示）/ 修复建议（1~3 修法 + 一键应用）/ 短码分享** 接进 UI；快捷键全套 + 绑定表存储；Mega 复合格**下钻 UI**；问题面板**三级**；热力图改用画布叠加 API |
| 新模块（core + 测试齐） | `core/shape_reflow.gd`（重栅格化保留手工格）、`core/domino_model.gd` 骨牌**划分/校验**、`core/text_to_shape.gd`（文字/手绘→形状）、`core/stats_histogram.gd`、`core/editor_disclosure.gd`（渐进披露 + 配色锁定）、`core/file_lock.gd`（存档占用锁）、`core/level_thumbnail.gd`（数据缩略图）、`core/stroke_limits.gd`（笔迹常量单源） |
| 门禁工具 | `tools/gut_shards.ps1`（**并行分片** + 碰 `user://` 文件自动串行片 + **缺摘要分片定向重跑** + 红时保留证据 + `-SimulateMissingShard` 自测开关）、`tools/ci_quick.ps1`（增量门禁）、`tools/ci_lock.ps1`（跨进程锁） |

**关键性能事实**：门禁从早期 **420 s 单进程串行** 降到 **≈160~250 s**（unit 10 片并行 + ui 3 片；`test/ui` 里 15 个有状态文件走串行片独占约 235 s，是时长主因）。

---

## B. 还没做（按优先级；每条都给了落点）

### B1（高）UI 接线余项 —— 对应的 **core 能力与测试都已就绪**，只缺界面入口
| 项 | core 已就绪 | 建议落点 |
|---|---|---|
| **骨牌划分编辑器** | `DominoModel.partition(grid, region)` / `verify_partition(...)`（`core/domino_model.gd:304/:360`，测试 `test/unit/test_domino_partition.gd`） | `ui/level_editor.gd`（新增一个页签或属性区） |
| **文字 / 手绘轮廓 → 形状 入口** | `TTS.text_to_cells(text, font_mask, scale, grid, origin)` / `outline_to_cells(points, grid, tolerance)`（`core/text_to_shape.gd:62/:119`） | 形状面板 + `ui/drawing_layer.gd` 的手绘完成回调 |
| **重栅格化保留手工格** | `ShapeReflow.reflow(grid, old_cells, new_cells, hand_edited)` / `describe_reflow`（`core/shape_reflow.gd`）。**接线口径已定**：`grid` 传**新形状盘对象**；手工格负载**无条件优先** | 形状切换/参数变更路径（原来只做"丢弃盘外格"） |
| **直方图面板** | `StatsHistogram.histogram(values, buckets, min, max)` / `describe`（`core/stats_histogram.gd:36/:108`） | 统计面板 |
| **配色锁定提示** | `EditorDisclosure.lock_report(variants_with_colors)`（`core/editor_disclosure.gd:121`） | 变体/配色面板 |
| **简单-专家渐进披露** | `EditorDisclosure.visible_controls(mode, ids)`（`core/editor_disclosure.gd:69`，未知 id 策略 = **fail-visible**） | 编辑器初始化时统一 `set_visible` |
| 四象染色预览 / 行容量侧栏 | —（尚未实现） | `ui/level_editor.gd` |
| **检查进度（标记插错的旗）** | —（尚未实现；现有格型见 `ui/editor_canvas.gd` 的格型枚举） | 需新增一种"标记"格型 + 试玩侧统计 |
| 只读分享 / 认证提交入口 | `core/share_code.gd` 已有导入导出 | 分享面板 |

> ⚠ 两个已定但**尚未接线**的口径，接线时不要改：① `shape_reflow` 的 `grid` = 新形状盘；② `ShapeDag` 的 `ring` = **annulus**，而 `to_adjacency_grid` 的 `"ring"` = **同心环盘**（同名不同义！UI 必须**按 `builder_name` 派发**，见 `ui/level_editor.gd` 的 `_call_shape_builder`）。

### B2（需你拍板）`probe40` 类重用例的优化
`test/ui/test_probe40_roundtrip.gd` 单文件 180~390 s（负载敏感），它是 `test/ui` 串行片的主要耗时。
- 可动的地方：每关"双生成"改"首关双生成 + 其余单生成"、60 s 预算改 20 s 超时即记 pending、`ui_9x9_timeout_budget` 3 seed 改 1 个等；
- **代价**：这些都是**验证强度取舍**（60 s 预算是当初为消除"机器忙就随机红"故意放宽的），**需要你点头**，负责人不应擅自改。

### B3（低）其它
- 门禁里 `dotnet build` 每次都跑（约 3.5 s）：可改成"仅 `.cs` 变更时跑"（收益小，我判断不值得）；
- Windows Defender 排除（见 `START_HERE.md` §4）；
- `core/domino_model.gd` 的 `place()` 已统一为**正交 1×2/2×1**（对角不再算合法骨牌）——若有历史存档含对角骨牌，`validate` 会报 `not_adjacent`，属**预期**（脏数据现形，而非静默放过）。

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
- **清空容器必须 `remove_child` 再 `queue_free`**（`queue_free` 延迟到帧末 ⇒ 同帧重填会让 `get_child(0)` 是过期节点；`ui/level_editor.gd` 已修 3 处，`_replay_rows` 早有正解可参考）。

---

## D. 常用命令速查

```powershell
# 全量门禁（判定：CI GREEN + unit 201/1473 + ui 33/212 + build 0 警告 0 错误）
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
