# domino_model.gd —— 骨牌划分（Domino Tiling）纯逻辑模型。
#
# 文档「五、变体规则配置 · 变体专用工具」：
#   骨牌划分编辑器（拖拽画骨牌，**实时验证全覆盖 / 无重叠，不完整阻止保存**）。
# 本轮只做**纯逻辑模型**：谁和谁组成一张骨牌、划分是否恰好全覆盖、以及序列化；
# 场景树 / UI / 生成器接线是后续切片（见文件末「集成点」）。
#
# 【与全仓同口径，禁止包围盒】
#   · 盘内格一律走 `GridInterface.all_positions()`；是否在盘内走 `in_board()`；
#     相邻判定走 `get_neighbors()`（异形盘/环绕盘上"坐标差为 1"并不等于相邻）。
#     **绝不**用 rows×cols 双层循环假设连续坐标。
#   · 复合格见只读的 `core/mega_cell.gd`：本模型只问它 `owner_of(pos)` / `size_of(id)`，
#     不复制它的合并/拆分/邻接逻辑。
#
# 【复合格 × 变体：未定义组合必须进兼容门禁（文档明确要求）】
#   · 骨牌**不允许跨复合格** —— 两格必须同属一个复合格（或都不属于任何复合格）；
#     归属不同 ⇒ `place` 明确拒绝（`cross_mega`），`validate` 明确 block；
#   · **单格复合格无法配对** —— 只含 1 格的复合格里那一格永远找不到同格伙伴 ⇒ 明确拒绝
#     （`mega_singleton`）/ block，**不静默放过**；
#   · 染色按复合格中心点判定（`MegaCell.centroid_of`）——本模型不碰染色。
#
# 【不完整 ⇒ block，且必须列出坐标】`validate()` 的 `uncovered` 逐格给出坐标（不是只给个数），
# `overlaps` 逐格给出被重复占用的格与其骨牌 id；`ok=false` / `level="block"`，对应
# 文档「不完整阻止保存」。
#
# 【序列化】`to_dict()/from_dict()` 带 `version`（更高版本 ⇒ 拒收），骨牌按**稳定顺序**输出
#（按骨牌内规范格序排序，再按 id 兜底），保证与拖拽顺序无关地逐字节 round-trip。
class_name DominoModel
extends RefCounted

## 序列化版本。**只增不改**：新增字段可以；改语义必须递增（`from_dict` 拒收更高版本）。
const VERSION := 1

## 一张骨牌固定 2 格（当前变体只支持 2×1 骨牌；多米诺之外的多格"骨牌"是后续切片）。
const DOMINO_SIZE := 2

const LEVEL_OK := "ok"
const LEVEL_WARN := "warn"
const LEVEL_BLOCK := "block"

## id → Array[Vector2i]（规范序：骨牌内 2 格按 (x, y) 字典序）。id 稳定、不回收。
var _dominoes: Array[Dictionary] = []
## Vector2i → domino id（0 / 缺省 = 该格尚未被任何骨牌占用）。
var _owner: Dictionary = {}
## 下一个待分配 id（从 1 起）。
var _next_id: int = 1


# ==================== 放置 / 擦除 ====================

