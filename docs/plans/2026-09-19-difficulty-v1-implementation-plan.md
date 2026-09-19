# 难度体系 v1 实施计划

> **执行方式**：逐任务执行，每个任务单独提交；任务间跑对应测试（GUT）。
> **依据设计**：`docs/plans/2026-09-19-difficulty-system-design.md`（含 §12 探针实测）
> **依据数据**：52,988 关实测（`tools/difficulty_quantiles.sh` / `difficulty_supply_matrix.sh` / `probe_peak_window.gd`）

**Goal:** 把"难度"从**长度语义**（Σ1/批量，与步数秩相关 0.923）换成**深度语义**（单步最大必要线索数 peak），使难度可跨变体/跨尺寸比较、可解释、且对用户自建变体零配置可用。

**Architecture:** 只改"难度这一层"——判据定义（core）+ 两个生成入口的验收（量产工具 / 自举平台）+ 存量离线重标 + UI 标签。**生成内核、解题器、Mod/RulePlugin 契约、沙箱全部不动**（探针已证明：峰值与标量目标正交，无需新搜索算法）。

**Tech Stack:** Godot 4.7 mono（GDScript + C# CP-SAT）、GUT、Python 3（离线重标/分析）、Ubuntu 2 核服务器

---

## 0. 不变式与非目标

### 必须保持（改动不得触碰）
| 不变式 | 原因 |
|---|---|
| `RulePlugin` API（`get_rule_id/get_kind/describe/compute_clue/build_clue_constraints`） | **自举平台的作者契约**；探针已证难度判据只依赖前两者，mod 无需任何新声明 |
| `manifest.json` 字段（id/version/api_version/entry） | 同上 |
| `PuzzleGenerator.generate_with_rules` 签名 | 所有调用方（19 处测试 + 3 个入口）都依赖；本计划**只加不改**（窗口在调用侧验收） |
| 权限沙箱 / `capability_grant` / `ModAPI` | 与难度正交 |
| 断点续跑语义（`_scan_unit` / `_unit_full`） | 服务器长跑依赖 |

### 非目标（YAGNI，明确不做）
- ❌ 加权成本表（对方方案）——用户变体处必崩
- ❌ 分位自标定——会把 o8 的 peak=1 定义成"噩梦"
- ❌ 离线大池建库——保留在线生成 + 断点续跑
- ❌ RankScore 择优（二期，需先 A/B）
- ❌ 生成内核的"深度导向搜索"——探针证明不需要

---

## 1. 影响面总览

| # | 面 | 文件 | 改动性质 |
|---|---|---|---|
| 1 | 判据定义 | `core/difficulty.gd` | 新增 `PEAK_WINDOWS` / `tier_of_peak` / `tier_of_profile` / `in_window` / `tier_range`；`filter_by_tier` 改按峰值 |
| 2 | 生成内核 | `core/puzzle_generator.gd:821-857` | **零改动**（`max_complexity` 已在算） |
| 3 | 量产工具 | `tools/batch_all_variants.gd` | 新增第 16 参窗口 + 验收分支 + 事件（`peak_miss`/`peak_hist`） |
| 4 | 存量重标 | 新建 `tools/retier_stock.py` | 52,988 关离线重标（零生成成本），扁平输出直接喂入库工具 |
| 5 | 入库 | `tools/import_batch_to_lib.gd` | 加窗口一致性校验 + 集内排序改按 peak |
| 6 | 玩家侧标签 | `ui/level_library.gd` / `ui/level_select.gd` | tile 数值 → 深度；档位说明文案 → 深度口径 |
| 7 | 提示预算 | `ui/hint_coordinator.gd` + `core/board.gd` | 按新档位给提示预算（深档更少） |
| 8 | **自举平台** | `ui/mod_select.gd:516-545` | 生成入口窗口验收 + 进度/预估 + 不可达提示 |
| 9 | 能力档案 | 新建 `tools/capability_probe.gd` + `ui/mod_select.gd` 卡片 | 探针产品化：每个 mod 的可达档位 |
| 10 | 作者文档 | `变体规则编写规范.md` | 新增"难度口径与异形盘例外"一节 |
| 11 | 测试 | `test/unit/test_peak_tier.gd`（新）等 | 窗口判据单测 + 回归 |

---

## 2. 任务分解

### Task 1: 窗口判据进 core（Difficulty）

**Files:**
- Modify: `core/difficulty.gd`（在 `TIERS` 之后追加，旧 `TIERS`/`tier_of` **保留**作"紧凑度画像"）
- Create: `test/unit/test_peak_tier.gd`

**Step 1: 写失败测试** `test/unit/test_peak_tier.gd`

