# mod_loader.gd —— mod 规则包加载（文档第二篇 §2.5 / §7）
# 从 JSON 文本解析 Def（线索/约束），注册到 DefEngine。
# 文档 IR 原子命名 → DefEngine 常量映射。
class_name ModLoader
extends RefCounted

var engine := DefEngine.new()

# 文档线索窗口名 → DefEngine window 常量
const WINDOW_MAP := {
	"n8": DefEngine.WINDOW_N8,
	"n4": DefEngine.WINDOW_N4,
	"same_color_n8": DefEngine.WINDOW_DIAG,
	"ring8": DefEngine.WINDOW_RING8,
	"ray_right": DefEngine.WINDOW_RAY_RIGHT,
}

# 文档线索聚合名 → DefEngine aggregate 常量
const AGG_MAP := {
	"sum": DefEngine.AGG_SUM,
	"weighted_sum": DefEngine.AGG_WEIGHTED_SUM,
	"first_index": DefEngine.AGG_FIRST_INDEX,
	"run_count": DefEngine.AGG_RUN_COUNT,
}

# 文档全局约束 op 名 → DefEngine op 常量
const OP_MAP := {
	"symmetry_axis": DefEngine.OP_SYMMETRY_AXIS,
	"sequence_diff": DefEngine.OP_SEQUENCE_DIFF,
	"pattern_forbidden": DefEngine.OP_PATTERN_FORBIDDEN,
	"partition_pairing": DefEngine.OP_PARTITION_PAIRING,
}

# sum_equality 的 region → 具体 op（四象/端点/四色）
const REGION_OP := {
	"quadrant": DefEngine.OP_QUADRANT_EQUAL,
	"endpoint": DefEngine.OP_ENDPOINT_EQUAL,
	"color": DefEngine.OP_COLOR_EQUAL,
}


## 从 JSON 文本加载线索 Def。返回 { ok, def_name, reason }。
func load_clue_def(json_text: String) -> Dictionary:
	var data: Variant = JSON.parse_string(json_text)
	if not (data is Dictionary):
		return {"ok": false, "reason": "JSON 解析失败"}
	if data.get("type", "") != "clue":
		return {"ok": false, "reason": "type 不是 clue"}
	var def_name: String = data.get("defName", "")
	var window: String = WINDOW_MAP.get(data.get("window", ""), "")
	var aggregate: String = AGG_MAP.get(data.get("aggregate", ""), "")
	if def_name == "" or window == "" or aggregate == "":
		return {"ok": false, "reason": "缺少 defName/window/aggregate 或不支持的 IR 原子"}
	var vr: Array = data.get("value_range", [0, 8])
	var def := {
		"type": "clue",
		"window": window,
		"aggregate": aggregate,
		"max": int(vr[1]) if vr.size() > 1 else 8,
		"min_clue": int(data.get("empty_value", 0)),
	}
	engine.register_clue_def(def_name, def)
	return {"ok": true, "def_name": def_name}


## 从 JSON 文本加载约束 Def。返回 { ok, def_name, reason }。
func load_constraint_def(json_text: String) -> Dictionary:
	var data: Variant = JSON.parse_string(json_text)
	if not (data is Dictionary):
		return {"ok": false, "reason": "JSON 解析失败"}
	if data.get("type", "") != "constraint":
		return {"ok": false, "reason": "type 不是 constraint"}
	var def_name: String = data.get("defName", "")
	var op: String = data.get("op", "")
	if op == "sum_equality":
		op = REGION_OP.get(data.get("region", ""), "")
	else:
		op = OP_MAP.get(op, "")
	if def_name == "" or op == "":
		return {"ok": false, "reason": "缺少 defName/op 或不支持的 op"}
	engine.register_constraint_def(def_name, {"type": "constraint", "op": op})
	return {"ok": true, "def_name": def_name}


## 从 JSON 文本加载 Def（按 type 自动分发线索/约束）。
func load_def(json_text: String) -> Dictionary:
	var data: Variant = JSON.parse_string(json_text)
	if not (data is Dictionary):
		return {"ok": false, "reason": "JSON 解析失败"}
	match data.get("type", ""):
		"clue":
			return load_clue_def(json_text)
		"constraint":
			return load_constraint_def(json_text)
		_:
			return {"ok": false, "reason": "不支持的 Def type"}


## 加载整个 mod 目录（workshop_rule/ 结构：defs/*.json）。
## 返回 { ok, loaded, reason }。
func load_mod_dir(dir_path: String) -> Dictionary:
	var defs_dir := dir_path.path_join("defs")
	var dir := DirAccess.open(defs_dir)
	if dir == null:
		return {"ok": false, "loaded": 0, "reason": "无法打开 defs 目录: %s" % defs_dir}
	var loaded := 0
	var errors: Array = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			var f := FileAccess.open(defs_dir.path_join(fname), FileAccess.READ)
			if f != null:
				var r := load_def(f.get_as_text())
				f.close()
				if r.get("ok", false):
					loaded += 1
				else:
					errors.append("%s: %s" % [fname, r.get("reason", "")])
			else:
				errors.append("%s: 无法读取" % fname)
		fname = dir.get_next()
	dir.list_dir_end()
	return {"ok": loaded > 0, "loaded": loaded, "reason": " ".join(errors)}
