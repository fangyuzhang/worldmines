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

## v3.1：删除 SaveData 自带的 save()/load() 直写直读入口（SAVE_PATH 与 SaveCoordinator.MAIN
## 同路径双入口，绕过三段式写盘 / ended 标记 / 坏档隔离，误调即破坏 §10.10 契约）。
## 持久化唯一入口 = SaveCoordinator.save / load_save。


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
## 防御：字段类型漂移（手改/损坏 JSON）时安全回退，不让畸形条目引发下标越界崩溃。
func from_dict(d: Dictionary) -> void:
	var rev: Variant = d.get("revealed_cells", [])
	var flg: Variant = d.get("flagged_cells", [])
	var mns: Variant = d.get("mine_positions", [])
	revealed_cells = _int_pairs_to_arr(rev if rev is Array else [])
	flagged_cells = _int_pairs_to_arr(flg if flg is Array else [])
	timer_seconds = float(d.get("timer_seconds", 0.0))
	mine_positions = _int_pairs_to_arr(mns if mns is Array else [])
	seed_value = int(d.get("seed_value", 0))
	var md: Variant = d.get("metadata", {})
	metadata = md if md is Dictionary else {}


func _arr_to_int_pairs(arr: Array[Vector2i]) -> Array:
	var out: Array = []
	for v in arr:
		out.append([v.y, v.x])  # 存 [row, col]
	return out


func _int_pairs_to_arr(pairs: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for p in pairs:
		if not (p is Array) or p.size() != 2:
			continue  # 畸形条目跳过（此前 p[1] 直接下标会崩）
		out.append(Vector2i(p[1], p[0]))
	return out
