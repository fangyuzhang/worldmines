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
#
# **命名契约（最关键）**：目录名 = 选关页 `VariantCatalog.MODES[].id`，逐字一致：
#     单算子 = 规则 id（o1 / s1 / z1）；C 类 = 结构_观测（s1_o1）；
#     F 类 = 结构_结构（s1_s2）；T4 = 守恒+结构+观测（z1+s1+o1）。
#   为兼容旧批次（2026-09-18 之前批量脚本用 c_/g_ 前缀）此处自动剥离前缀，
#   但**新产出必须直接是上面的形式**（batch_all_variants.gd 已同步修正）。
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

## mode -> size -> tier -> Array[level]
var _bag: Dictionary = {}
var _skipped_bad := 0
var _skipped_dup := 0
var _units_seen := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		var s := str(a)
		if s == "--dry-run":
			_dry = true
		elif s == "--overwrite":
			_overwrite = true
		elif s.begins_with("--min="):
			_min_levels = maxi(1, int(s.substr(6)))
		elif not s.begins_with("--"):
			_src = s

	print("[import] 源目录: %s%s" % [_src, "（dry-run，不写盘）" if _dry else ""])
	_scan_source()
	var imported := _write_sets()
	_rebuild_catalog()
	_report(imported)
	CliShutdown.request_exit(0)


## 扫描 `src/<combo>/<size>/<tier>_<idx>.json`，收进 _bag。
func _scan_source() -> void:
	var root := DirAccess.open(_src)
	if root == null:
		push_error("[import] 源目录打不开: %s" % _src)
		return
	for combo_name in root.get_directories():
		var mode := _normalize_mode(str(combo_name))
		var combo_dir := "%s/%s" % [_src, combo_name]
		var cd := DirAccess.open(combo_dir)
		if cd == null:
			continue
		for size_dir in cd.get_directories():
			var side := int(str(size_dir))
			if side <= 0:
				continue
			_scan_size(combo_dir, size_dir, mode, side)
		print("[import]   %-16s → %s" % [combo_name, mode])


func _scan_size(combo_dir: String, size_dir: String, mode: String, side: int) -> void:
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
		if parts.size() != 2:
			continue
		var tier := str(parts[0])
		if not TIERS.has(tier):
			continue
		_units_seen += 1
		var lv := _read_level("%s/%s" % [list_dir, fn])
		if lv.is_empty():
			_skipped_bad += 1
			continue
		_put(mode, side, tier, lv)


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


## 旧批次目录名 `c_o1` / `g_s1` → `o1` / `s1`（新产出直接就是后者，此处恒等）。
static func _normalize_mode(name: String) -> String:
	for pfx in ["c_", "g_"]:
		if name.begins_with(pfx):
			return name.substr(pfx.length())
	return name


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
					continue
				var rel := "%s/%d/%s.json" % [mode, side, tier]
				var dst := "%s/%s" % [LIB_DIR, rel]
				if FileAccess.file_exists(dst) and not _overwrite:
					print("[import]   跳过（已存在）: %s（用 --overwrite 覆盖）" % rel)
					continue
				arr.sort_custom(func(a, b):
					return float((a as Dictionary).get("difficulty", 0.0)) \
							< float((b as Dictionary).get("difficulty", 0.0)))
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


## 全量重建 catalog.json —— **扫盘上全部 levels_lib**，而非只记本次导入，
## 否则会把库里已有的内容从索引里抹掉（已有的 8 席 9117 关就是这么没的）。
func _rebuild_catalog() -> void:
	var catalog: Dictionary = {}
	var total := 0
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
			var side := int(str(size_dir))
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
				var by_size: Dictionary = catalog.get(mode, {})
				var by_tier: Dictionary = by_size.get(str(side), {})
				by_tier[tier] = n
				by_size[str(side)] = by_tier
				catalog[mode] = by_size
				total += n
	if _dry:
		print("[import] dry-run：catalog 将有 %d 席 / %d 关" % [catalog.size(), total])
		return
	var f := FileAccess.open(CATALOG_PATH, FileAccess.WRITE)
	if f == null:
		push_error("[import] catalog 写不了: %s" % CATALOG_PATH)
		return
	f.store_string(JSON.stringify({"catalog": catalog}, "  "))
	f.close()
	print("[import] catalog 已重建：%d 席 / %d 关" % [catalog.size(), total])


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


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
