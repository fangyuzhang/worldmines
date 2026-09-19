extends SceneTree

# import_batch_to_lib.gd —— 把量产产物归档进正式关卡库（`levels_lib/`）。
#
# 为什么需要它：量产工具（tools/batch_all_variants.gd）产出一关一文件到
# `user://batch_all/<mode>/<size>/<tier>_<idx>.json`，而游戏只从
# `res://levels_lib/<mode>/<size>/<tier>.json`（一集一文件 + catalog.json 索引）读。
# **此前这条转换通道完全不存在** —— 服务器辛苦跑出来的关卡变不成游戏内容
#（见 UI待办 B2 #4）。本工具就是那座桥。
#
# 用法：
#   godot --headless --path . -s tools/import_batch_to_lib.gd -- [src] [flags]
#   · src        源目录，默认 user://batch_all
#   · --dry-run  只报告不写盘（先跑这个看看会导入什么）
#   · --overwrite  覆盖已存在的 (mode,size,tier) 集；默认**只补缺**，不动已有的
#   · --min=10   集内关卡数下限（低于此不建集，防半成品入库），默认 1
#   · --no-window-check  跳过「集内档位 vs 实测峰值」一致性校验（仅用于导入旧口径关卡）
#   · --allow-prewon    放行「开局即胜」死盘（revealed 覆盖全部非雷格 → 加载即判 WON；默认拒收，
#                       这类盘玩家看到的是「全开却无结算」的死盘——真实用户 bug）
#   · --prune    清掉「本轮未产出」的残留集：只删 levels_lib/<mode>/<size>/ 下的四档名 json
#                （不删目录、不删 catalog）；库内重标（retier_stock.py）后用它清错档残留。
#                建议**只与 --overwrite 同时用**：单独用时「已存在被跳过」的集会被误判为未产出。
#
# **mode 口径（最关键，2026-09-19 修正）**：以**关卡 JSON 字段**为产物侧真相
#   （`clue_rule` + `global_rules`），推导库内 mode id（= 选关页 MODES[].id）：
#     单算子 = o1/s1/z1；C 类 = 结构_观测（s1_o1）；F 类 = 结构_结构（s1_s2）；
#     T4 = 守恒+结构+观测（z1+s1+o1）；内置 = classic / dt。
#   **不依赖目录命名**（与《关卡集供给对账》同口径）。历史形态全部自动兼容：
#     量产链（额外组合路径）`x_classic_s1` / `x_o10`；内置路径 `o1` / `s1_o1`；
#     旧批次 `c_o1` / `g_s1`。按目录名判会整批拒掉服务器 15 批产物（实测 14/14 被拒）。
#
# 安全设计：
#   · catalog.json **全量重建**（扫盘上全部 levels_lib，而非只记本次导入）——
#     否则会抹掉已有的 8 席 9117 关；
#   · 集内按 seed 去重（重复导入同一批不会产生重复关卡）；
#   · 关卡落到集里前做**必需字段**校验，坏关卡跳过并计数（不静默丢）；
#   · 按 difficulty 升序排列（与库既有集一致，选关页按序推进）。
#
# 产物：res://levels_lib/<mode>/<size>/<tier>.json + res://levels_lib/catalog.json
const CliShutdown := preload("res://tools/cli_shutdown.gd")

const LIB_DIR := "res://levels_lib"
const CATALOG_PATH := LIB_DIR + "/catalog.json"
const TIERS: Array = ["intro", "easy", "normal", "hard"]
## 关卡必需字段（缺任何一个都判坏关：Board.load_level 需要它们，缺了会加载出空盘）。
const REQUIRED_FIELDS: Array = ["mines", "revealed", "size", "total_mines"]

var _src := "user://batch_all"
var _dry := false
var _overwrite := false
var _min_levels := 1
var _no_window_check := false      # --no-window-check：跳过窗口一致性校验（仅导入旧口径关卡用）
var _allow_prewon := false         # --allow-prewon：放行「开局即胜」死盘（默认关闭，见 _prewon_ok）
var _prune := false                # --prune：清「本轮未产出」残留集（库内重标后清错档残留）