```gdscript
extends GutTest

# 深度窗口判据（v4.0）：peak → 档位；超纲过滤。
func test_window_boundaries() -> void:
	assert_eq(Difficulty.tier_of_peak(0), "intro")
	assert_eq(Difficulty.tier_of_peak(2), "intro")
	assert_eq(Difficulty.tier_of_peak(3), "easy")
	assert_eq(Difficulty.tier_of_peak(4), "easy")
	assert_eq(Difficulty.tier_of_peak(5), "normal")
	assert_eq(Difficulty.tier_of_peak(8), "normal")
	assert_eq(Difficulty.tier_of_peak(9), "hard")
	assert_eq(Difficulty.tier_of_peak(20), "hard")
	assert_eq(Difficulty.tier_of_peak(21), "")      # 超纲
	assert_eq(Difficulty.tier_of_peak(-1), "")      # 无画像

func test_tier_of_profile() -> void:
	assert_eq(Difficulty.tier_of_profile({"max_complexity": 9}), "hard")
	assert_eq(Difficulty.tier_of_profile({"max_complexity": 3}), "easy")
	assert_eq(Difficulty.tier_of_profile({}), "")
	assert_eq(Difficulty.tier_of_profile({"difficulty": 3.0}), "")  # 只有标量不算

func test_window_predicate_and_range() -> void:
	assert_true(Difficulty.in_window(9, 9, 20))
	assert_false(Difficulty.in_window(8, 9, 20))
	assert_eq(Difficulty.tier_range("hard"), Vector2i(9, 20))
	assert_eq(Difficulty.tier_range("easy"), Vector2i(3, 4))

func test_filter_by_tier_uses_peak() -> void:
	var lv := [
		{"difficulty_profile": {"max_complexity": 1, "difficulty": 2.5}},  # 旧口径会判 hard
		{"difficulty_profile": {"max_complexity": 10, "difficulty": 0.2}}, # 旧口径会判 intro
	]
	assert_eq(Difficulty.filter_by_tier(lv, "hard").size(), 1)
	assert_eq(int(Difficulty.filter_by_tier(lv, "hard")[0]["difficulty_profile"]["max_complexity"]), 10)
```

**Step 2: 跑测试看失败**

```bash
godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir res://test/unit -gexit
```
Expected: FAIL（`tier_of_peak` 未定义）

**Step 3: 实现**（`core/difficulty.gd` 追加）

```gdscript
## 深度窗口（v4.0，2026-09-19）：以「峰值 = 单步最大必要线索数」定档。
## 依据：52,988 关实测——窗口占比 44.1/22.8/21.7/11.1%，峰值随尺寸单调增长、与长度近似独立。
## 为什么不用标量 difficulty 定档：它与「步数」秩相关 0.923、与峰值仅 0.475（测长度而非深度）。
const PEAK_WINDOWS := {
	"intro":  {"label": "入门", "min": 0,  "max": 2},
	"easy":   {"label": "普通", "min": 3,  "max": 4},
	"normal": {"label": "困难", "min": 5,  "max": 8},
	"hard":   {"label": "噩梦", "min": 9,  "max": 20},
}
const PEAK_OVER := 21  ## ≥ 此值 =「超纲」（机器级），不进任何档


## 峰值 → 档位；超纲/无画像返回 ""。
static func tier_of_peak(peak: int) -> String:
	if peak < 0 or peak >= PEAK_OVER:
		return ""
	for id in PEAK_WINDOWS:
		var w: Dictionary = PEAK_WINDOWS[id]
		if peak >= int(w["min"]) and peak <= int(w["max"]):
			return id
	return ""


## 读 difficulty_profile 定档（无 max_complexity → ""）。
static func tier_of_profile(dp: Dictionary) -> String:
	if dp.is_empty() or not dp.has("max_complexity"):
		return ""
	return tier_of_peak(int(dp.get("max_complexity", -1)))


## 窗口谓词（量产 / 自举平台的验收判据）：闭区间 [lo, hi]。
static func in_window(peak: int, lo: int, hi: int) -> bool:
	return peak >= lo and peak <= hi


## 档位 → 窗口 [min, max]（Vector2i）。
static func tier_range(tier: String) -> Vector2i:
	var w: Dictionary = PEAK_WINDOWS.get(tier, {})
	if w.is_empty():
		return Vector2i(-1, -1)
	return Vector2i(int(w["min"]), int(w["max"]))
```

并把 `filter_by_tier` 的判定改为：

```gdscript
	for lv in levels:
		var dp: Dictionary = lv.get("difficulty_profile", {})
		if Difficulty.tier_of_profile(dp) == tier:
			out.append(lv)
```

**Step 4: 跑测试看通过**（同 Step 2 命令，目录级）→ Expected: PASS 4/4

> 必须目录级回归：只跑新文件会掩盖对既有测试的破坏（真实教训：test_difficulty_tiers 的 fixture 当时没有 max_complexity）。

