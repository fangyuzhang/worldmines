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
##
## 【2026-10-03 接入 `LevelFormat` 分层（文档「八」核心架构决策）】
##   · 写盘：`write_set`/`materialize` 前先过 `LevelFormat.check_write_budget`（超限**拒绝**），
##     关卡按 `LevelFormat.to_result_layer` / `to_design_layer` 写**分层信封** `{version, result, design}`。
##   · 读取：老文件**先 `LevelFormat.migrate`** 再取用（旧字段不丢）；结果层直接喂 `Board.load_level`。
##   · 故障隔离：设计层缺失 / 损坏都不影响开局（游戏**只读结果层**）。
##   · 未知更高版本 ⇒ **拒载 + 可读原因**（绝不猜）。
##   · 向后兼容：`<root>/<大小>/<档位>.json` 集文件与平铺单关两种老布局都仍能读。

const SCHEMA := 1
const TIER_ORDER: Array = ["easy", "normal", "hard"]
## 单关物化目录（`GameSession.start_level` 要一个文件路径，集文件里的关卡得先落成单文件）。
const PLAY_DIR := "user://lib_play"

# ==================== 分层 / 包内布局的单一真源 ====================

## 结果层（游戏只读它）与设计层（编辑器才读）的目录名。工坊包内布局 = `<LEVELS_DIR>/...` + `<DESIGN_DIR>/...`，
## 写入方（`WorkshopPack.build`）与读取方（`collect` / 测试）都引用这里，杜绝"写新路径、读旧路径"的分叉。
const LEVELS_DIR := "levels"
const DESIGN_DIR := "design"

## `LevelFormat.RESULT_KEYS` 之外、本仓**游戏侧确实会读**的键（`Board.load_level` / `LevelLoader` 读它们）。
## 【为什么本层要补】`level_format.gd` 是已交付、有单测钉死的模块，本次只做**集成适配**：结果层必须真的
## 覆盖游戏所需，否则"只读结果层"就会静默丢数据（例如规则关的 `global_rules`、难度画像 `difficulty_profile`）。
## 这些键进结果层、并从设计层移除（两层不重叠）。
const GAME_KEYS: Array = [
	"difficulty_profile", "difficulty", "global_rules",
	"variant", "clue_def", "constraint_def", "dominoes", "hidden_state",
	"custom", "custom_shapes", "palette", "groups",
]


# ==================== 结果层 / 设计层（分层信封）====================

## 一份关卡文档 → 分层信封 `{version, result, design}`。
##   · result = `LevelFormat.to_result_layer` + `GAME_KEYS` 里游戏侧额外要读的键；
##   · design = `LevelFormat.to_design_layer`（未识别字段全留）减去已进结果层的键 ⇒ 两层不重叠。
static func envelope(doc: Dictionary) -> Dictionary:
	var result := LevelFormat.to_result_layer(doc)
	var design := LevelFormat.to_design_layer(doc)
	for k in GAME_KEYS:
		if doc.has(k) and not result.has(k):
			result[k] = _dup(doc[k])
		design.erase(k)
	var v := int(result.get("version", LevelFormat.CURRENT_VERSION))
	return {"version": v, "result": result, "design": design}


## 是否是分层信封（含 `result` 字典）。
static func is_envelope(doc: Dictionary) -> bool:
	return doc.get("result", null) is Dictionary


## 任意输入（信封 / 纯结果层 / 平铺全量关卡）→ 规范信封。
static func _as_envelope(doc: Dictionary) -> Dictionary:
	if is_envelope(doc):
		var env := doc.duplicate(true)
		if not (env.get("design", null) is Dictionary):
			env["design"] = {}
		return env
	# 纯结果层（有 cells、无 mines）：原样当 result，不能回头跑 to_result_layer
	#（那会重新从 clue_rule/custom 推 rule，而结果层里根本没有这些键 ⇒ 规则会被降级成经典）。
	if doc.get("cells", null) is Array and not doc.has("mines"):
		return {"version": int(doc.get("version", LevelFormat.CURRENT_VERSION)),
			"result": doc.duplicate(true), "design": {}}
	return envelope(doc)


## 结果层 → `Board.load_level` 能**直接吃**的关卡字典。**只读结果层**：设计层缺失 / 损坏都不影响。
## 注意：`LevelFormat.load_result` 吐的是游戏侧输入（含 `mines`），但仍有一处必须桥接——见 `_bridge_rule`。
static func playable(doc: Dictionary) -> Dictionary:
	if doc.is_empty():
		return {}
	var env := _as_envelope(doc)
	var res := LevelFormat.load_result(env)
	if not bool(res.get("ok", false)):
		return {}
	var lv: Dictionary = res["level"]
	var result: Dictionary = env["result"] as Dictionary
	_bridge_rule(lv, result)
	for k in GAME_KEYS:
		if result.has(k) and not lv.has(k):
			lv[k] = _dup(result[k])
	return lv


