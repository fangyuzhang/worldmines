class_name LevelSets
extends RefCounted

## 「关卡集」文件的读写、收集与物化（批量生产 P6，2026-10-02）。
##
## 【为什么必须有"集文件"】用户要一次生成 100 关并发布创意工坊，而安装侧有硬上限
##（`workshop_pack.gd:MAX_INSTALL_FILES = 64`）⇒ 一关一文件必然撞墙。
## 仓库既有口径就是集文件：`res://levels_lib/<mode>/<size>/<tier>.json`，形如
##   {"mode":"classic","size":5,"tier":"easy","count":12,"levels":[{...}]}
## 每关自带 `difficulty_profile`（难度唯一真源 = `Difficulty.tier_of_profile`）。
## 本文件把这条口径做成**一份**实现：批量生产写它、工坊打包收集它、玩家侧列表读它 ⇒ 三处不会漂移。
##
## 【与 `ui/level_library.gd` 的分工】那边读的是 `res://levels_lib`（官方库，路径写死，
## 还带"集内档位必须同窗"的玩家可见闸门）；本文件读的是 `user://`（Mod / 工坊安装目录）。
## 共用的是**文件格式**与档位判定，不是路径绑定——所以这里不复制任何难度逻辑。

const SCHEMA := 1
const TIER_ORDER: Array = ["easy", "normal", "hard"]
## 单关物化目录（`GameSession.start_level` 要一个文件路径，集文件里的关卡得先落成单文件）。
const PLAY_DIR := "user://lib_play"