**Step 5: 提交**

```bash
git add core/difficulty.gd test/unit/test_peak_tier.gd
git commit -m "feat(difficulty): v4 深度窗口判据（peak 定档）+ 单测"
```

---

### Task 2: 量产工具加窗口参数（验收改口径）

**Files:**
- Modify: `tools/batch_all_variants.gd`（`_initialize` 参数解析 + 生成循环验收段 + `unit_done` 事件）

**Step 1: 加参数（第 16 参）**

```gdscript
var _peak_window := Vector2i(-1, -1)  # 第 16 参：peak 窗口 "lo-hi"（如 "9-20"）；缺省 -1 = 不限（旧行为）
```

在 `_initialize` 现有第 15 参之后追加：

```gdscript
	# 第 16 参：峰值窗口（v4.0 深度口径）——"lo-hi" 闭区间；缺省/空 = 不限（保持旧行为）。
	# 用法示例：第 16 参（位置参数）传 `9-20`（只收噩梦）、`0-20`（全档，按窗口自动分档计数）。
	if args.size() >= 16 and str(args[15]) != "":
		var pw := str(args[15]).split("-", false, 1)
		# 格式与范围必须启动即校验：这类配置错误在本工作流已真实发生（PowerShell 丢空串导致参数错位），
		# 静默失效会让长跑白费机时或把脏数据写进量产目录。宁可在启动时失败。
		if pw.size() != 2 or not pw[0].is_valid_int() or not pw[1].is_valid_int():
			push_error("[量产] 第 16 参窗口格式非法: %r（应为 lo-hi，如 9-20；空缺位请填 off / -1）" % str(args[15]))
			CliShutdown.request_exit(1)
			return
		var p_lo := int(pw[0])
		var p_hi := int(pw[1])
		if p_lo < 0 or p_hi < p_lo or p_hi >= Difficulty.PEAK_OVER:
			push_error("[量产] 第 16 参窗口范围非法: %d-%d（需 0 <= lo <= hi <= %d；>=%d 为超纲档不进库）" % [
				p_lo, p_hi, Difficulty.PEAK_OVER - 1, Difficulty.PEAK_OVER])
			CliShutdown.request_exit(1)
			return
		_peak_window = Vector2i(p_lo, p_hi)
```

**Step 2: 循环内改验收**（在 `var diff := float(dp.get("difficulty", 0.0))` 之前插入窗口判定，并把 `tier` 的来源改为窗口）

```gdscript
				var dp: Dictionary = level.get("difficulty_profile", {})
				var diff := float(dp.get("difficulty", 0.0))
				var mc: Variant = dp.get("max_complexity")
				var peak := int(mc) if mc != null else -1
				# 全候选峰值分布（窗口内外都记）——命中率 = 窗口内 / 本直方图总数
				peak_hist[peak] = int(peak_hist.get(peak, 0)) + 1
				# v4.0 窗口验收：peak 不在窗口 → 拒收（记 peak_miss，供能力档案累积）
				if _peak_window.x >= 0 and not Difficulty.in_window(peak, _peak_window.x, _peak_window.y):
					u_peak_miss += 1
					unit_lines.append(_ev({"t": "peak_miss", "combo": combo["id"], "side": side,
						"seed": seed, "peak": peak, "cost_s": cost_ms / 1000.0}))
					continue
				var tier := Difficulty.tier_of_peak(peak) if _peak_window.x >= 0 else Difficulty.tier_of(diff)
```

单元级计数需新增（放在 `var u_sim := 0` 附近）：

```gdscript
			var u_peak_miss := 0
			var peak_hist: Dictionary = {}
```

`unit_done` 事件追加字段（便于离线累积能力档案 + 口径自证）：

```gdscript
				"peak_miss": u_peak_miss, "peak_hist": peak_hist,
				"peak_window": ("off" if _peak_window.x < 0 else "%d-%d" % [_peak_window.x, _peak_window.y]),
```

**Step 3: 关掉与窗口冲突的标量定向**（窗口模式下标量 target 无意义；探针已证对峰值无效）

```gdscript
				var t_target := _target_difficulty
				if _tiered_target and t_target <= 0.0 and _peak_window.x < 0:
					t_target = _next_tier_target(made_by_tier)
```

**Step 4: 冒烟（本地，100 关噩梦窗口；预期命中率 ~50%）**