## 取设计层（信封 → `design`；平铺文档 → `to_design_layer`）。
static func design_of(doc: Dictionary) -> Dictionary:
	if doc.get("design", null) is Dictionary:
		return (doc["design"] as Dictionary).duplicate(true)
	if is_envelope(doc):
		return {}
	return LevelFormat.to_design_layer(doc)


## 信封 → 平铺关卡（结果层 + 设计层合并，结果层优先）。玩家侧读取器 / 编辑器重建都用它，
## 从而"结果层能开局、设计层能回编辑"这两件事用的是同一份数据。
static func flatten(doc: Dictionary) -> Dictionary:
	var lv := playable(doc)
	if lv.is_empty():
		return {}
	var design := design_of(doc)
	for k in design.keys():
		if not lv.has(k):
			lv[k] = _dup(design[k])
	return lv


## 【必须桥接的原因】`LevelFormat` 结果层把规则放 `rule`（id / level / spec），而 `Board.load_level`
## 读的是 `rule_level` + `clue_rule` + `custom.spec`。不桥接的话，规则关卡会**静默退回经典 8 邻**、
## 数字全错且不报错——那正是玩家只会当成"游戏 bug"的一类失败。
static func _bridge_rule(lv: Dictionary, result: Dictionary) -> void:
	var rule_v: Variant = result.get("rule", null)
	if not (rule_v is Dictionary):
		return
	var rule: Dictionary = rule_v
	var rid := str(rule.get("id", ""))
	if bool(rule.get("level", false)) and rid != "":
		if not lv.has("rule_level"):
			lv["rule_level"] = true
		if not lv.has("clue_rule"):
			lv["clue_rule"] = rid
	var spec: Variant = rule.get("spec", null)
	if spec is Dictionary and not (spec as Dictionary).is_empty():
		var custom: Dictionary = {}
		if lv.get("custom", null) is Dictionary:
			custom = (lv["custom"] as Dictionary).duplicate(true)
		if not custom.has("spec"):
			custom["spec"] = (spec as Dictionary).duplicate(true)
		lv["custom"] = custom


# ==================== 集文件读写 ====================

## 写一个集文件（目录会自动建）。失败返回 false，**由调用方给出人话原因**（本层不打印、不静默）。
## 关卡按分层信封落盘；任何一关超体积护栏 ⇒ 整体拒绝（不写出半份坏集）。
static func write_set(path: String, mode: String, size: int, tier: String, levels: Array) -> bool:
	return bool(write_set_report(path, mode, size, tier, levels).get("ok", false))


## `write_set` 的**带原因**版本：超预算 / 写盘失败时返回 `{ok, reason, cells, est_bytes}`。
static func write_set_report(path: String, mode: String, size: int, tier: String, levels: Array) -> Dictionary:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var envelopes: Array = []
	for lv in levels:
		if not (lv is Dictionary):
			continue
		var chk := LevelFormat.check_write_budget(lv)
		if not bool(chk.get("ok", false)):
			return {"ok": false, "reason": "集文件 %s 有一关超预算：%s" % [path, str(chk.get("reason", ""))],
				"cells": int(chk.get("cells", 0)), "est_bytes": int(chk.get("est_bytes", 0))}
		envelopes.append(envelope(lv))
	var payload := {
		"schema": SCHEMA,
		"version": LevelFormat.CURRENT_VERSION,
		"mode": mode,
		"size": size,
		"tier": tier,
		"count": envelopes.size(),
		"levels": envelopes,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "reason": "无法写入集文件：%s" % path, "cells": 0, "est_bytes": 0}
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
	return {"ok": true, "reason": "", "cells": 0, "est_bytes": 0}


## 读集文件 → `{schema, mode, size, tier, count, levels, designs}`；不是集文件则返回 {}。
## `levels` 是**平铺关卡**（结果为先 + 设计字段合回）——兼容既有玩家侧消费者；
## `designs` 是与之平行的设计层（新分层文件才有；老文件为 {}）。
static func read_set(path: String) -> Dictionary:
	return read_set_report(path).get("set", {})


