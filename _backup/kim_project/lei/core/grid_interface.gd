# grid_interface.gd —— 网格抽象契约（文档 §3.5）【人工锁死】
# 上层不感知底层存储。P0 唯一实现 = RectGrid（二维数组）。
# P3 追加 CustomGrid（邻接表来自 grid_def 数据）。
class_name GridInterface
extends RefCounted

## 返回格子对象（引用）。
func get_cell(pos: Vector2i) -> Cell:
	push_error("GridInterface.get_cell 必须在子类实现")
	return null


## 返回 pos 的全部邻格坐标（8 邻域，含边界检查）。
func get_neighbors(pos: Vector2i) -> Array[Vector2i]:
	push_error("GridInterface.get_neighbors 必须在子类实现")
	return []


## pos 是否在棋盘内（只读辅助）。
func in_board(pos: Vector2i) -> bool:
	return false


## 棋盘尺寸（只读辅助）。
func size() -> Vector2i:
	return Vector2i.ZERO