## 把两格组成一张骨牌。
##
## `opts`：
##   grid —— **必需**，`GridInterface`（判断 in_board / 相邻的唯一口径，绝不按坐标差猜）。
##   mega —— 可选，`MegaCell` 实例（复合格归属门禁）；也接受 `doc` 键（其值同上，便于
##           后续把 EditorDoc 整个传进来）。
##
## 成功：`{"ok": true, "id": int, "cells": Array[Vector2i]}`。
## 拒绝：`{"ok": false, "code": String, "reason": String}`，**无副作用**。
## code ∈ {"same_cell","no_grid","out_of_board","not_adjacent","occupied","cross_mega","mega_singleton"}。
func place(a: Vector2i, b: Vector2i, opts: Dictionary = {}) -> Dictionary:
	if a == b:
		return _reject("same_cell",
			"两格是同一格 (%d,%d)：一张骨牌必须由 2 个**不同的相邻格**组成" % [a.x, a.y])
	var grid: Variant = opts.get("grid", null)
	if not _is_grid(grid):
		return _reject("no_grid",
			"未提供棋盘：place 需要 opts.grid（GridInterface），才能按**邻接表**判断两格是否相邻"
			+ "（不接受包围盒/坐标差估算）")
	if not bool(grid.call("in_board", a)):
		return _reject("out_of_board", "格 (%d,%d) 不在盘内" % [a.x, a.y])
	if not bool(grid.call("in_board", b)):
		return _reject("out_of_board", "格 (%d,%d) 不在盘内" % [b.x, b.y])
	if not _neighbors_of(grid, a).has(b):
		return _reject("not_adjacent",
			"(%d,%d) 与 (%d,%d) 不相邻：骨牌两格必须相邻（按棋盘邻接表判定；异形/环绕盘上坐标差 1 也不一定相邻）"
			% [a.x, a.y, b.x, b.y])

	var occ_a := int(_owner.get(a, 0))
	var occ_b := int(_owner.get(b, 0))
	if occ_a != 0 or occ_b != 0:
		return _reject("occupied", _occupied_text(a, occ_a, b, occ_b))

	# 复合格门禁：两格必须同属一个复合格（或都不属于任何复合格）。
	var mega: Variant = _resolve_mega(opts.get("mega", opts.get("doc", null)))
	if mega != null:
		var ma := _mega_owner_of(mega, a)
		var mb := _mega_owner_of(mega, b)
		if ma != mb:
			return _mega_reject(mega, a, ma, b, mb)

	var cells := _canon_pair([a, b])
	var id := _next_id
	_next_id += 1
	_dominoes.append({"id": id, "cells": cells})
	_owner[a] = id
	_owner[b] = id
	return {"ok": true, "id": id, "cells": cells.duplicate()}


## 删除一张骨牌（释放其占用的格）。未知 id ⇒ `{ok:false, code:"unknown", reason}`。
func erase(domino_id: int) -> Dictionary:
	var idx := _index_of(domino_id)
	if idx < 0:
		return _reject("unknown", "骨牌 #%d 不存在，无法删除" % domino_id)
	var d: Dictionary = _dominoes[idx]
	_free(d["cells"])
	_dominoes.remove_at(idx)
	return {"ok": true, "id": domino_id, "cells": (d["cells"] as Array).duplicate()}


## 清空全部骨牌（含占用表；id 不回收 ⇒ 旧引用不会指向新骨牌）。
func clear_all() -> void:
	_dominoes.clear()
	_owner.clear()


# ==================== 查询 ====================

func count() -> int:
	return _dominoes.size()


## 全部骨牌 id（升序）。
func domino_ids() -> Array[int]:
	var out: Array[int] = []
	for d in _dominoes:
		out.append(int(d["id"]))
	out.sort()
	return out


## 某格归属的骨牌 id；0 = 尚未被任何骨牌占用。
func owner_of(pos: Vector2i) -> int:
	return int(_owner.get(pos, 0))


func has(domino_id: int) -> bool:
	return _index_of(domino_id) >= 0


## 单张骨牌记录 `{id, cells}` 的副本；不存在 ⇒ `{}`。
func find_domino(domino_id: int) -> Dictionary:
	var idx := _index_of(domino_id)
	if idx < 0:
		return {}
	var d: Dictionary = _dominoes[idx]
	return {"id": int(d["id"]), "cells": (d["cells"] as Array).duplicate()}


## 全部骨牌记录（**稳定顺序**：按骨牌内规范格序排序，id 兜底）。返回深副本，调用方改不到内部。
func dominoes() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d in _sorted_records():
		out.append({"id": int(d["id"]), "cells": (d["cells"] as Array).duplicate()})
	return out


# ==================== 实时校验（全覆盖 / 无重叠 / 复合格门禁）====================

