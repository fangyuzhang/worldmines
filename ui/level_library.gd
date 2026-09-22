# level_library.gd —— 关卡库（量产产物 → 游戏可玩内容）
#
# 背景（2026-09-17）：选关页原先只有「按种子现生成」一条路（user://gen_levels），
# 而量产入库的正式关卡（0000 关级）没有任何入口——游戏里找不到。
# 本模块让「正式关卡」成为一等公民：
#
#   数据：levels_lib/catalog.json            —— 索引 {mode: {size: {tier: count}}}
#         levels_lib/<mode>/<size>/<tier>.json —— 一个关卡集（levels 数组，按难度升序）
#   读取：catalog() / counts() / levels() / get_level() / materialize()
#
# 与生成关的分工：库里有的（mode,size,tier）→ 用正式关卡；库里没有 → 退回按种子现生成
# （老流程原样保留，选关页自动二选一）。这样「新算子已量产」的那一刻内容就上线，
# 没量产的组合仍然可玩，不需要二选一式的开关。
#
# 为什么 materialize（写一份到 user://）：对局链路（GameSession/SaveCoordinator/LevelLoader）
# 都按「关卡文件路径」工作，且存档要记住 level_path。把库里的盘按需落成一个文件，
# 就能完整复用整条既有链路（含续档/进度键），无需给 Board 造第二条加载路径。
class_name LevelLibrary
extends RefCounted

const DIR := "res://levels_lib"
const CATALOG_PATH := DIR + "/catalog.json"
## 关卡库落盘缓存目录（materialize 的产物；一次性写、后续复用）。
const PLAY_DIR := "user://lib_play"
## 档位展示序（v4.1 三档，随 Difficulty.PEAK_WINDOWS 的键序；显式列出以免依赖字典序）。
## test_single_source_of_truth 钉住两者同步——改档位名单时两处必须一起改。
const TIER_ORDER: Array = ["easy", "normal", "hard"]

static var _catalog: Dictionary = {}
static var _catalog_loaded := false
static var _sets: Dictionary = {}          # "mode|size|tier" -> Array[Dictionary]


## 索引 {mode: {size_str: {tier: count}}}；库不存在/为空 → {}。
static func catalog() -> Dictionary:
	if _catalog_loaded:
		return _catalog
	_catalog_loaded = true
	if not FileAccess.file_exists(CATALOG_PATH):
		_catalog = {}
		return _catalog
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
	if parsed is Dictionary:
		_catalog = (parsed as Dictionary).get("catalog", {})
	return _catalog


## 库是否非空（选关页据此决定是否显示「难度」列）。
static func is_empty() -> bool:
	return catalog().is_empty()


## 该（变体 × 尺寸）的档位 → 关数；无内容返回 {}。
static func counts(mode: String, size: int) -> Dictionary:
	var c := catalog()
	if not c.has(mode):
		return {}
	var by_size: Dictionary = c[mode]
	if not by_size.has(str(size)):
		return {}
	return by_size[str(size)]


## 该（变体 × 尺寸）是否有任何正式关卡。
static func has_any(mode: String, size: int) -> bool:
	return not counts(mode, size).is_empty()


## 该（变体 × 尺寸 × 档）的关数（0 = 无内容）。
static func count(mode: String, size: int, tier: String) -> int:
	return int(counts(mode, size).get(tier, 0))


## 该（变体 × 尺寸）有内容的档位（按 TIER_ORDER 排序）。
static func tiers_present(mode: String, size: int) -> Array:
	var c := counts(mode, size)
	var out: Array = []
	for t in TIER_ORDER:
		if int(c.get(t, 0)) > 0:
			out.append(t)
	return out


## 该变体在全部尺寸下的关数合计（选关页卡片进度条 / 概览用）。
static func total(mode: String) -> int:
	var n := 0
	for size in SIZES:
		var c := counts(mode, size)
		for t in c:
			n += int(c[t])
	return n


const SIZES: Array = [5, 6, 7, 8, 9]


## 一个关卡集（levels 数组，按难度升序）。不存在 → 空数组。
static func levels(mode: String, size: int, tier: String) -> Array:
	var key := "%s|%d|%s" % [mode, size, tier]
	if _sets.has(key):
		return _sets[key]
	var path := "%s/%s/%d/%s.json" % [DIR, mode, size, tier]
	if not FileAccess.file_exists(path):
		_sets[key] = []
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var arr: Array = []
	if parsed is Dictionary:
		arr = (parsed as Dictionary).get("levels", [])
	# v4.1 严格难度梯度（玩家可见前的最后一道闸）：集内关卡必须与集档位同窗。
	# 数据侧已有三道（生成门禁 / retier 重标 / 入库校验），这里兜的是历史或外部产物
	# —— 宁可不显示，也不让「噩梦」档里冒出普通盘（那正是玩家一眼看穿的假梯度）。
	var conforming := filter_conforming(arr, tier)
	if conforming.size() != arr.size():
		push_warning("[LevelLibrary] %s/%d/%s：%d 关档位与峰值不符已隐去（建议重导入该集）" % [
			mode, size, tier, arr.size() - conforming.size()])
	_sets[key] = conforming
	return conforming


