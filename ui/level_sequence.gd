# level_sequence.gd —— 生成关卡的「序列」事实来源
#
# 背景：这些常量与路径规则原先散落在 ui/level_select.gd 内部，
# 导致「终局之后下一关是什么」这个问题只能由选关页回答（而 game_over 拿不到它）。
# 抽成无依赖的静态工具后：选关页负责生成，终局页负责导航，两者共享同一套约定。
#
# 命名约定：<mode_id>_<size>_<idx>.json（idx 从 0 开始，每套 LEVELS_PER_SET 关）。
# 进度键约定：gen://<mode_id>/<size>/<idx>（必须与 ui/level_select._level_key 一致）。
class_name LevelSequence
extends RefCounted

const GEN_DIR := "user://gen_levels"
const LEVELS_PER_SET := 3
const SIZES: Array = [5, 6, 7, 8, 9]
## 每尺寸雷数（约 40% 密度：10/25=40%、14/36=38.9%、20/49=40.8%、26/64=40.6%、32/81=39.5%）。
const MINE_COUNTS := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


## 每尺寸固定雷数；未列出的尺寸回退 40%。
static func mine_count(size: int) -> int:
	return maxi(1, int(MINE_COUNTS.get(size, int(float(size * size) * 0.4))))


static func level_path(mode_id: String, size: int, idx: int) -> String:
	return "%s/%s_%d_%d.json" % [GEN_DIR, mode_id, size, idx]


## 进度存储键（与 ProgressStore 记录口径一致）。
static func level_key(mode_id: String, size: int, idx: int) -> String:
	return "gen://%s/%d/%d" % [mode_id, size, idx]


## 解析 gen_levels 路径 → {"mode": String, "size": int, "idx": int}；非生成关返回空字典。
static func parse_path(path: String) -> Dictionary:
	var base := path.get_file().get_basename()
	var parts := base.split("_")
	if parts.size() < 3:
		return {}
	var idx := parts[parts.size() - 1]
	var size := parts[parts.size() - 2]
	if not idx.is_valid_int() or not size.is_valid_int():
		return {}
	var mode_id := "_".join(parts.slice(0, parts.size() - 2))
	if mode_id == "":
		return {}
	return {"mode": mode_id, "size": int(size), "idx": int(idx)}


## 同一「变体 × 尺寸」序列里的下一关路径；已是最后一关 / 非生成关 → ""。
static func next_level_path(path: String) -> String:
	var p := parse_path(path)
	if p.is_empty():
		return ""
	var next_idx: int = int(p["idx"]) + 1
	if next_idx >= LEVELS_PER_SET:
		return ""
	return level_path(str(p["mode"]), int(p["size"]), next_idx)


## 该关卡的下一关是否已解锁（依赖 ProgressStore：需前一关已通关）。
## 非生成关（如 res://levels/ 手工关）没有序列概念 → false。
static func has_next(path: String) -> bool:
	var next_path := next_level_path(path)
	if next_path == "":
		return false
	var p := parse_path(next_path)
	return ProgressStore.is_cleared(level_key(str(p["mode"]), int(p["size"]), int(p["idx"]) - 1))


# ============ 终局 → 选关页 的焦点交接 ============
#
# 终局页不知道下一关怎么生成（那是选关页的职责），也不该知道。
# 交接一个「翻到哪一套」的意图即可：选关页 _ready 时领取并自动展开对应弹窗，
# 玩家看到的就是「下一关已被选中」，点一下即开局。

static var _pending_focus: Dictionary = {}


static func request_focus(mode_id: String, size: int) -> void:
	_pending_focus = {"mode": mode_id, "size": size}


## 领取并清空（一次性意图）。无待处理请求返回空字典。
static func take_focus() -> Dictionary:
	var f := _pending_focus
	_pending_focus = {}
	return f
