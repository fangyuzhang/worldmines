class_name VariantBase
extends RefCounted
## 变体基类 —— 所有扫雷变体的统一接口契约。
##
## 【如何新增一个变体】= 在 res://scripts/variants/ 下新建一个 .gd 文件，
## 继承 VariantBase 并覆写下列钩子，注册表会自动扫描并注册它。
## 变体天然支持混合对局：A 类叠「与」，B 类叠「显示」。

enum Category { GENERATION, NUMBER_RULE }

# ---- 元数据（每个变体必须填写）----
var id: String = ""                # 唯一代号，如 "MX"、"4N"
var display_name: String = ""      # 展示名
var category: Category = Category.NUMBER_RULE
var difficulty: int = 1            # 1~5 星
var compat_score: float = 8.0      # 基础兼容性分 0~10（GDD §4.2.1）
var weight: String = "light"       # light / heavy（生成算法复杂度提示）

## 与其他变体的冲突惩罚表：{ 对方 id: 惩罚分 }
## 强矛盾给大惩罚（如镜像+行首尾 → 10），一般冲突给 1~3（GDD §4.2.2）
func conflict_table() -> Dictionary:
	return {}

# ============ A 类钩子：生成层（雷怎么放） ============
## 验证当前雷阵是否满足本变体约束。满足返回 true。
## 经典实现：无额外约束，恒 true。
func check_constraints(_board: Board) -> bool:
	return true

## A 类专属：首次点击安全重排后需要重新验证约束。
## 返回 true 表示该变体有"特殊重排需求"，交给生成器决定是否需要重新生成整个棋盘。
func needs_regenerate_on_first_click() -> bool:
	return false

# ============ B 类钩子：数字规则层（数字怎么算） ============
## 计算格子 (r, c) 上显示的线索。返回一个线索对象数组。
## 经典：返回一条线索 = 8 邻雷数。多个 B 类变体可叠加，各自返回自己的线索。
func compute_clues(_board: Board, _r: int, _c: int) -> Array[VariantClue]:
	return []

## 该格子是否为"自动展开点"（即经典扫雷的数字 0，触发洪水填充）。
func is_flood_seed(_board: Board, _r: int, _c: int) -> bool:
	return false

## 已揭开格子的显示文本（UI 层用于渲染该格子的线索）。
func cell_display(_board: Board, _r: int, _c: int) -> String:
	return ""

# ---- 工具方法（子类可复用） ----
func _is_mine(board: Board, r: int, c: int) -> bool:
	if not board.in_bounds(r, c):
		return false
	return board.is_mine(r, c)
