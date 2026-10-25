# clue_def_parser.gd —— 线索定义解析（文档 §3.5/§4.2）
# P0 只解析经典规则（8 邻求和）。预留 topology:"custom" 分支 → 记日志跳过（P3 实装）。
class_name ClueDefParser
extends RefCounted

const CLASSIC_CLUE_DEF := {
	"defName": "Clue_Classic",
	"type": "clue",
	"window": "n8",
	"aggregate": "sum",
	"empty_value": 0,
	"value_range": [0, 8],
	"minimal_clue_value": 0,
}


## 解析 clue_def。P0 仅支持经典 n8 求和；custom 拓扑记录日志并跳过。
func parse(def: Dictionary) -> Dictionary:
	var topology: String = def.get("topology", "rect")
	if topology == "custom":
		push_warning("ClueDefParser: topology=custom 已跳过（P3 实装）")
		return {}
	var window: String = def.get("window", "n8")
	var aggregate: String = def.get("aggregate", "sum")
	if window != "n8" or aggregate != "sum":
		push_warning("ClueDefParser: P0 仅支持 window=n8 + aggregate=sum，收到 %s/%s，已跳过" % [window, aggregate])
		return {}
	return def


## 返回内置经典规则定义。
func get_classic_def() -> Dictionary:
	return CLASSIC_CLUE_DEF.duplicate(true)