## 实时校验当前划分。
##
## `grid` —— `GridInterface`（唯一真源：盘内格 = `all_positions()`）。
## `doc`  —— 可选，复合格来源：`MegaCell` 实例，或含 "mega" 键的字典，或带 `mega_cell()` 的对象。
##
## 返回：
##   {ok: bool,                       # false == block（文档「不完整阻止保存」）
##    level: "ok"|"warn"|"block",
##    covered: bool,                  # 每个盘内格**恰好**属于一张骨牌（全覆盖 + 无重叠 + 无盘外格）
##    uncovered: Array[Vector2i],     # 未被任何骨牌覆盖的盘内格（逐格坐标，升序）
##    overlaps: Array,                # [{pos, count, ids}] 被多张骨牌重复占用的格（升序）
##    overlap_cells: Array[Vector2i], # 同上，纯坐标（UI 高亮方便）
##    issues: Array}                  # [{code, level, text, cells}] 可读原因
func validate(grid: Variant, doc: Variant = null) -> Dictionary:
	var board: Array[Vector2i] = []
	var board_set := {}
	if _is_grid(grid):
		for p: Vector2i in grid.call("all_positions"):
			if not board_set.has(p):
				board_set[p] = true
				board.append(p)
	board.sort_custom(_pos_less)

	# 逐格占用计数（**从骨牌记录重算**，不信任可能被脏存档覆盖过的 _owner）。
	var occ := {}
	for d in _dominoes:
		for p: Vector2i in (d["cells"] as Array):
			occ[p] = int(occ.get(p, 0)) + 1

	var uncovered: Array[Vector2i] = []
	var overlaps: Array = []
	var overlap_cells: Array[Vector2i] = []
	for p: Vector2i in board:
		var n := int(occ.get(p, 0))
		if n == 0:
			uncovered.append(p)
		elif n >= DOMINO_SIZE:
			overlaps.append({"pos": p, "count": n, "ids": _ids_at(p)})
			overlap_cells.append(p)

	# 盘外的格（形状盘上按包围盒写坐标会踩）：也要列出来。
	var off_board: Array[Vector2i] = []
	for k in occ:
		var p2: Vector2i = k
		if not board_set.has(p2):
			off_board.append(p2)
	off_board.sort_custom(_pos_less)

	var issues: Array = []
	if not uncovered.is_empty():
		issues.append(_issue("uncovered", LEVEL_BLOCK,
			"骨牌划分不完整：还有 %d 个盘内格没有被任何骨牌覆盖（%s）—— 不完整会阻止保存"
			% [uncovered.size(), _fmt_cells(uncovered)], uncovered))
	if not overlaps.is_empty():
		issues.append(_issue("overlap", LEVEL_BLOCK,
			"骨牌重叠：%d 个格被多张骨牌重复占用（%s）—— 每格必须恰好属于一张骨牌"
			% [overlap_cells.size(), _fmt_cells(overlap_cells)], overlap_cells))
	if not off_board.is_empty():
		issues.append(_issue("off_board", LEVEL_BLOCK,
			"骨牌包含**不在盘内**的格（%s）—— 形状盘/外部拓扑盘必须按邻接表判定，不能按包围盒"
			% _fmt_cells(off_board), off_board))

	# 已存骨牌的内部一致性：相邻 + 不跨复合格（脏存档 / 手工构造才会违反）。
	var mega: Variant = _resolve_mega(doc)
	var not_adjacent: Array[Vector2i] = []
	var cross_mega: Array[Vector2i] = []
	for d2 in _sorted_records():
		var cs: Array = d2["cells"]
		if cs.size() == DOMINO_SIZE and _is_grid(grid):
			if not _neighbors_of(grid, cs[0]).has(cs[1]):
				not_adjacent.append(cs[0])
				not_adjacent.append(cs[1])
		if mega != null and cs.size() == DOMINO_SIZE:
			if _mega_owner_of(mega, cs[0]) != _mega_owner_of(mega, cs[1]):
				cross_mega.append(cs[0])
				cross_mega.append(cs[1])
	if not not_adjacent.is_empty():
		issues.append(_issue("not_adjacent", LEVEL_BLOCK,
			"有骨牌的两格并不相邻（%s）—— 相邻必须按棋盘邻接表判定" % _fmt_cells(not_adjacent), not_adjacent))
	if not cross_mega.is_empty():
		issues.append(_issue("cross_mega", LEVEL_BLOCK,
			"有骨牌**跨复合格**（%s）—— 文档「复合格 × 变体」未定义组合，明确拒绝（把配对限制在同一个复合格内）"
			% _fmt_cells(cross_mega), cross_mega))

	# 单格复合格：那一格永远配不成骨牌 ⇒ 必然留空缺，明确 block（不静默放过）。
	if mega != null:
		var singles: Array[Vector2i] = []
		var single_ids := {}
		for p3: Vector2i in board:
			var oid := _mega_owner_of(mega, p3)
			if oid != 0 and _mega_size_of(mega, oid) == 1:
				singles.append(p3)
				single_ids[oid] = true
		if not singles.is_empty():
			var names: Array[String] = []
			for k2 in single_ids:
				names.append("#%d" % int(k2))
			names.sort()
			issues.append(_issue("mega_singleton", LEVEL_BLOCK,
				"单格复合格 %s 只含 1 格（%s）：骨牌必须 2 格同属一个复合格 ⇒ 这些格永远配不成骨牌、必然留下空缺"
				% [",".join(names), _fmt_cells(singles)], singles))

	# 盘内格数为奇数 ⇒ 2 格骨牌不可能全覆盖（提前说清，避免用户白找）。
	if board.size() % DOMINO_SIZE != 0:
		issues.append(_issue("odd_cells", LEVEL_BLOCK,
			"盘内格数 %d 是奇数：2 格骨牌不可能全覆盖（必然至少留 1 格空缺）" % board.size(), []))

	var level := LEVEL_OK
	for it in issues:
		level = _max_level(level, str((it as Dictionary)["level"]))
	var covered := uncovered.is_empty() and overlaps.is_empty() and off_board.is_empty()
	return {
		"ok": level != LEVEL_BLOCK,
		"level": level,
		"covered": covered,
		"uncovered": uncovered,
		"overlaps": overlaps,
		"overlap_cells": overlap_cells,
		"issues": issues,
	}