```bash
# 注意参数位：... <per_tier> <timeout_coef> <tiered> <stall_max> <k_public> <peak窗口>
# ⚠️ 坑：PowerShell 会**丢弃空字符串参数**（""），导致后续参数整体错位、窗口静默失效（实测踩过）。
#    空缺位置请显式填占位值：tiered 填 off、k_public 填 -1。
godot --headless --path . -s res://tools/batch_all_variants.gd -- \
  user://probe_w4 100 400 -1 1 1 1 0 "o4@8" o4_bianjing 100 3000 off 60 -1 "9-20"
```
Expected: 产出 `hard_XX.json` 100 关，**每关 peak ∈ [9,20]**；`issues.jsonl` 的 `unit_done` 行含 `peak_miss/peak_hist/peak_window`；按探针 56% 命中率，tried ≈ 180；窗口模式下 `per_tier` 收满后**按窗口覆盖档收工**（`_window_tiers_full`：窗口覆盖到的各档全部收满才停——跨档窗口如 8-20 需两档都满），不再依赖 `stall_max`。

> 实测参考（s1@8、窗口 9-20、per_tier=3）：命中率 **7/60 ≈ 11.7%**（与探针 10% 同量级）、单候选 ≈ **13 s**、`by_tier` 仅 hard ✓。
> 另注①：窗口模式下若 `per_type` 大于 `per_tier`，报告会把该单元计入"部分成功"（只产了 per_tier 关）——属预期，不是缺陷。
> 另注②（口径干净）：窗口模式要求输出目录口径干净——含旧口径文件（峰值不在窗口内）会拒绝续跑（防继承错误档位计数导致 made=0 的静默零产出）。

**Step 5: 提交**

```bash
git add tools/batch_all_variants.gd
git commit -m "feat(batch): 量产工具加峰值窗口验收（第 16 参），验收与档位计数切到深度口径"
```

---

### Task 3: 存量重标工具（零生成成本）

**Files:**
- Create: `tools/retier_stock.py`
- Test: 用现有 `_staged_levels/harvest_*` 跑一遍，核对计数与 `difficulty_supply_matrix.sh` 一致

**Step 1: 写脚本**（关键片段）

```python
"""retier_stock.py —— 存量关卡按深度窗口重标（不改内容，只重排档位目录）

为什么需要：52,988 关是按旧口径（标量难度）分档的产物，其中大量高峰值盘被判进低档
（实测 deep-intro 365 关、easy 里 1,450 关）。重标是零生成成本的现货供给。

输出（扁平结构，直接喂 tools/import_batch_to_lib.gd）：
  <out>/<原目录名>/<side>/<tier>_<idx>.json      ← 重标后的档位
  <out_over>/                                              ← 超纲（peak>=21）
  <out_unknown>/                                           ← 无 max_complexity
  <out>/retier_report.json                                 ← 计数 + 峰值直方图
"""
WINDOWS = {"intro": (0, 2), "easy": (3, 4), "normal": (5, 8), "hard": (9, 20)}

def tier_of(peak):
    for t, (lo, hi) in WINDOWS.items():
        if lo <= peak <= hi:
            return t
    return ""      # 超纲或缺失
```

逐目录遍历 → 读 `difficulty_profile.max_complexity` → 归属档位 → `json.dump` 到目标路径（文件名 `tier_序号.json`，序号按 peak 升序编号）→ 计数。

**Step 2: 跑（本地）**

```bash
python tools/retier_stock.py --src _staged_levels/harvest_0917 --out _staged_levels/retiered
```
Expected: 报告里 `hard`（噩梦）计数与该目录的峰值 ≥9 数一致（可对照 `difficulty_supply_matrix.sh` 输出）。

**Step 3: 提交**

```bash
git add tools/retier_stock.py
git commit -m "feat(tools): 存量关卡按深度窗口重标（零生成成本，扁平输出直喂入库）"
```

---

### Task 4: 入库加窗口一致性校验 + 按深度排序

**Files:**
- Modify: `tools/import_batch_to_lib.gd`（`_scan_source` 加校验；`_write_sets` 改排序；`_report` 加计数）

**Step 1: 校验**（`_put` 之前）

```gdscript
## v4.0 窗口一致性：集内档位必须与实测峰值一致（防错档入库）。
## 例外：旧口径关卡（--no-window-check 或集名含 _legacy）跳过校验。
func _window_ok(lv: Dictionary, tier: String) -> bool:
	if _no_window_check:
		return true
	var peak := int((lv.get("difficulty_profile", {}) as Dictionary).get("max_complexity", -1))
	return Difficulty.tier_of_peak(peak) == tier
```

不通过 → `_skipped_mismatch += 1` 并 `continue`（报告里打印前 8 条）。

**Step 2: 排序**（`_write_sets` 内）

```gdscript
				arr.sort_custom(func(a, b):
					var pa := int(((a as Dictionary).get("difficulty_profile", {}) as Dictionary).get("max_complexity", 0))
					var pb := int(((b as Dictionary).get("difficulty_profile", {}) as Dictionary).get("max_complexity", 0))
					if pa != pb:
						return pa < pb          # 同档内：深度由浅到深
					return int((a as Dictionary).get("difficulty_profile", {}).get("rounds", 0)) \
						< int((b as Dictionary).get("difficulty_profile", {}).get("rounds", 0)))
```

