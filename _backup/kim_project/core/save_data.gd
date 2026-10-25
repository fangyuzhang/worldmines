# save_data.gd —— SaveData 最小结构（文档 §4.2.1）
# P0 最小字段 + metadata 预留，后续只增不改结构。
class_name SaveData
extends RefCounted

var revealed_cells: Array[Vector2i] = []   # 已翻开格
var flagged_cells: Array[Vector2i] = []    # 标记格
var timer_seconds: float = 0.0             # 计时
var mine_positions: Array[Vector2i] = []   # 静态雷位（恢复与生成算法彻底解耦）
var seed_value: int = 0                    # 仅作元数据，恢复对局不依赖它
var metadata: Dictionary = {}              # 预留：P2 绘画层 / P3 来源标识/体检徽章

const SAVE_PATH := "user://save.json"


func to_dict() -> Dictionary:
	return {
		"revealed_cells": _arr_to_int_pairs(revealed_cells),
		"flagged_cells": _arr_to_int_pairs(flagged_cells),
		"timer_seconds": timer_seconds,
		"mine_positions": _arr_to_int_pairs(mine_positions),
		"seed_value": seed_value,
		"metadata": metadata,
	}


## 从字典恢复。雷位/翻开/标记/计时/游戏状态精确恢复。
func from_dict(d: Dictionary) -> void:
	revealed_cells = _int_pairs_to_arr(d.get("revealed_cells", []))
	flagged_cells = _int_pairs_to_arr(d.get("flagged_cells", []))
	timer_seconds = d.get("timer_seconds", 0.0)
	mine_positions = _int_pairs_to_arr(d.get("mine_positions", []))
	seed_value = d.get("seed_value", 0)
	metadata = d.get("metadata", {})


func save() -> bool:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict()))
	f.close()
	return true


func load() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		return false
	var text := FileAccess.get_file_as_string(SAVE_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		return false
	from_dict(parsed)
	return true


func _arr_to_int_pairs(arr: Array[Vector2i]) -> Array:
	var out: Array = []
	for v in arr:
		out.append([v.y, v.x])  # 存 [row, col]
	return out


func _int_pairs_to_arr(pairs: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for p in pairs:
		out.append(Vector2i(p[1], p[0]))
	return out