## mode -> size -> tier -> Array[level]
var _bag: Dictionary = {}
var _skipped_bad := 0
var _skipped_dup := 0
var _skipped_mismatch := 0         # v4.0 窗口一致性：集内档位 ≠ 实测峰值（防错档入库）
var _mismatch: Array = []          # 不匹配明细（报告列前 8 条）
var _skipped_prewon := 0           # v4.0 开局即胜门禁：revealed 覆盖全部非雷格 → 拒收（死盘）
var _prewon: Array = []            # 拒收明细（报告列前 8 条，含集名）
var _units_seen := 0
var _accepted := 0                  # 已收入 _bag 的关数（目录级进度打印用）
var _skipped_non_official := 0      # 关卡 JSON 推导出非官方组合 → 跳过的关数
var _non_official: Array = []       # 非官方组合的来源目录（去重，报告用）
var _bad_sizes: Array = []      # 尺寸目录名不认识的（如旧批次 `55`），整目录跳过
var _skipped_thin := 0           # 集内关卡数 < _min_levels 被跳过的集数（G6：不静默）
var _skipped_badname := 0        # 档名不符合 <tier>_<N> 的 json 数（G6：不静默）
var _badname_warned := 0         # 上述已 push_warning 的条数（前 5 条告警，防刷屏）


func _initialize() -> void:
	# 导出后 res:// 只读（架构审计 P0）：本工具全程写 res://levels_lib（它是唯一入库工具），
	# 在 pck 运行时里会静默失败。直接在启动时拒绝，避免「跑完了但什么都没写进去」。
	if OS.has_feature("template"):
		push_error("[import] 当前运行在导出后的运行时里：res:// 只读，无法入库。请在开发机（编辑器 / headless 工具）运行本工具。")
		CliShutdown.request_exit(1)
		return
	var args := OS.get_cmdline_user_args()
	for a in args:
		var s := str(a)
		if s == "--dry-run":
			_dry = true
		elif s == "--overwrite":
			_overwrite = true
		elif s.begins_with("--min="):
			_min_levels = maxi(1, int(s.substr(6)))
		elif s == "--no-window-check":
			_no_window_check = true
		elif s == "--allow-prewon":
			_allow_prewon = true
		elif s == "--prune":
			_prune = true
		elif not s.begins_with("--"):
			_src = s

	print("[import] 源目录: %s%s" % [_src, "（dry-run，不写盘）" if _dry else ""])
	_scan_source()
	var imported := _write_sets()
	_prune_sets(imported)     # G1b：清残留（仅 --prune 生效）；放在 catalog 重建前，索引不含已删集
	_rebuild_catalog()
	_report(imported)
	CliShutdown.request_exit(0)


## 扫描 `src/<combo>/<size>/<tier>_<idx>.json`，收进 _bag。
## 目录名**只用于遍历**——mode 由关卡 JSON 推导（见 `_mode_from_level`），
## 因此 `x_classic_s1`（量产链）/ `o1`（内置路径）/ `c_o1`（旧批次）都能正确入库。
func _scan_source() -> void:
	var root := DirAccess.open(_src)
	if root == null:
		push_error("[import] 源目录打不开: %s" % _src)
		return
	for combo_name in root.get_directories():
		var combo_dir := "%s/%s" % [_src, combo_name]
		var cd := DirAccess.open(combo_dir)
		if cd == null:
			continue
		var accepted_before := _accepted
		for size_dir in cd.get_directories():
			var side := _parse_side(str(size_dir))
			if side <= 0:
				_bad_sizes.append("%s/%s" % [combo_name, size_dir])
				continue
			_scan_size(combo_dir, size_dir, side)
		if _accepted > accepted_before:
			print("[import]   %-20s → 收 %d 关" % [combo_name, _accepted - accepted_before])


