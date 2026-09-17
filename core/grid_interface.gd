# grid_interface.gd —— 网格抽象契约（文档 §3.5）【人工锁死】
# 上层不感知底层存储。P0 唯一实现 = RectGrid（二维数组）。
# P3 追加 CustomGrid（邻接表来自 grid_def 数据）。
class_name GridInterface
extends RefCounted

## 返回格子对象（引用）。
func get_cell(_pos: Vector2i) -> Cell:
	push_error("GridInterface.get_cell 必须在子类实现")
	return null


## 返回 pos 的全部邻格坐标（8 邻域，含边界检查）。
func get_neighbors(_pos: Vector2i) -> Array[Vector2i]:
	push_error("GridInterface.get_neighbors 必须在子类实现")
	return []


## pos 是否在棋盘内（只读辅助）。
func in_board(_pos: Vector2i) -> bool:
	return false


## 棋盘尺寸（只读辅助）。
func size() -> Vector2i:
	return Vector2i.ZERO


## 返回棋盘内所有格子坐标（遍历用）。
## 矩形 = 全坐标；异形/邻接表 = 稀疏坐标集。上层遍历必须用本方法，禁止双层 for r/c 假设连续坐标。
func all_positions() -> Array[Vector2i]:
	return []


## 格子总数（不含异形洞格）。O(1)。
func cell_count() -> int:
	return 0
