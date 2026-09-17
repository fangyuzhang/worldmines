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


## 关卡库关卡（正式量产内容）的路径规则：user://lib_play/<mode>_<size>_<tier>_<idx>.json
## 与生成关的区别：多了档位维度（同一变体×尺寸下四个难度各自成集），见 ui/level_library.gd。
static func lib_path(mode_id: String, size: int, tier: String, idx: int) -> String:
	return "%s/%s_%d_%s_%d.json" % [LevelLibrary.PLAY_DIR, mode_id, size, tier, idx]


## 关卡库关卡的进度键（与生成关键空间隔离：lib:// 与 gen:// 前缀不同）。
static func lib_key(mode_id: String, size: int, tier: String, idx: int) -> String:
	return "lib://%s/%d/%s/%d" % [mode_id, size, tier, idx]


## 关卡路径 → 进度键。**写进度与读进度必须都经过这里**：
## 生成关取序列键（gen://<mode>/<size>/<idx>），非生成关（res://levels/*.json 手工关、
## 测试关卡）没有序列概念 → 原样返回路径。
##
## 为什么要有这个函数：写侧原先直接拿 level_path（user://gen_levels/*.json）当键，
## 而读侧（选关页打勾/解锁、has_next）一律查序列键——写的和读的永远不是同一个键，
## 表现就是「通关了不打勾、下一关永远锁着、『下一关』按钮永不出现」。
static func progress_key(path: String) -> String:
	var p := parse_path(path)
	if p.is_empty():
		return path
	if bool(p.get("lib", false)):
		return lib_key(str(p["mode"]), int(p["size"]), str(p["tier"]), int(p["idx"]))
	return level_key(str(p["mode"]), int(p["size"]), int(p["idx"]))


## 解析关卡路径 → {"mode","size","idx"[,"tier","lib"]}；非序列关（手工关/测试关）返回空字典。
## 两种方案（按文件名从右往左剥，先试库方案）：
##   关卡库：<mode>_<size>_<tier>_<idx>（tier ∈ 四档 id）
##   生成关：<mode>_<size>_<idx>
static func parse_path(path: String) -> Dictionary:
	var base := path.get_file().get_basename()
	var parts := base.split("_")
	# 关卡库方案：倒三段必须是 idx(int) / tier(四档 id) / size(int)——模式名里的下划线不受影响
	if parts.size() >= 4:
		var l_idx := parts[parts.size() - 1]
		var l_tier := parts[parts.size() - 2]
		var l_size := parts[parts.size() - 3]
		if l_idx.is_valid_int() and l_size.is_valid_int() and LevelLibrary.TIER_ORDER.has(l_tier):
			var l_mode := "_".join(parts.slice(0, parts.size() - 3))
			if l_mode != "":
				return {"mode": l_mode, "size": int(l_size), "tier": l_tier,
						"idx": int(l_idx), "lib": true}
	if parts.size() < 3:
		return {}
	var idx := parts[parts.size() - 1]
	var size := parts[parts.size() - 2]
	if not idx.is_valid_int() or not size.is_valid_int():
		return {}
	var mode_id := "_".join(parts.slice(0, parts.size() - 2))
	if mode_id == "":
		return {}
	return {"mode": mode_id, "size": int(size), "idx": int(idx), "lib": false}


## 同一「变体 × 尺寸」序列里的下一关路径；已是最后一关 / 非生成关 → ""。
static func next_level_path(path: String) -> String:
	var p := parse_path(path)
	if p.is_empty():
		return ""
	var next_idx: int = int(p["idx"]) + 1
	if next_idx >= LEVELS_PER_SET:
		return ""
	return level_path(str(p["mode"]), int(p["size"]), next_idx)


## 从某关出发的「下一关」位置（**跨尺寸**）：同尺寸内 idx+1；本尺寸打完则接
## 下一个尺寸的第 1 关（5×5 → 6×6 → … → 9×9）；已是最大尺寸的末关 → 空字典。
##
## 为什么跨尺寸：每套只有 LEVELS_PER_SET 关，末关再没有「下一关」的话，
## 玩家打完 5×5 三关就断了线——而 SIZES 本来就是一条难度阶梯，同变体沿楼梯继续最自然。
## 这里**不判可行性**（那需要 CP-SAT，会让本模块失去「无依赖静态工具」的性质）：
## 目标尺寸若对该变体不可行，选关页的 _refresh_popup 会自动切到最近可行尺寸。
static func advance(path: String) -> Dictionary:
	var p := parse_path(path)
	if p.is_empty():
		return {}
	if bool(p.get("lib", false)):
		return _lib_advance(str(p["mode"]), int(p["size"]), str(p["tier"]), int(p["idx"]))
	var mode := str(p["mode"])
	var size := int(p["size"])
	var idx := int(p["idx"])
	if idx + 1 < LEVELS_PER_SET:
		return {"mode": mode, "size": size, "idx": idx + 1}
	var si: int = SIZES.find(size)
	if si < 0 or si + 1 >= SIZES.size():
		return {}
	return {"mode": mode, "size": int(SIZES[si + 1]), "idx": 0}