**Step 3: 提交**

```bash
git add tools/import_batch_to_lib.gd
git commit -m "feat(import): 档位窗口一致性校验 + 集内按深度排序"
```

---

### Task 5: 玩家侧标签改深度口径

**Files:**
- Modify: `ui/level_library.gd`（`level_label` / 新增 `level_peak`）
- Modify: `ui/level_select.gd`（档位说明文案 4 处）

**Step 1: tile 数值显示深度**（`ui/level_library.gd`）

```gdscript
## 某关峰值深度（读不到 → -1）。
static func level_peak(mode: String, size: int, tier: String, idx: int) -> int:
	var lv := get_level(mode, size, tier, idx)
	if lv.is_empty():
		return -1
	return int((lv.get("difficulty_profile", {}) as Dictionary).get("max_complexity", -1))


## 关卡短标签（tile 用）：序号 + 深度（玩家一眼看出要同时把握几条线索）。
static func level_label(mode: String, size: int, tier: String, idx: int) -> String:
	var peak := level_peak(mode, size, tier, idx)
	if peak < 0:
		return str(idx + 1)
	return "%d\n深度%d" % [idx + 1, peak]
```

**Step 2: 档位说明文案**（`ui/level_select.gd`：档位按钮/描述处）

```gdscript
const TIER_HINT := {
	"intro": "≤2 条线索", "easy": "3–4 条", "normal": "5–8 条", "hard": "9+ 条",
}
```

在档位标签处附提示（如 `"噩梦（9+ 条线索）"`），玩家能理解"深度"含义。

**Step 3: 提交** `git commit -m "feat(ui): 档位标签与 tile 数值切深度口径（含档位说明）"`

---

### Task 6: 提示预算按新档位

**Files:**
- Modify: `core/board.gd`（新增 `peak` / `tier` 字段）
- Modify: `ui/hint_coordinator.gd:95-104`

**Step 1: Board 带上深度与档位**

```gdscript
## 深度画像（v4.0）：peak = 单步最大必要线索数；tier = 由 peak 定的档位。
var peak := -1
var tier := ""
```
在读取 `difficulty_profile` 处：

```gdscript
	var dp: Dictionary = level.get("difficulty_profile", {})
	peak = int(dp.get("max_complexity", -1))
	tier = Difficulty.tier_of_profile(dp)
```

**Step 2: 提示预算改按深度档（深档给得更少）**

```gdscript
## 一次提示给出的结论格上限：噩梦 3 / 困难 5 / 普通·入门不限（-1）。
## 依据：档位已切深度口径（峰值深 = 推理链宽），深档应"只给一个推理阶段"。
func _hint_budget_cap(board: Board) -> int:
	if board == null:
		return -1
	match board.tier:
		"hard":
			return 3
		"normal":
			return 5
		_:
			return -1
```

**Step 3: 提交** `git commit -m "feat(hint): 提示预算按深度档（噩梦 3 / 困难 5 / 其余不限）"`

---

### Task 7: 自举平台生成入口（**关键**）

**Files:**
- Modify: `ui/mod_select.gd::_generate_rule_levels`（516-545）

**Step 1: 目标档参数 + 窗口验收 + 不可达提示**

```gdscript
## 用自举式规则平台为指定规则生成关卡（v4.0：按深度档窗口验收）。
## · 窗口命中率实测 10%~56% → 尝试上限从 40 提到 200，并给进度；
## · 连续 60 次不进窗口 → 判定"该规则/尺寸下不可达"，如实告知并建议换尺寸（不空转到超时）。
func _generate_rule_levels(rule_id: String, tier_id: String = "easy") -> void:
	_open_gen_dialog("正在为规则 %s 生成「%s」关卡…" % [rule_id, str(Difficulty.PEAK_WINDOWS.get(tier_id, {}).get("label", tier_id))])
	var gen := PuzzleGenerator.new()
	var w := Difficulty.tier_range(tier_id)
	var out_dir := "user://mods/_custom/levels"
	DirAccess.make_dir_recursive_absolute(out_dir)
	var owner := ModAPI.find_rule_owner(rule_id)      # （保留原双参数兼容：find_rule_owner 单参不改）
	var board_info := _mod_board(owner)
	var topo: GridInterface = board_info["topo"]
	var size: Vector2i = board_info["size"]
	var mine_count := int(topo.cell_count() * 0.2) if topo != null else 5
	var produced := 0
	var tried := 0
	var misses := 0
	for t in 200:
		await get_tree().process_frame
		if _gen_cancel or produced >= 5:
			break
		tried += 1
		var level := gen.generate_with_rules(rule_id, [], size, mine_count, t + 1, 0, 50, topo)
		if level.is_empty():
			continue
		var peak := int((level.get("difficulty_profile", {}) as Dictionary).get("max_complexity", -1))
		if not Difficulty.in_window(peak, w.x, w.y):
			misses += 1
			if misses == 60:
				_close_gen_dialog()
				_toast("该规则在 %d×%d 下达不到「%s」档（已试 60 次）——建议换更大尺寸或改目标档" % [
					size.x, size.y, str(Difficulty.PEAK_WINDOWS.get(tier_id, {}).get("label", tier_id))], true)
				_gen_cancel = false
				return
			continue
		# …原落盘逻辑不变（写 name + 落盘 + produced += 1）
	_close_gen_dialog()
	_gen_cancel = false
	_toast("已为规则 %s 生成 %d 关（深度 %d–%d，尝试 %d 次）" % [rule_id, produced, w.x, w.y, tried], produced == 0)
```