## `read_set` 的**带原因**版本。老文件先 `LevelFormat.migrate`；未知更高版本 **拒载 + 原因**。
static func read_set_report(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "reason": "文件不存在：%s" % path, "set": {}}
	var parsed: Variant = SpecHelper.parse_json_safe(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return {"ok": false, "reason": "不是合法的 JSON 对象：%s" % path, "set": {}}
	var d: Dictionary = parsed
	if not (d.get("levels", null) is Array):
		return {"ok": false, "reason": "不是集文件（缺少 levels 数组）：%s" % path, "set": {}}
	var v := LevelFormat.version_of(d)
	if v > LevelFormat.CURRENT_VERSION:
		return {"ok": false, "reason": _version_reason("集文件 %s" % path, v), "set": {}}
	var levels: Array = []
	var designs: Array = []
	for lv in (d["levels"] as Array):
		if lv is Dictionary and is_envelope(lv as Dictionary):
			var flat := flatten(lv as Dictionary)
			if flat.is_empty():
				return {"ok": false, "reason": "集文件 %s 内有一关的结果层损坏（无法开局）" % path, "set": {}}
			levels.append(flat)
			designs.append(design_of(lv as Dictionary))
		elif lv is Dictionary:
			var m := LevelFormat.migrate(lv as Dictionary)
			if not bool(m.get("ok", false)):
				return {"ok": false, "reason": "集文件 %s 内有一关：%s" % [path, str(m.get("reason", ""))], "set": {}}
			levels.append(m["doc"])
			designs.append({})
		else:
			levels.append(lv)
			designs.append({})
	var out := d.duplicate(true)
	out["levels"] = levels
	out["designs"] = designs
	return {"ok": true, "reason": "", "set": out}


## 读一个"可能就是单关"的 json（不是字典/读不到 → {}）。
static func read_level(path: String) -> Dictionary:
	return read_level_report(path).get("level", {})


## `read_level` 的**带原因**版本。信封 → 只读结果层开局（设计层坏也不影响）；老平铺关卡 → 先迁移；
## 非关卡文件（index/manifest/…）→ 原样返回（不塞无关字段）。
static func read_level_report(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "reason": "文件不存在：%s" % path, "level": {}}
	var parsed: Variant = SpecHelper.parse_json_safe(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return {"ok": false, "reason": "不是合法的 JSON 对象：%s" % path, "level": {}}
	var d: Dictionary = parsed
	if is_envelope(d):
		var v := LevelFormat.version_of(d)
		if v > LevelFormat.CURRENT_VERSION:
			return {"ok": false, "reason": _version_reason("关卡 %s" % path, v), "level": {}}
		var flat := flatten(d)
		if flat.is_empty():
			return {"ok": false, "reason": "关卡 %s 的结果层损坏（无法开局）" % path, "level": {}}
		return {"ok": true, "reason": "", "level": flat}
	if not _looks_like_level(d):
		return {"ok": true, "reason": "", "level": d}
	var m := LevelFormat.migrate(d)
	if not bool(m.get("ok", false)):
		return {"ok": false, "reason": "关卡 %s：%s" % [path, str(m.get("reason", ""))], "level": {}}
	return {"ok": true, "reason": "", "level": m["doc"]}


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
## 写的是**结果层 → Board 直接能吃**的形态（`playable`）；每次重写（文件很小，
## 宁可多写一次，也不让玩家玩到过期数据）。超预算 → 返回 "" 并在 `materialize_report` 里给原因。
static func materialize(lv: Dictionary, name_hint: String, out_dir := PLAY_DIR) -> String:
	return str(materialize_report(lv, name_hint, out_dir).get("path", ""))


## `materialize` 的**带原因**版本（玩家侧 `start_level` 只需要路径 ⇒ 主入口仍返回 String）。
static func materialize_report(lv: Dictionary, name_hint: String, out_dir := PLAY_DIR) -> Dictionary:
	if lv.is_empty():
		return {"ok": false, "reason": "关卡为空", "path": ""}
	var chk := LevelFormat.check_write_budget(lv)
	if not bool(chk.get("ok", false)):
		return {"ok": false, "reason": str(chk.get("reason", "")), "path": "",
			"cells": int(chk.get("cells", 0)), "est_bytes": int(chk.get("est_bytes", 0))}
	var play := playable(lv)
	if play.is_empty():
		return {"ok": false, "reason": "关卡结果层损坏（无法开局）", "path": ""}
	if not DirAccess.dir_exists_absolute(out_dir):
		DirAccess.make_dir_recursive_absolute(out_dir)
	var path := out_dir.path_join("%s.json" % _slug(name_hint))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "reason": "无法写入：%s" % path, "path": ""}
	f.store_string(JSON.stringify(play, "  "))
	f.close()
	return {"ok": true, "reason": "", "path": path}


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


## 看起来像"一关"的字典（用于把 index.json / manifest.json 这类非关卡文件排除在迁移之外）。
static func _looks_like_level(d: Dictionary) -> bool:
	if d.get("size", null) is Dictionary:
		return true
	if d.get("mines", null) is Array:
		return true
	if d.get("cells", null) is Array and d.get("revealed", null) is Array:
		return true
	return false


static func _version_reason(label: String, v: int) -> String:
	return "%s 的格式版本 v%d 高于本程序支持的最高版本 v%d，拒绝加载（不猜测更高版本的语义）" % [
		label, v, LevelFormat.CURRENT_VERSION]


static func _slug(s: String) -> String:
	var out := ""
	for ch in s:
		if (ch >= "0" and ch <= "9") or (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or ch == "_" or ch == "-":
			out += ch
		elif ch == " ":
			out += "_"
	return out if out != "" else "level"


static func _dup(v: Variant) -> Variant:
	if v is Dictionary:
		return (v as Dictionary).duplicate(true)
	if v is Array:
		return (v as Array).duplicate(true)
	return v