## 写一个集文件（目录会自动建）。失败返回 false，**由调用方给出人话原因**（本层不打印、不静默）。
static func write_set(path: String, mode: String, size: int, tier: String, levels: Array) -> bool:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var payload := {
		"schema": SCHEMA,
		"mode": mode,
		"size": size,
		"tier": tier,
		"count": levels.size(),
		"levels": levels,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
	return true


## 读集文件 → {schema, mode, size, tier, count, levels}；不是集文件则返回 {}。
static func read_set(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = SpecHelper.parse_json_safe(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return {}
	var d: Dictionary = parsed
	if not (d.get("levels", null) is Array):
		return {}
	return d


## 读一个"可能就是单关"的 json（不是字典/读不到 → {}）。
static func read_level(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = SpecHelper.parse_json_safe(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## 一关属于哪一档：**只认** `difficulty_profile`（与官方库同口径）。
## 读不到档位（老文件 / Mod 自产）时用 `fallback`，再由调用方决定要不要显示"未分档"。
static func tier_of_level(lv: Dictionary, fallback := "") -> String:
	var t := Difficulty.tier_of_profile(lv.get("difficulty_profile", {}))
	return t if t != "" else fallback


## 一关的边长（方阵盘取 rows；异形盘取 size 里的较大边，仅用于分组显示）。
static func size_of(lv: Dictionary) -> int:
	var s: Variant = lv.get("size", {})
	if s is Dictionary:
		return maxi(int((s as Dictionary).get("rows", 0)), int((s as Dictionary).get("cols", 0)))
	return 0


## 收集一个目录下所有关卡，按「大小 → 档位」分组。
## 既认集文件（`<root>/<大小>/<档位>.json`），也认平铺的单关文件（`<root>/*.json`，
## `ui/mod_select.gd` 既有的产出布局）——两种布局都必须能玩到，否则老包会"装好了却一关都不显示"。
## 返回 {ok, count, groups:{"8":{"easy":[关卡...]}}, sizes:[int], per_tier:{tier:count},
##       per_size:{size:count}, files:[String], reason}
static func collect(root: String) -> Dictionary:
	var groups := {}
	var files: Array[String] = []
	var per_tier := {}
	var per_size := {}
	var d := DirAccess.open(root)
	if d == null:
		return {"ok": false, "count": 0, "groups": {}, "sizes": [], "per_tier": {},
			"per_size": {}, "files": [], "reason": "目录不存在：%s" % root}
	# ① 集文件：<root>/<大小>/<档位>.json
	for sub in d.get_directories():
		var sub_s := str(sub)
		if not sub_s.is_valid_int():
			continue
		var size := int(sub_s)
		var sd := DirAccess.open(root.path_join(sub_s))
		if sd == null:
			continue
		for f in sd.get_files():
			var f_s := str(f)
			if not f_s.ends_with(".json"):
				continue
			var path := root.path_join(sub_s).path_join(f_s)
			var set := read_set(path)
			if set.is_empty():
				continue
			var set_tier := str(set.get("tier", f_s.get_basename()))
			for lv in (set["levels"] as Array):
				if lv is Dictionary:
					_bucket(groups, per_tier, per_size, size, tier_of_level(lv, set_tier), lv)
			files.append(path)
	# ② 平铺单关：<root>/*.json
	for f in d.get_files():
		var f_s := str(f)
		if not f_s.ends_with(".json"):
			continue
		var path := root.path_join(f_s)
		var lv := read_level(path)
		if lv.is_empty():
			continue
		var size := size_of(lv)
		_bucket(groups, per_tier, per_size, size, tier_of_level(lv, _tier_from_name(f_s)), lv)
		files.append(path)
	# `groups` 的键必须是字符串（字典键），但 `sizes` 给 UI 用 ⇒ 出成**升序整数数组**，
	# 否则调用方每次都要 `int(k)` 转换、还容易忘了转（本文件的第一版就把它当整数数组返回过）。
	var sizes: Array[int] = []
	for k in per_size.keys():
		sizes.append(int(k))
	sizes.sort()
	return {"ok": true, "count": _count_levels(groups), "groups": groups,
		"sizes": sizes, "per_tier": per_tier, "per_size": per_size, "files": files, "reason": ""}


## 把一关写成可开玩的单文件（集文件里的关卡没有独立路径 ⇒ 玩家的 `start_level(path)` 需要它）。
## 每次重写（文件很小；宁可多写一次，也不让玩家玩到过期数据）。
static func materialize(lv: Dictionary, name_hint: String, out_dir := PLAY_DIR) -> String:
	if lv.is_empty():
		return ""
	if not DirAccess.dir_exists_absolute(out_dir):
		DirAccess.make_dir_recursive_absolute(out_dir)
	var path := out_dir.path_join("%s.json" % _slug(name_hint))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(lv, "  "))
	f.close()
	return path


## 分组统计的短句（玩家侧组头 / 编辑器进度文案共用一句话术）。
static func group_label(size: int, tier: String) -> String:
	return "%d×%d　%s" % [size, size, Difficulty.tier_short(tier)]


static func _bucket(groups: Dictionary, per_tier: Dictionary, per_size: Dictionary,
		size: int, tier: String, lv: Dictionary) -> void:
	var sk := str(size) if size > 0 else "0"
	var tk := tier if tier != "" else "unknown"
	if not groups.has(sk):
		groups[sk] = {}
	var by_tier: Dictionary = groups[sk]
	if not by_tier.has(tk):
		by_tier[tk] = []
	(by_tier[tk] as Array).append(lv)
	per_tier[tk] = int(per_tier.get(tk, 0)) + 1
	per_size[sk] = int(per_size.get(sk, 0)) + 1


static func _count_levels(groups: Dictionary) -> int:
	var n := 0
	for sk in groups.keys():
		for tk in (groups[sk] as Dictionary).keys():
			n += ((groups[sk] as Dictionary)[tk] as Array).size()
	return n


## 从既有文件名里认档位（`<规则>_<档位>_NN.json`，`ui/mod_select.gd` 的老布局）。
static func _tier_from_name(file_name: String) -> String:
	for t in TIER_ORDER:
		if file_name.find("_%s_" % t) != -1:
			return t
	return ""


static func _slug(s: String) -> String:
	var out := ""
	for ch in s:
		if (ch >= "0" and ch <= "9") or (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or ch == "_" or ch == "-":
			out += ch
		elif ch == " ":
			out += "_"
	return out if out != "" else "level"