**Step 2: 卡片加档位下拉**（规则行加 `OptionButton`：入门/普通/困难/噩梦 → 调 `_generate_rule_levels(rule_id, tier_id)`）

**Step 3: 手工验证**（本地跑游戏，用一个 mod 规则生成 5 关噩梦；观察进度与落盘 `peak`）
Expected: 落盘关卡的 `difficulty_profile.max_complexity` ∈ [9,20]；若该规则不可达 → 60 次后弹提示（不卡死）。

**Step 4: 提交** `git commit -m "feat(platform): 自举生成入口按深度窗口验收（含进度与不可达提示）"`

---

### Task 8: 能力档案（探针产品化）+ 作者文档

**Files:**
- Create: `tools/capability_probe.gd`（由 `tools/probe_peak_window.gd` 泛化：多尺寸循环 + 落盘）
- Modify: `ui/mod_select.gd`（卡片"探测能力"按钮 + 显示可达档位）
- Modify: `变体规则编写规范.md`（新增一节）

**Step 1: 探针工具**（复用 `probe_peak_window.gd` 主体，循环尺寸并落盘）

```gdscript
# capability_probe.gd —— 变体能力档案：某规则在各尺寸能供哪些深度档
# 用法：godot --headless --path . -s res://tools/capability_probe.gd -- \
#         <clue> <globals_csv|-> <sides_csv> <cand_per_side> <mods>
# 落盘：user://mods/_custom/capability/<clue>_<globals>.json
#   { "sides": { "8": {"cand": 40, "peak_hist": {...}, "reachable": ["intro","easy","normal","hard"],
#                       "hit_rate": {...}, "cost_ms_mean": 6600} } }
```

**Step 2: UI 显示**（卡片上"探测"按钮 → 后台跑 → 显示"可达：入门/普通/困难／不可达：噩梦（建议 9×9）"）

**Step 3: 作者文档加一节**（`变体规则编写规范.md`）

```markdown
## 难度口径（v4.0，2026-09-19）

难度 = **推理深度**（`peak` = 单步最大必要线索数），四档窗口：
入门 ≤2 ｜ 普通 3–4 ｜ 困难 5–8 ｜ 噩梦 9–20 ｜ ≥21 为超纲（不进库）。

**mod 作者不需要做任何事**：判据由求解器在你已实现的 `compute_clue` / `build_clue_constraints`
之上自动算出。你不必声明权重、成本或难度参数。

**异形棋盘（board.json 拓扑）**：绝对窗口按 5×5–9×9 矩形标定；异形盘以
**等效边长 = round(√格子数)** 近似查窗口，平台的能力探测结果可作校正依据。
若某档在多次尝试后不可达，平台会如实提示（不硬造档位）。
```

**Step 4: 提交** `git commit -m "feat(platform): 变体能力档案（探针产品化）+ 作者文档补难度口径"`

---

### Task 4b: 跨工具档位口径统一（复审 Minor5）

**Files:**
- Modify: `tools/verify_batch.gd`（约 L98-110：尺寸×档分组 / `tier` 收集）
- Modify: `tools/mod_selfcheck.gd`（约 L79-80）
- Modify: `tools/batch_generate.gd`（约 L90-91：落盘分组/命名）

三处仍按**标量 `difficulty`** 定档（`Difficulty.tier_of(d)`，长度语义，与步数秩相关 0.923）；v4.0 起档位口径是**峰值深度**，须与量产工具（窗口模式下文件名档位按 `tier_of_peak`）对齐——否则同一批关卡在不同报表/分组里归属不同档。（`tier_of` 本身保留作紧凑度画像/回退，不在本任务删除。）

**Step 1: 三处统一改按 `Difficulty.tier_of_profile(dp)`**（null/无画像 → `""`，计入未分档）