func _scan_size(combo_dir: String, size_dir: String, side: int) -> void:
	var list_dir := "%s/%s" % [combo_dir, size_dir]
	var d := DirAccess.open(list_dir)
	if d == null:
		return
	for fname in d.get_files():
		var fn := str(fname)
		if not fn.ends_with(".json"):
			continue
		var base := fn.get_basename()          # easy_01
		var parts := base.split("_", false)
		# 档名必须符合 `<tier>_<N>`（G6）：不匹配的 json 计数 + 前 5 条 push_warning，
		# 不再静默跳过——目录里混进 report/临时文件时，此前完全无声，量产「少产」查无实据。
		if parts.size() != 2 or not TIERS.has(str(parts[0])) or not str(parts[1]).is_valid_int():
			_skipped_badname += 1
			if _badname_warned < 5:
				_badname_warned += 1
				push_warning("[import] 档名不符合 <tier>_<N>，跳过: %s/%s" % [list_dir, fn])
			continue
		var tier := str(parts[0])
		_units_seen += 1
		var lv := _read_level("%s/%s" % [list_dir, fn])
		if lv.is_empty():
			_skipped_bad += 1
			continue
		# mode 以关卡 JSON 为准（clue_rule + global_rules）；非官方组合（旧算子等）在此挡下。
		var mode := _mode_from_level(lv)
		if mode == "":
			_skipped_non_official += 1
			if not _non_official.has(combo_dir):
				_non_official.append(combo_dir)
			continue
		if not _window_ok(lv, tier):
			_skipped_mismatch += 1
			if (_mismatch as Array).size() < 8:
				(_mismatch as Array).append("%s：档位 %s 但峰值 %s" % [
					fn, tier, str((lv.get("difficulty_profile", {}) as Dictionary).get("max_complexity", -1))])
			continue
		if not _prewon_ok(lv):
			_skipped_prewon += 1
			if (_prewon as Array).size() < 8:
				(_prewon as Array).append("%s/%s：revealed %d ≥ 非雷格 %d（开局即胜死盘）" % [
					list_dir, fn, (lv.get("revealed", []) as Array).size(), _non_mine_count(lv)])
			continue
		_put(mode, side, tier, lv)


## v4.0 窗口一致性：集内档位必须与实测峰值一致（防错档入库）。
## 为什么必须校验：量产/重标两条来源都可能把旧口径文件混进来（文件名 hard_01 而峰值只有 3），
## 一旦入库，玩家会在"噩梦"档遇到浅盘，且全流程不报错。
func _window_ok(lv: Dictionary, tier: String) -> bool:
	if _no_window_check:
		return true
	var dp: Dictionary = lv.get("difficulty_profile", {})
	var peak_tier := Difficulty.tier_of_profile(dp)
	return peak_tier == tier


## v4.0 开局即胜门禁：revealed 覆盖全部非雷格 ⇒ Board 加载时 unknown == remaining_mines ⇒
## 即判 WON，而结算覆盖层尚未实例化（信号丢失）→ 玩家看到「全开却无结算、点不动」的
## 死盘（真实用户 bug，重开一样）——这类盘默认拒收，不得入库。
## 与窗口校验同级但**独立开关**：--allow-prewon 显式放行（不影响 --no-window-check 语义）。
func _prewon_ok(lv: Dictionary) -> bool:
	if _allow_prewon:
		return true
	return (lv.get("revealed", []) as Array).size() < _non_mine_count(lv)


## 非雷格数 = 格子数 − 实际雷数（len(mines) 优先，缺失回退 total_mines）。
## 与 Board 判胜口径、retier_stock.py 的 terminal_at_load 同一算法（三处必须一致）。
func _non_mine_count(lv: Dictionary) -> int:
	var sz: Dictionary = lv.get("size", {})
	var cells: int = int(sz.get("cols", 0)) * int(sz.get("rows", 0))
	var mines: Array = lv.get("mines", [])
	var mine_n: int = mines.size()
	if mine_n <= 0:
		mine_n = int(lv.get("total_mines", 0))
	return maxi(1, cells - mine_n)


