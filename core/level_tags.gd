# level_tags.gd —— 进度键 / 关卡路径 → 归属标签（纯函数，无 I/O，无 class_name）
#
# 谁在用：成就系统（「观测轴通关 5 关」「错觉收藏 3 关」）与掌握度雷达（三轴通关数）。
# 两处如果各写一遍解析，必然出现「成就里算结构轴、雷达里不算」的静默不一致 —— 所以只此一份。
#
# ⚠️ 刻意不写 class_name（坑表 #26）。调用方：const Tags := preload("res://core/level_tags.gd")。
extends RefCounted


const Axes := preload("res://core/variant_axes.gd")
const Series := preload("res://core/illusion_series.gd")

## 旧内置 id → 官方轴席位（对照 ui/variant_catalog.gd 的 HIDDEN_RULES 注释：
## clock=O8 / loopruns=O10 / pf=S1 / mx=Z1 / rl=Z2 / qd=Z3）。
## 这些 id 仍会出现在老存档的进度键里，不认就等于那批通关凭空消失。
const ALIASES := {
	"clock": "o8", "loopruns": "o10",
	"pf": "s1", "mx": "z1", "rl": "z2", "qd": "z3",
}

const KIND_OBS := "obs"
const KIND_STRUCT := "struct"
const KIND_CONSERVE := "conserve"
const KIND_MIXED := "mixed"
const KIND_SPECIAL := "special"


## 进度键 → {mode, size, tier, idx, lib}；非序列关（res:// 手工关、测试关）返回 {}。
## 与 ui/level_sequence.gd 的键格式一致：gen://<mode>/<size>/<idx>、lib://<mode>/<size>/<tier>/<idx>。
static func parse_key(key: String) -> Dictionary:
	var rest := ""
	var lib := false
	if key.begins_with("lib://"):
		rest = key.substr(6)
		lib = true
	elif key.begins_with("gen://"):
		rest = key.substr(6)
	else:
		return {}
	var parts := rest.split("/")
	if parts.size() < 3 or str(parts[0]) == "":
		return {}
	var out := {"mode": str(parts[0]), "size": int(str(parts[1])), "lib": lib}
	if lib:
		if parts.size() < 4:
			return {}
		out["tier"] = str(parts[2])
		out["idx"] = int(str(parts[3]))
	else:
		out["idx"] = int(str(parts[2]))
	return out


## 进度键 ↔ 关卡路径都能喂：路径拿 basename 去符号化（`o1_8_0.json` → mode `o1`）。
## 只认「像序列键」的输入，其它一律返回 {}。
static func parse_any(key_or_path: String) -> Dictionary:
	var p := parse_key(key_or_path)
	if not p.is_empty():
		return p
	var base := key_or_path.get_file().get_basename()
	var parts := base.split("_")
	if parts.size() < 3:
		return {}
	if not str(parts[parts.size() - 1]).is_valid_int() or not str(parts[parts.size() - 2]).is_valid_int():
		return {}
	var mode := "_".join(parts.slice(0, parts.size() - 2))
	if mode == "":
		return {}
	return {"mode": mode, "size": int(str(parts[parts.size() - 2])), "idx": int(str(parts[parts.size() - 1])), "lib": false}


## 模式 id → 官方轴 id 列表（可能多席：混合档）。不属任何轴返回 []。
static func axes_for_mode(mode: String) -> Array[String]:
	var out: Array[String] = []
	if mode == "":
		return out
	for tok in mode.split("_", false):
		var t := str(tok)
		if ALIASES.has(t):
			t = str(ALIASES[t])
		if not (Axes.OBS.has(t) or Axes.STRUCT.has(t) or Axes.CONSERVE.has(t)):
			continue
		if not out.has(t):
			out.append(t)
	return out


## 进度键 → 轴 id 列表。
static func axes_of(key: String) -> Array[String]:
	var p := parse_any(key)
	if p.is_empty():
		return []
	return axes_for_mode(str(p.get("mode", "")))


## 轴的三大类归属：obs / struct / conserve / mixed（跨轴）/ special（无轴）。
static func kind_of(key: String) -> String:
	var ax := axes_of(key)
	if ax.is_empty():
		return KIND_SPECIAL
	var kinds := {}
	for a in ax:
		kinds[_kind_of_axis(a)] = true
	if kinds.size() > 1:
		return KIND_MIXED
	return str(kinds.keys()[0])


static func _kind_of_axis(a: String) -> String:
	if Axes.OBS.has(a):
		return KIND_OBS
	if Axes.STRUCT.has(a):
		return KIND_STRUCT
	return KIND_CONSERVE


## 是否错觉策展关卡（res://levels/iso_01.json / 以及 Mod 里的同名系列）。
static func is_illusion(key: String) -> bool:
	return Series.is_illusion(key)


## 错觉系列 id；不属于返回 ""。
static func series_of(key: String) -> String:
	return Series.series_of(key)


## 通关表（ProgressStore 的 levels 字典）→ 轴种类统计。
## 返回 {"ids": Array[String]（已通关关卡里出现过的轴，去重）, "obs": n, "struct": n, "cons": n, "all": n}
## 用途：成就系统按「通关了几种观测轴算子」判定（obs_kinds 等）。
static func axis_kinds_of_levels(levels: Dictionary) -> Dictionary:
	var ids: Array[String] = []
	for k in levels:
		var rec = levels[k]
		if not (rec is Dictionary) or not bool((rec as Dictionary).get("cleared", false)):
			continue
		for a in axes_of(str(k)):
			if not ids.has(a):
				ids.append(a)
	var out := {"ids": ids, "obs": 0, "struct": 0, "cons": 0, "all": ids.size()}
	for a in ids:
		var kind := _kind_of_axis(a)
		if kind == KIND_OBS:
			out["obs"] = int(out["obs"]) + 1
		elif kind == KIND_STRUCT:
			out["struct"] = int(out["struct"]) + 1
		else:
			out["cons"] = int(out["cons"]) + 1
	return out