```gdscript
# 旧：var tier := Difficulty.tier_of(float(dp.get("difficulty", -1.0)))
# 新：var tier := Difficulty.tier_of_profile(dp)     # dp = level.get("difficulty_profile", {})
# batch_generate 中该 tier 还决定落盘文件名与每档配额计数，改后两处口径一致
```

**Step 2: 顶层 `difficulty` 字段仅作画像（勿用于分组）**

`tools/batch_all_variants.gd` 的 `level["difficulty"] = diff`（原 L732；本批改动后为 L783）写入的顶层 `difficulty` 字段仅作**紧凑度画像**——长度语义，不是档位判据；报表/校验分组需按 `difficulty_profile.max_complexity`（峰值）另算。

**Step 3: 提交** `git commit -m "chore(tools): 档位分组口径统一到峰值（复审 Minor5）"`

---

### Task 9: 回归 + 首批正式产出

**Step 1: GUT 全量回归**

```bash
pwsh tools/verify_all.ps1
```
Expected: 全绿（重点：`test_difficulty*` / `test_no_guess` / `test_mod_generation` / `test_ui_gen_budget`）

**Step 2: 存量重标 → 入库（现货，零生成）**

```bash
python tools/retier_stock.py --src _staged_levels/harvest_0917 --out _staged_levels/retiered
godot --headless --path . -s tools/import_batch_to_lib.gd -- _staged_levels/retiered --overwrite --min=10
```
Expected: 选关页出现按深度分档的集（含首批 `hard` 噩梦，峰值 ≥9 现货 5,881 关规模）

**Step 3: 服务器按窗口补产（首批：深变体噩梦）**

```bash
# 服务器（/root/minesweeper），与现有补产链参数同构，仅追加第 16 参窗口
Godot -s res://tools/batch_all_variants.gd -- \
  user://batch_w4_o4 100 1200 -1 1 1 0 0 "o4@5-9" o4_bianjing 100 3000 "" 60 "" "9-20"
```
Expected: 每单元 100 关噩梦；`unit_done.peak_miss/peak_hist` 与探针命中率同量级

**Step 4: 提交与推送**

```bash
git add -A && git commit -m "chore(difficulty): v1 首批产出与入库（存量重标 + 窗口补产）"
git push origin main
```

---

## 2.9 执行状态与验收记录（2026-09-19 执行完毕）

| 任务 | 状态 | 提交 | 证据 |
|---|---|---|---|
| 1 窗口判据进 core | ✅ | `f9caa13` + `01564a4` | 单测 4+3 项全绿；复审修复：既有 fixture 补 `max_complexity`、`PEAK_WINDOWS↔TIERS` parity 守卫、null 防御 |
| 2 量产窗口参数 | ✅ | `348b477` | s1@8 窗口 9-20：命中 7/60≈11.7%、产出 peak=9/10/9 全在窗口内、`by_tier` 仅 hard；坏格式 exit=1；`-1` 回显"不限"；续跑 0.1s 跳过 |
| 2 复审 I1–I4 加固 | ✅ | 同上 | 解析期校验 + 启动回显；`_window_tiers_full` 收工；`_unit_full` 窗口分支；脏目录拒跑；null 对齐 |
| 3 存量重标 | ✅ | `8e156ef` | 8 目录 15,035 关 → 主输出 14,973（over 35 / bad 27）；四档 min/max 恰等于窗口；独立抽验 397 关零越界 |
| 4 入库校验 | ✅ | `46f6f20` | 正例不匹配 0；反例（peak=3 命名 hard_01）被拦并给明细；`--no-window-check` 放行 |
| 4b 跨工具口径统一 | ✅ | 同上 | verify_batch / mod_selfcheck / batch_generate 改峰值优先 + 无峰值回退标量 |
| 5 UI 标签 | ✅ | `a24bdbb` | tile 显示"深度N"；`Difficulty.tier_text` 成为唯一档位文案源（main_menu 也统一） |
| 6 提示预算 | ✅ | 同上 | 噩梦 3 / 困难 5 / 普通·入门不限；无画像回退标量 |
| 7 自举平台生成入口 | ✅ | `6cbe96a` | 窗口验收 + 进度 + 连续 60 次窗口外止损 + 档案兜底提示 |
| 8 能力档案 + 作者文档 | ✅ | 同上 | CLI 实跑 classic+z1@5×5：6 候选 1.1s、可达 入门/普通、档案结构正确；作者文档补「难度口径 v4.0」 |
| 9-1 全量回归 | ✅ | — | `verify_all.ps1`：dotnet OK / unit 512 全过 / ui 126 全过 / integration 16 过 +1 risky → **ALL GREEN** |
| 9-2 存量重标入库（首批） | ✅ | `544cc45` | 112 集 / 8,978 关入库（坏关 0、不匹配 0）——但**只覆盖新集**，旧集仍带旧口径档名（见 9-4） |
| 9-3 服务器窗口补产 | ⏸ **延迟**（有据） | — | 服务器 2 核**满载**（load 2.52，两条链各 98% CPU、1天5小时/14小时）→ 不插队。已交付一键启动器 `tools/run_window_production.sh`（含参数位与运维注意），待现有链结束后执行 |
| 9-4 **最终复审缺口闭环（G1–G8）** | ✅ | `03ae6a9` | 复审抓出"库内 1,387 关错档"（76 关真噩梦藏在浅档、35 关浅盘挂在噩梦档）→ 库内重标收口：**9,138 关 / mismatch 0 / hidden_deep 0 / shallow_in_hard 0**，清理 24 个残留集；G2 守卫测试改峰值口径（此前红）；G3 窗口外结构性止损；G4 自举落盘命名带档位；G5 ops 报表口径；G6 静默跳过可见化；G7 catalog schema=4；G8 文案"难度→紧凑度"。**verify_all ALL GREEN（收口后可复现）** |