## 收一关进 _bag（按 seed 去重）。
func _put(mode: String, side: int, tier: String, lv: Dictionary) -> void:
	var by_mode: Dictionary = _bag.get(mode, {})
	var by_size: Dictionary = by_mode.get(side, {})
	var arr: Array = by_size.get(tier, [])
	var seed_v := int(lv.get("seed", -1))
	for exist in arr:
		if int((exist as Dictionary).get("seed", -2)) == seed_v:
			_skipped_dup += 1
			return
	arr.append(lv)
	_accepted += 1
	by_size[tier] = arr
	by_mode[side] = by_size
	_bag[mode] = by_mode


func _read_level(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return {}
	var lv: Dictionary = parsed
	for f in REQUIRED_FIELDS:
		if not lv.has(f):
			push_warning("[import] 缺字段 %s，跳过: %s" % [f, path])
			return {}
	if (lv["mines"] as Array).is_empty():
		return {}
	return lv


## 关卡 JSON → 库内 mode id（**产物侧真相 = JSON 字段**，与《关卡集供给对账》同口径）。
static func _mode_from_level(lv: Dictionary) -> String:
	return _canonical_mode(str(lv.get("clue_rule", "")), lv.get("global_rules", []))


## (clue_rule, global_rules) → 库内 mode id；非官方组合返回 ""。
## 与 `ui/variant_catalog.build_modes()` 的 id 构造一一对应：
##   classic | o*（观测）| s*（结构）| z*（守恒）| dt（内置骨牌）| s_o（C 类）| s_s（F 类）| z+s+o（T4）
static func _canonical_mode(clue: String, globals: Variant) -> String:
	var gs: Array = []
	if globals is Array:
		for g in globals:
			gs.append(str(g))
	if gs.is_empty():
		if clue == "classic" or VariantAxes.OBS.has(clue):
			return clue
		return ""
	if gs.size() == 1:
		var g1 := str(gs[0])
		if clue == "classic":
			if VariantAxes.STRUCT.has(g1) or VariantAxes.CONSERVE.has(g1) or g1 == "dt":
				return g1
			return ""
		if VariantAxes.OBS.has(clue) and VariantAxes.STRUCT.has(g1):
			return "%s_%s" % [g1, clue]                     # C 类：结构_观测
		return ""
	if gs.size() == 2:
		var a := str(gs[0])
		var b := str(gs[1])
		if clue == "classic" and VariantAxes.STRUCT.has(a) and VariantAxes.STRUCT.has(b):
			# F 类：结构_结构（按轴序归一，与构建侧 i<j 同序）
			if VariantAxes.STRUCT.find(a) < VariantAxes.STRUCT.find(b):
				return "%s_%s" % [a, b]
			return "%s_%s" % [b, a]
		if VariantAxes.OBS.has(clue):
			var cons := a if VariantAxes.CONSERVE.has(a) else (b if VariantAxes.CONSERVE.has(b) else "")
			var st := a if VariantAxes.STRUCT.has(a) else (b if VariantAxes.STRUCT.has(b) else "")
			if cons != "" and st != "":
				return "%s+%s+%s" % [cons, st, clue]       # T4：守恒+结构+观测
		return ""
	return ""


## 官方 mode id 判定（推导结果自检；也用于目录名/规格串的兼容识别）。
static func _is_official_mode(name: String) -> bool:
	return _canonical_mode_from_id(name) != ""


## 目录名 / 规格串 → 库内 mode id；无法识别返回 ""。
## 兼容三种历史形态：量产链额外组合 `x_classic_s1` / `x_o10`（剥 `x_` 与 `classic` 底座）、
## 旧批次 `c_o1` / `g_s1`（剥一字母前缀）、内置路径 `o1` / `s1_o1` / `z1+s1+o1`（恒等）。
## 实测：服务器 15 批产物目录全为 `x_*` 形态——**按旧判据会被 100% 拒掉**（2026-09-19 探针取证）。
static func _canonical_mode_from_id(name: String) -> String:
	var n := name
	for pfx in ["x_", "c_", "g_"]:
		if n.begins_with(pfx):
			n = n.substr(pfx.length())
			break
	if n.begins_with("classic+"):
		n = n.substr(8)
	elif n.begins_with("classic_"):
		n = n.substr(8)
	if n == "classic" or n == "dt":
		return n
	if VariantAxes.OBS.has(n) or VariantAxes.STRUCT.has(n) or VariantAxes.CONSERVE.has(n):
		return n
	var t4 := n.split("+", false)
	if t4.size() == 3 and VariantAxes.CONSERVE.has(str(t4[0])) \
			and VariantAxes.STRUCT.has(str(t4[1])) and VariantAxes.OBS.has(str(t4[2])):
		return n
	var pair := n.split("_", false)
	if pair.size() == 2 and VariantAxes.STRUCT.has(str(pair[0])):
		if VariantAxes.OBS.has(str(pair[1])) or VariantAxes.STRUCT.has(str(pair[1])):
			return n
	return ""


## 尺寸目录名解析：只认规范写法 `5x5`（batch_all_variants.gd 产出）或 `5`（库内既有格式）。
## 为什么不能直接 `int()`：**`int("5x5")` 的实测结果是 55，不是 5**（数字拼接）→ 关卡会被写进
## `levels_lib/<mode>/55/`：选关页按 size=5 找 `5/`，永远看不到，纯垃圾文件（2026-09-19 实测）。
## 纯数字分支只接受**单字符**（`5`~`9`）：`55` 这类歧义名宁可跳过并在报告里点名，也不猜。
static func _parse_side(dir_name: String) -> int:
	var s := dir_name.strip_edges()
	if s.contains("x"):
		var parts := s.split("x", false)
		if parts.size() != 2 or int(parts[0]) != int(parts[1]):
			return 0                    # 非方形（如 5x6）：库的尺寸键是单个 int，不支持
		return int(parts[0])
	return int(s) if s.is_valid_int() and s.length() == 1 else 0


## 写集文件，返回 {mode: {size: {tier: count}}}（本次实际落盘的）。
func _write_sets() -> Dictionary:
	var imported: Dictionary = {}
	var order: Array = _bag.keys()
	order.sort()
	for mode in order:
		var by_size: Dictionary = _bag[mode]
		var sizes: Array = by_size.keys()
		sizes.sort()
		for side in sizes:
			var by_tier: Dictionary = by_size[side]
			for tier in TIERS:
				if not by_tier.has(tier):
					continue
				var arr: Array = by_tier[tier]
				if arr.size() < _min_levels:
					_skipped_thin += 1     # G6：薄集不静默——报告里带阈值打印
					continue
				var rel := "%s/%d/%s.json" % [mode, side, tier]
				var dst := "%s/%s" % [LIB_DIR, rel]
				if FileAccess.file_exists(dst) and not _overwrite:
					print("[import]   跳过（已存在）: %s（用 --overwrite 覆盖）" % rel)
					continue
				# v4.0：集内按深度（峰值）升序、同深度按轮数升序——由浅入深，与档位口径一致
				arr.sort_custom(func(a, b):
					var da: Dictionary = (a as Dictionary).get("difficulty_profile", {})
					var db: Dictionary = (b as Dictionary).get("difficulty_profile", {})
					var pa := int(da.get("max_complexity", 0))
					var pb := int(db.get("max_complexity", 0))
					if pa != pb:
						return pa < pb
					return int(da.get("rounds", 0)) < int(db.get("rounds", 0)))
				var doc := {"mode": mode, "size": side, "tier": tier,
					"count": arr.size(), "levels": arr}
				if not _dry:
					DirAccess.make_dir_recursive_absolute("%s/%s/%d" % [LIB_DIR, mode, side])
					var f := FileAccess.open(dst, FileAccess.WRITE)
					if f == null:
						push_error("[import] 写不了: %s" % dst)
						continue
					f.store_string(JSON.stringify(doc, "  "))
					f.close()
				print("[import]   %s + %d 关" % [rel, arr.size()])
				var m: Dictionary = imported.get(mode, {})
				var s2: Dictionary = m.get(side, {})
				s2[tier] = arr.size()
				m[side] = s2
				imported[mode] = m
	return imported


## --prune（G1b）：清「本轮未产出」的残留集。
## 用途：库内重标（retier_stock.py → 本工具 --overwrite）后，某 (mode,size) 下旧口径/错档的
## 档名集会残留（源里已没有它）——不清掉的话选关页仍能点到、catalog 也会继续记它。
##
## 安全口径（宁可不删，也不误删）：
##   · 只认 levels_lib/<mode>/<size>/ 下的**四档名 json**（<tier>.json）；不删目录、不删
##     catalog（它在库根，不在本层）、不碰其他命名文件；
##   · 某 (mode,size) 本轮**一个集都没产出** → 整目录不删（防把一整席误清空）；
##   · 删除前打印将删清单（前 20 条）+ 计数；
##   · dry-run 只预览不删；未与 --overwrite 同用时也跳过删除（否则「已存在被跳过」的集
##     会被误判为未产出——使用建议本身也写在文件头）。
func _prune_sets(imported: Dictionary) -> void:
	if not _prune:
		return
	var doomed: Array = []      # 可读相对路径（打印 + 对账）
	var abs_paths: Array = []   # res:// 绝对路径（删除）
	var modes: Array = imported.keys()
	modes.sort()
	for mode in modes:
		var by_size: Dictionary = imported[mode]
		var sizes: Array = by_size.keys()
		sizes.sort()
		for side in sizes:
			var produced: Dictionary = by_size[side]     # tier -> count（本轮产出）
			var rel_dir := "%s/%d" % [str(mode), int(side)]
			var d := DirAccess.open("%s/%s" % [LIB_DIR, rel_dir])
			if d == null:
				continue
			for fname in d.get_files():
				var fn := str(fname)
				if not fn.ends_with(".json"):
					continue
				var tier := fn.get_basename()
				if not TIERS.has(tier):
					continue                 # 只认四档名（安全：其余命名一概不碰）
				if produced.has(tier):
					continue
				doomed.append("%s/%s" % [rel_dir, fn])
				abs_paths.append("%s/%s/%s" % [LIB_DIR, rel_dir, fn])
	if doomed.is_empty():
		print("[import] --prune：无残留集（本轮产出的 (mode,size) 目录与盘上档名一致）")
		return
	var shown := mini(20, doomed.size())
	print("[import] --prune：将删除 %d 个未产出残留集（前 %d）:" % [doomed.size(), shown])
	for r in doomed.slice(0, shown):
		print("[import]   %s" % str(r))
	if _dry:
		print("[import] --prune：dry-run，不实际删除")
		return
	if not _overwrite:
		print("[import] --prune 未与 --overwrite 同用：为避免把「已存在被跳过」的集误删，本轮跳过删除；确要清理请补 --overwrite 重跑")
		return
	var removed := 0
	for p in abs_paths:
		if DirAccess.remove_absolute(str(p)) == OK:
			removed += 1
		else:
			push_warning("[import] --prune 删除失败: %s" % str(p))
	print("[import] --prune：已删除 %d 个残留集" % removed)


## 全量重建 catalog.json —— **扫盘上全部 levels_lib**，而非只记本次导入，
## 否则会把库里已有的内容从索引里抹掉（已有的 8 席 9117 关就是这么没的）。
func _rebuild_catalog() -> void:
	var catalog: Dictionary = {}
	var total := 0
	var thin: Array = []      # 薄集（<100 关）：设计口径「每集 100 关」的欠额，报告出来便于补齐
	var md := DirAccess.open(LIB_DIR)
	if md == null:
		push_error("[import] levels_lib 打不开")
		return
	for mode in md.get_directories():
		var mode_dir := "%s/%s" % [LIB_DIR, mode]
		var sd := DirAccess.open(mode_dir)
		if sd == null:
			continue
		for size_dir in sd.get_directories():
			var side := _parse_side(str(size_dir))   # 与扫描侧同规则（防 `5x5` 被读成 55）
			if side <= 0:
				continue
			var td := DirAccess.open("%s/%s" % [mode_dir, size_dir])
			if td == null:
				continue
			for fname in td.get_files():
				var fn := str(fname)
				if not fn.ends_with(".json"):
					continue
				var tier := fn.get_basename()
				if not TIERS.has(tier):
					continue
				var n := _count_in_set("%s/%s/%s" % [mode_dir, size_dir, fn])
				if n <= 0:
					continue
				if n < 100:
					thin.append("%s/%s/%s=%d" % [mode, side, tier, n])
				var by_size: Dictionary = catalog.get(mode, {})
				var by_tier: Dictionary = by_size.get(str(side), {})
				by_tier[tier] = n
				by_size[str(side)] = by_tier
				catalog[mode] = by_size
				total += n
	if _dry:
		print("[import] dry-run：catalog 将有 %d 席 / %d 关" % [catalog.size(), total])
		_report_thin(thin)
		return
	var f := FileAccess.open(CATALOG_PATH, FileAccess.WRITE)
	if f == null:
		push_error("[import] catalog 写不了: %s" % CATALOG_PATH)
		return
	# schema=4（G7）：标记 v4.0 峰值口径（档位 = max_complexity 落窗）。读取侧
	# （ui/level_library.gd::catalog）取的是 ["catalog"] 子字典，加 schema 键对旧读取零影响；
	# 有它之后，库口径换代时离线工具可一眼分辨 catalog 由哪版口径生成。
	f.store_string(JSON.stringify({"schema": 4, "catalog": catalog}, "  "))
	f.close()
	print("[import] catalog 已重建（schema=4）：%d 席 / %d 关" % [catalog.size(), total])
	_report_thin(thin)


## 薄集报告：设计口径「每集 100 关」，<100 的集就是欠额 —— 显式列出来（避免静默欠额）。
func _report_thin(thin: Array) -> void:
	if thin.is_empty():
		return
	print("[import] 薄集（<100 关）%d 个 —— 用 fill_level_lib 增量补齐（断点续跑只补未满单元）" % thin.size())
	print("[import]   前 10: %s" % ", ".join(thin.slice(0, mini(10, thin.size()))))


static func _count_in_set(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return 0
	return int((parsed as Dictionary).get("count", (parsed as Dictionary).get("levels", []).size()))


func _report(imported: Dictionary) -> void:
	var sets := 0
	var levels := 0
	for mode in imported:
		for side in (imported[mode] as Dictionary):
			for tier in (imported[mode][side] as Dictionary):
				sets += 1
				levels += int(imported[mode][side][tier])
	print("[import] 本次导入 %d 个集 / %d 关；扫描单元 %d，坏关 %d，重复 %d" % [
		sets, levels, _units_seen, _skipped_bad, _skipped_dup])
	if _skipped_mismatch > 0:
		print("[import] 不匹配跳过 %d 关（集内档位 ≠ 实测峰值；前 8: %s）" % [
			_skipped_mismatch, ", ".join(_mismatch.slice(0, mini(8, _mismatch.size())))])
	if _skipped_prewon > 0:
		print("[import] 开局即胜死盘拒收 %d 关（revealed 覆盖全部非雷格；加 --allow-prewon 可放行；前 8: %s）" % [
			_skipped_prewon, ", ".join(_prewon.slice(0, mini(8, _prewon.size())))])
	if _skipped_non_official > 0:
		print("[import] 非官方组合跳过 %d 关（按关卡 JSON 判定；来源目录 %d 个，前 8: %s）" % [
			_skipped_non_official, _non_official.size(),
			", ".join(_non_official.slice(0, mini(8, _non_official.size())))])
	if not _bad_sizes.is_empty():
		print("[import] 尺寸目录名不认识、跳过 %d 个（规范为 5x5 或 5；前 8: %s）" % [
			_bad_sizes.size(), ", ".join(_bad_sizes.slice(0, mini(8, _bad_sizes.size())))])
	if _skipped_thin > 0:
		print("[import] 薄集跳过 %d 个（集内关卡数 < --min=%d；先补产或调低 --min 再导入）" % [
			_skipped_thin, _min_levels])
	if _skipped_badname > 0:
		print("[import] 档名不符 <tier>_<N> 跳过 %d 个（前 5 条已 push_warning；核对源目录混入的文件）" % [
			_skipped_badname])


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