## 下一关文件路径（跨尺寸）；没有则 ""。
static func advance_path(path: String) -> String:
	var a := advance(path)
	if a.is_empty():
		return ""
	if bool(a.get("lib", false)):
		# 库关卡按需物化（写一份到 user://lib_play），对局链路照常按路径工作
		return LevelLibrary.materialize(str(a["mode"]), int(a["size"]),
				str(a["tier"]), int(a["idx"]))
	return level_path(str(a["mode"]), int(a["size"]), int(a["idx"]))


## 关卡库序列的下一关：同档 idx+1 → 本尺寸下一个有内容的档 → 下一个有内容的尺寸（首个有内容的档）。
## 与生成关同款「跨尺寸阶梯」哲学：库里有多少就走到多少，走完返回空（终局页据此收掉「下一关」）。
static func _lib_advance(mode: String, size: int, tier: String, idx: int) -> Dictionary:
	if idx + 1 < LevelLibrary.count(mode, size, tier):
		return {"mode": mode, "size": size, "tier": tier, "idx": idx + 1, "lib": true}
	var ti: int = LevelLibrary.TIER_ORDER.find(tier)
	for j in range(ti + 1, LevelLibrary.TIER_ORDER.size()):
		var t2: String = LevelLibrary.TIER_ORDER[j]
		if LevelLibrary.count(mode, size, t2) > 0:
			return {"mode": mode, "size": size, "tier": t2, "idx": 0, "lib": true}
	var si: int = SIZES.find(size)
	for k in range(si + 1, SIZES.size()):
		var s2: int = SIZES[k]
		for t3 in LevelLibrary.TIER_ORDER:
			if LevelLibrary.count(mode, s2, str(t3)) > 0:
				return {"mode": mode, "size": s2, "tier": str(t3), "idx": 0, "lib": true}
	return {}


## 该关卡的下一关是否已解锁（依赖 ProgressStore：需**当前关**已通关）。
## 非生成关（如 res://levels/ 手工关）没有序列概念 → false。
static func has_next(path: String) -> bool:
	if advance(path).is_empty():
		return false
	return ProgressStore.is_cleared(progress_key(path))


## 失败终局「跳过本关」是否可用：只要**存在下一关**即可。
## 与 has_next 的区别在前提不同：has_next 用于胜利之后（要求当前关已通关），
## 而跳过发生在失败终局——当前关必然未通关，若沿用 has_next 就永远不会显示。
static func has_skip_target(path: String) -> bool:
	return not advance(path).is_empty()


## 跳过当前关：记为 skipped（不算通关），只用于解锁下一关。
## 返回下一关路径（无下一关 → ""，调用方据此不显示该入口）。
static func skip_to_next(path: String) -> String:
	var next_path := advance_path(path)
	if next_path == "":
		return ""
	ProgressStore.record_skip(progress_key(path))   # 写序列键，与读取侧同一约定
	return next_path


# ============ 终局 → 选关页 的焦点交接 ============
#
# 终局页不知道下一关怎么生成（那是选关页的职责），也不该知道。
# 交接一个「翻到哪一套」的意图即可：选关页 _ready 时领取并自动展开对应弹窗，
# 玩家看到的就是「下一关已被选中」，点一下即开局。

static var _pending_focus: Dictionary = {}


## 交接「翻到哪一套」的意图。
## auto_start = true 时要求选关页领到意图后**直接开局**（生成仍归它管），
## 玩家感知是「点『下一关』/『跳过本关』就直接进下一关」，而不是回到选关页再点一次。
## tier：关卡库关卡的档位（2026-09-18 补）——**下一关跨档时必须带上**，否则选关页
## 会落回默认档（入门）并自动开局错关。生成关传空串即可（无档位概念）。
static func request_focus(mode_id: String, size: int, auto_start := false, tier := "") -> void:
	_pending_focus = {"mode": mode_id, "size": size, "auto_start": auto_start, "tier": tier}


## 领取并清空（一次性意图）。无待处理请求返回空字典。
static func take_focus() -> Dictionary:
	var f := _pending_focus
	_pending_focus = {}
	return f