> **库最终态（9-4 后）**：10 席 / 144 集 / **9,138 关**，档位与峰值 100% 一致（独立扫描复核）；档位分布按实测峰值统计。
> **注意**：`544cc45` 里的 catalog 计数（10,409）是重标收口前的中间态，已被 `03ae6a9` 取代。

### 遗留与后续

| 项 | 说明 | 建议 |
|---|---|---|
| 薄集 118 个（<100 关） | 首批迁移只覆盖本地 harvest 来源（o1–o10 家族）；classic/dt/z*/s* 席仍稀疏 | 用 `run_window_production.sh` 按窗口补产填满；classic 席需专门来源 |
| 服务器补产 | 见 9-3 | 链结束后跑 `bash tools/run_window_production.sh o4_nm "9-20" "o4@5-9" user://batch_w4_o4 100 1200 o4_bianjing` |
| `batch_generate.gd` 的 `_stats["tiers"]` 缺 `intro` 键 | 既有缺口（本次未扩大范围） | 顺手补上并加断言 |
| 首轮新脚本加载失败 | 新 `class_name` 需一次导入注册才可见 | 无需处理；CI 里跑一次 `--headless --path . --quit` 预热即可 |

---

## 3. 风险与回滚

| 风险 | 缓解 | 回滚 |
|---|---|---|
| 新旧档位并存导致语义混乱 | `catalog.json` 加 `schema: 4`；旧集保留不删 | 恢复旧 `tier_of` 路径（core 未删） |
| 存量重标误伤（无 profile/超纲） | 分到 `_unknown/`、`_over/`，不入库 | 源文件不动，重跑即可 |
| 中浅变体噩梦供给不足 | 探针已定量（s1 10% / z1 8×8 不可达）→ UI 如实声明；不足档由大盘面补 | 降档交付 |
| 用户侧生成等待过长 | 进度 + 60 次不可达提前退出 + 建议尺寸 | 保持旧"生成成功即收"开关（`tier_id=""` 走旧路径） |
| 提示预算语义变化影响老玩家 | 文案说明"深档少给提示" | 单点函数，易回退 |

---

## 4. 验收清单（可脚本化）

| # | 验收项 | 判据 |
|---|---|---|
| 1 | 窗口判据 | `test_peak_tier.gd` 全绿；`tier_of_peak(21)==""` |
| 2 | 量产窗口验收 | 冒烟批次内**每一关** `tier_of_peak(peak) == 目标档`（脚本校验 100%） |
| 3 | 存量重标 | 重标报表 total == 源 total − 超纲 − 无画像 |
| 4 | 入库校验 | `import` 报告 `mismatch == 0` |
| 5 | 跨变体可比 | 同一档在任意变体的窗口相同（绝对口径） |
| 6 | 可解释 | 每关可输出峰值/步数/档位（选关页 tile 可见） |
| 7 | 退化变体 | o8/o9 不出现 `hard` 集；平台提示文案存在 |
| 8 | 自举平台 | 新 mod 无参数即可按档生成；不可达有提示（60 次退出） |
| 9 | 回归 | `pwsh tools/verify_all.ps1` 全绿 |

---

## 5. 机时预算（据探针实测）

| 项 | 量 | 机时 |
|---|---|---|
| 存量重标（52,988 关） | 一次性 | < 5 分钟（纯 IO） |
| 单单元 100 关噩梦（深变体 o4） | 0.8 h | — |
| 单单元 100 关噩梦（中部 s1） | 1.8 h | — |
| 全矩阵噩梦（110 单元 × 100 关） | ≈ 165 h | 2 核并行 ≈ **3.5 天** |
| 入门/正常/困难 | 近似免费（分布主体） | — |

> 现有 52,988 关重标可**立即**供给：入门 23,348 / 正常 12,087 / 困难 11,520 / **噩梦 5,881** / 超纲 152。