# ==================== 序列化（version 只增不改）====================

## `{version, next_id, dominoes: [{id, cells: [[x, y], ...]}, ...]}`。
## 骨牌按**稳定顺序**（规范格序 + id 兜底），与拖拽/放置顺序无关 ⇒ round-trip 逐字节一致。
func to_dict() -> Dictionary:
	var items: Array = []
	for d in _sorted_records():
		var pair: Array = []
		for p: Vector2i in (d["cells"] as Array):
			pair.append([p.x, p.y])
		items.append({"id": int(d["id"]), "cells": pair})
	return {"version": VERSION, "next_id": _next_id, "dominoes": items}


## 从 `to_dict()` 产物恢复。
## · 版本高于本模块 → push_error + 返回空实例（不猜语义）；
## · 单张骨牌坏数据（id 非正 / id 重复 / cells 解析后不等于 2 个不同格）→ push_error + 跳过该条，
##   不牵连整盘；
## · 同一格出现在多张骨牌里 → **照常收下**（由 `validate()` 报 `overlap`，绝不静默丢骨牌）。
static func from_dict(d: Dictionary) -> DominoModel:
	# 用 `new()` 而非 `DominoModel.new()`：新脚本的全局类缓存可能尚未刷新，按类名自引用会编译失败。
	var model := new()
	var ver := int(d.get("version", VERSION))
	if ver > VERSION:
		push_error("DominoModel.from_dict: 存档版本 %d 高于本模块支持的 %d（version 只增不改，请升级读取方）" % [ver, VERSION])
		return model
	var raw: Variant = d.get("dominoes", [])
	if not (raw is Array):
		push_error("DominoModel.from_dict: dominoes 必须是数组（收到 %s）" % str(raw))
		return model
	var used := {}
	for item: Variant in raw:
		if not (item is Dictionary):
			push_error("DominoModel.from_dict: dominoes 条目必须是字典：%s" % str(item))
			continue
		var rec: Dictionary = item
		var did := int(rec.get("id", 0))
		if did <= 0:
			push_error("DominoModel.from_dict: 骨牌 id 必须为正整数（收到 %d），已跳过" % did)
			continue
		if used.has(did):
			push_error("DominoModel.from_dict: 骨牌 id 重复 %d，已跳过" % did)
			continue
		var cells := _canon_pair(rec.get("cells", []))
		if cells.size() != DOMINO_SIZE or cells[0] == cells[1]:
			push_error("DominoModel.from_dict: 骨牌 #%d 的 cells 必须是 2 个不同的格（收到 %s），已跳过"
				% [did, str(rec.get("cells", []))])
			continue
		used[did] = true
		model._dominoes.append({"id": did, "cells": cells})
		model._next_id = maxi(model._next_id, did + 1)
		for p: Vector2i in cells:
			model._owner[p] = did
	model._next_id = maxi(model._next_id, int(d.get("next_id", 1)))
	return model