## v4.1 严格梯度过滤器：只保留「峰值窗口 == 集档位」的关卡（纯函数，可单测）。
static func filter_conforming(arr: Array, tier: String) -> Array:
	var out: Array = []
	for lv in arr:
		if lv is Dictionary \
				and Difficulty.tier_of_profile((lv as Dictionary).get("difficulty_profile", {})) == tier:
			out.append(lv)
	return out


## 取一关（越界 → 空字典）。
static func get_level(mode: String, size: int, tier: String, idx: int) -> Dictionary:
	var arr := levels(mode, size, tier)
	if idx < 0 or idx >= arr.size():
		return {}
	var lv: Variant = arr[idx]
	return lv if lv is Dictionary else {}


## 关卡落盘路径（materialize 的确定性目标）。
static func play_path(mode: String, size: int, tier: String, idx: int) -> String:
	return "%s/%s_%d_%s_%d.json" % [PLAY_DIR, mode, size, tier, idx]


## 把库里的一关落成「可对局的文件」，返回路径（失败 → ""）。
## 对局链路按文件路径工作（含存档记住 level_path），故这里做一次物化。
##
## 缓存策略（2026-09-19 改）：按**源集文件 mtime** 判断是否需要重写 ——
## 源集比物化文件新（或源 mtime 读不到）才重写。库再导入后集文件 mtime 变新 → 照常更新，
## 原设计意图（"永远与库一致"）不变；而同一关反复进入不再每次写盘
## （原实现每次都写，桌面 0.5ms 尚可，移动端单次写盘 10~50ms 级，是进关卡顿的来源之一）。
## 读不到源 mtime 时保守重写：宁可多写一次，也不能让玩家玩到过期数据。
static func materialize(mode: String, size: int, tier: String, idx: int) -> String:
	var path := play_path(mode, size, tier, idx)
	var lv := get_level(mode, size, tier, idx)
	if lv.is_empty():
		return ""
	var src_mtime := FileAccess.get_modified_time("%s/%s/%d/%s.json" % [DIR, mode, size, tier])
	# 严格大于才跳过：mtime 精度通常只有秒，若集文件与物化文件在同一秒产生，
	# `>=` 会把「集随后又被更新（同一秒内）」也判成最新 → 玩家玩到旧盘。
	# 宁可多写一次，也不能出现过期数据（原「每次都重写」的意图在此保留）。
	if src_mtime > 0 and FileAccess.file_exists(path) \
			and FileAccess.get_modified_time(path) > src_mtime \
			and _materialized_ok(path, lv):
		return path
	if DirAccess.make_dir_recursive_absolute(PLAY_DIR) != OK:
		return ""
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(lv, "  "))
	f.close()
	return path


## 物化文件可用性校验（审计修复 2026-09-21）：命中缓存前必须**验内容**，不能只比 mtime——
## 首次物化时崩溃/断电/磁盘满会留下半份 JSON，而此后 mtime 永远"更新"，该关就永久不可玩
## （点开始游戏只会 toast「关卡加载失败」，旧存档也恢复不了），只有手删 user://lib_play 才自愈。
## 校验失败 → false ⇒ 走下面的重写路径（原子替换）。字段校验取"缺了就会崩/玩错盘"的最小集。
static func _materialized_ok(path: String, expect: Dictionary) -> bool:
	if not FileAccess.file_exists(path):
		return false
	# 用 JSON.new().parse() 而非 JSON.parse_string()：后者对坏内容会触发 Godot 内部
	# engine error（`Condition "error != Error::OK"`）—— 而本函数恰恰是为「坏文件」而写的，
	# 每次命中坏档都会在控制台刷错误、CI 也会把它记成 Unexpected Errors。
	var j := JSON.new()
	if j.parse(FileAccess.get_file_as_string(path)) != OK:
		return false
	var parsed: Variant = j.data
	if not (parsed is Dictionary):
		return false
	var d: Dictionary = parsed
	if not d.has("mines") or not d.has("size") or not d.has("total_mines"):
		return false
	if int(d.get("total_mines", -1)) != int(expect.get("total_mines", -2)):
		return false
	# 拓扑键必须与源关卡一致（形状关丢了 topology 会被当成矩形盘——玩错盘）
	if expect.has("topology") != d.has("topology"):
		return false
	return true


## 某关的难度值（读不到 → -1.0）。tile 提示等 UI 直接取值，
## 不要从 level_label 反解析（那是展示格式，会变）。
static func level_difficulty(mode: String, size: int, tier: String, idx: int) -> float:
	var lv := get_level(mode, size, tier, idx)
	if lv.is_empty():
		return -1.0
	var prof: Dictionary = lv.get("difficulty_profile", {})
	return float(prof.get("difficulty", -1.0))


## 某关峰值深度（读不到 → -1）。
static func level_peak(mode: String, size: int, tier: String, idx: int) -> int:
	var lv := get_level(mode, size, tier, idx)
	if lv.is_empty():
		return -1
	return int((lv.get("difficulty_profile", {}) as Dictionary).get("max_complexity", -1))


## 关卡短标签（tile 用）：序号 + 深度峰值（玩家一眼看出要同时把握几条线索）。
static func level_label(mode: String, size: int, tier: String, idx: int) -> String:
	var peak := level_peak(mode, size, tier, idx)
	if peak < 0:
		return str(idx + 1)
	return "%d\n深度%d" % [idx + 1, peak]
