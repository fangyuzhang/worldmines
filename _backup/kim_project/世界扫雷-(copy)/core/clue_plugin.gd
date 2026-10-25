# clue_plugin.gd —— 线索函数插件基类（文档 23 号 §3.1 ① / 21 号 R09/R28）
# 线索函数本质 = 纯函数：给定雷分布(mine_set)，返回线索值。
# 契约（子类必须实现）：get_clue_id / value_range / compute
# 可选：clue_neighbors / is_zero_safe / describe / z3_encode
class_name CluePlugin
extends RefCounted


## 线索 id（唯一）。子类实现。
func get_clue_id() -> StringName:
	return &""


## PluginManager 统一注册句柄（勿覆盖；映射到线索 id）。
func get_id() -> StringName:
	return get_clue_id()


## 值域 [min, max]（动态，禁硬编码，R09/K12）。子类实现。
func value_range(_grid_size: Vector2i) -> Vector2i:
	return Vector2i(0, 8)


## 计算线索值。子类实现。
## mine_set: Dictionary（Vector2i -> true），答案板雷位；返回 Variant（int / Array / String）。
func compute(_mine_set: Dictionary, _pos: Vector2i, _grid_size: Vector2i) -> Variant:
	return 0


## 线索邻域（默认 8 邻）。子类可覆盖（K28：与拓扑邻接 get_neighbors 解耦）。
func clue_neighbors(pos: Vector2i, grid_size: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d in ClueEngine.ring_dirs():
		var p := pos + d
		if p.x >= 0 and p.x < grid_size.x and p.y >= 0 and p.y < grid_size.y:
			out.append(p)
	return out


## 值 0 是否语义上蕴含邻域全安全（求解器能否用 0 推全安全；K13）。默认 true。
func is_zero_safe() -> bool:
	return true


## 规则说明（自动进规则图鉴）。子类可选覆盖。
func describe() -> Dictionary:
	return {"name": get_clue_id(), "rule_text": ""}