# ==================== 内部：稳定顺序 ====================

func _sorted_records() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d in _dominoes:
		out.append({"id": int(d["id"]), "cells": _canon_pair(d["cells"])})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ca: Array = a["cells"]
		var cb: Array = b["cells"]
		if _pair_less(ca, cb):
			return true
		if _pair_less(cb, ca):
			return false
		return int(a["id"]) < int(b["id"]))
	return out


## 规范格对：解析 Vector2i / {x,y} / [x,y]，去重后按 (x, y) 字典序排序。
static func _canon_pair(raw: Variant) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if raw is Array:
		for v: Variant in raw:
			var p_v: Variant = _to_pos(v)
			if p_v == null:
				continue
			var p: Vector2i = p_v
			if not out.has(p):
				out.append(p)
	out.sort_custom(_pos_less)
	return out


static func _to_pos(v: Variant) -> Variant:
	if v is Vector2i:
		return v
	if v is Dictionary:
		var dd: Dictionary = v
		if dd.has("x") and dd.has("y"):
			return Vector2i(int(dd["x"]), int(dd["y"]))
	if v is Array:
		var a: Array = v
		if a.size() == 2 and (a[0] is int or a[0] is float) and (a[1] is int or a[1] is float):
			return Vector2i(int(a[0]), int(a[1]))
	return null


static func _pos_less(a: Vector2i, b: Vector2i) -> bool:
	return a.x < b.x or (a.x == b.x and a.y < b.y)


static func _pair_less(a: Array, b: Array) -> bool:
	var n := mini(a.size(), b.size())
	for i in n:
		var pa: Vector2i = a[i]
		var pb: Vector2i = b[i]
		if pa.x != pb.x:
			return pa.x < pb.x
		if pa.y != pb.y:
			return pa.y < pb.y
	return a.size() < b.size()


# ==================== 内部：复合格门禁 ====================

## 复合格来源：`MegaCell` 实例 / {"mega": ...} 字典 / 带 `mega_cell()` 的对象。取不到 ⇒ null。
static func _resolve_mega(doc: Variant) -> Variant:
	if doc == null:
		return null
	if doc is Dictionary:
		return (doc as Dictionary).get("mega", null)
	if doc is Object and (doc as Object).has_method("mega_cell"):
		return (doc as Object).call("mega_cell")
	# 鸭子类型：有 owner_of + size_of 就是复合格管理器（MegaCell 及等价实现）。
	if doc is Object and (doc as Object).has_method("owner_of") and (doc as Object).has_method("size_of"):
		return doc
	return null


static func _mega_owner_of(mega: Variant, pos: Vector2i) -> int:
	if mega == null:
		return 0
	return int((mega as Object).call("owner_of", pos))


static func _mega_size_of(mega: Variant, mega_id: int) -> int:
	if mega == null:
		return 0
	return int((mega as Object).call("size_of", mega_id))


## 跨复合格 / 单格复合格的可读拒绝（两格归属不同 ⇒ 一定进这里）。
static func _mega_reject(mega: Variant, a: Vector2i, ma: int, b: Vector2i, mb: int) -> Dictionary:
	if ma != 0 and _mega_size_of(mega, ma) == 1:
		return {"ok": false, "code": "mega_singleton",
			"reason": "复合格 #%d 只含 1 格（含 (%d,%d)）：单格复合格无法与任何格配成骨牌（骨牌必须 2 格同属一个复合格）"
				% [ma, a.x, a.y]}
	if mb != 0 and _mega_size_of(mega, mb) == 1:
		return {"ok": false, "code": "mega_singleton",
			"reason": "复合格 #%d 只含 1 格（含 (%d,%d)）：单格复合格无法与任何格配成骨牌（骨牌必须 2 格同属一个复合格）"
				% [mb, b.x, b.y]}
	return {"ok": false, "code": "cross_mega",
		"reason": "跨复合格：(%d,%d) %s，( %d,%d) %s —— 骨牌不允许跨复合格（文档「复合格 × 变体」未定义组合，明确拒绝）"
			% [a.x, a.y, _mega_where(ma), b.x, b.y, _mega_where(mb)]}


static func _mega_where(owner_id: int) -> String:
	return "不属于任何复合格" if owner_id == 0 else "属于复合格 #%d" % owner_id


# ==================== 内部工具 ====================

func _index_of(domino_id: int) -> int:
	for i in _dominoes.size():
		if int((_dominoes[i] as Dictionary)["id"]) == domino_id:
			return i
	return -1


func _ids_at(pos: Vector2i) -> Array[int]:
	var out: Array[int] = []
	for d in _sorted_records():
		if (d["cells"] as Array).has(pos):
			out.append(int(d["id"]))
	return out


func _free(cells: Variant) -> void:
	for p: Vector2i in (cells as Array):
		if _owner.has(p):
			_owner.erase(p)


func _occupied_text(a: Vector2i, id_a: int, b: Vector2i, id_b: int) -> String:
	var parts: Array[String] = []
	if id_a != 0:
		parts.append("(%d,%d) 已被骨牌 #%d 占用" % [a.x, a.y, id_a])
	if id_b != 0:
		parts.append("(%d,%d) 已被骨牌 #%d 占用" % [b.x, b.y, id_b])
	return "无法放置：%s（每格只能属于一张骨牌，请先擦除原骨牌）" % "；".join(parts)


static func _is_grid(g: Variant) -> bool:
	return g is Object and (g as Object).has_method("all_positions") \
		and (g as Object).has_method("in_board") and (g as Object).has_method("get_neighbors")


static func _neighbors_of(grid: Variant, pos: Vector2i) -> Array:
	var res: Variant = (grid as Object).call("get_neighbors", pos)
	return res if res is Array else []


static func _fmt_cells(cells: Array) -> String:
	var parts: Array[String] = []
	var limit := mini(cells.size(), 6)
	for i in limit:
		var p: Vector2i = cells[i]
		parts.append("(%d,%d)" % [p.x, p.y])
	if cells.size() > limit:
		parts.append("…共 %d 格" % cells.size())
	return ", ".join(parts)


static func _reject(code: String, reason: String) -> Dictionary:
	return {"ok": false, "code": code, "reason": reason}


static func _max_level(a: String, b: String) -> String:
	if a == LEVEL_BLOCK or b == LEVEL_BLOCK:
		return LEVEL_BLOCK
	if a == LEVEL_WARN or b == LEVEL_WARN:
		return LEVEL_WARN
	return LEVEL_OK


static func _issue(code: String, level: String, text: String, cells: Array = []) -> Dictionary:
	return {"code": code, "level": level, "text": text, "cells": cells}


# ==================== 集成点（后续切片，勿在本轮动手）====================
# 1) UI：`ui/level_editor.gd` 拖拽画骨牌 —— 拖动时对候选对调 `place()`，block 则禁掉并显示 reason；
#    盘面重绘用 `dominoes()`（稳定顺序）；实时状态用 `validate(grid, doc)`。
#    当前 `core/editor_doc.gd` **没有** dominoes 字段（关卡 JSON 的 `dominoes` 由 Board 读取，
#    编辑器尚未编辑它）⇒ 需要新增一个独立字段，走 `to_dict()/from_dict()` 归档，不动现有 validate()
#    语义（与 MegaCell 的集成点注释同口径）。
# 2) 生成器：`core/puzzle_generator.gd` 落盘 `dominoes` 时格式为 `[[{c,r},{c,r}], ...]`；
#    本模型的 `cells` 是 `[[x,y],[x,y]]`（内部 `Vector2i(c,r)`）——接线时需在
#    `to_dict()/from_dict()` 之外做一次 c/r ↔ x/y 交换，避免两套口径打架。
# 3) 变体门禁：DT 规则 `geometry_kind() == GEO_RECT_ONLY`；「复合格 × DT」属未定义组合，
#    本模型挡住跨复合格/单格复合格两条；染色（按复合格中心点）留给后续切片。
