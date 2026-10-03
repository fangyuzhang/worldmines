# mega_cell.gd —— 复合格（Mega Cell）：把一大片基础格合并成「逻辑一格」的纯逻辑模型。
#
# 为什么存在（文档「三、形状系统 · 复合格」）：合并后该区域**显示一个数字、可放雷、参与求解**，
# 双击可下钻看内部。三个必须由**入口**挡住 / 提醒的坑（本模块是唯一入口）：
#   ① 禁止嵌套 —— 复合格不能再合并（邻接关系会指数爆炸）：任一基础格已被别的复合格占用，
#      或调用方直接把「复合格 / 复合格集合」当基础格传进来，一律拒绝并给人话原因；
#   ② 密度稀释 —— 逻辑一格最多放 1 颗雷，区域越大实际密度越低（37% → 7% 这种），
#      低于**变体推荐密度**时给 warn（带可读原因）；
#   ③ 邻接上限 —— 单复合格邻接 >30 格 warn、>80 格 block（数字读不出来 / 求解器算不动）。
#
# 实例语义：`MegaCell.new()` = **一块棋盘上的复合格集合（管理器）**；单个复合格用
#   `{"id": int, "cells": Array[Vector2i]}` 记录表示（merge 的返回值、也是各查询入口接受的入参）。
#
# 边界（本轮刻意不做，留给后续切片，见文件末「集成点」）：
#   · 不参与求解（求解器 / CP-SAT 接线是后续切片）；
#   · 不碰场景树、不引用 UI / autoload、不改任何现有文件；
#   · 邻接**不自造矩形 4/8 邻域**：由调用方传入 `GridInterface` 或「坐标 → 邻居数组」的 Callable；
#   · 不写进关卡 JSON（`to_dict` 只是这一子系统自己的存档口径）。
#
# 坐标口径：基础格 = `Vector2i`（整数棋盘坐标，与全仓一致）。
#   浮点派生量（区域重心）序列化时按 **1/65536** 定点量化（`quantize` / `dequantize`），
#   保证跨平台 / 跨语言 round-trip 不引入浮点漂移。
class_name MegaCell
extends RefCounted

## 序列化版本。**只增不改**：新增字段可以；改语义必须递增（`from_dict` 拒收更高版本）。
const VERSION := 1

## 坐标量化口径：1 / 65536。
const COORD_SCALE := 65536

## 邻接规模门禁阈值（与 `EditorDoc` 的「W-B 邻接规模门禁」同口径：>30 warn、>80 block）。
const ADJ_WARN := 30
const ADJ_BLOCK := 80

## 复合格内雷数上限（文档：合并后该区域最多放 1 颗雷）。
const DEFAULT_MINE_CAP := 1

const LEVEL_OK := "ok"
const LEVEL_WARN := "warn"
const LEVEL_BLOCK := "block"

## id → Array[Vector2i]（规范序：去重 + 按 (x, y) 字典序）。
var _cells: Dictionary = {}
## Vector2i → id（0 / 缺省 = 该基础格尚未被任何复合格占用）。
var _owner: Dictionary = {}
## 下一个待分配 id（从 1 起；拆分不回收 id，避免旧引用指向新复合格）。
var _next_id: int = 1
## id → {other_id: true}：反序列化时发现的「同一基础格被多个复合格占用」（坑①的兜底）。
var _conflict_ids: Dictionary = {}
## id → {Vector2i: true}：同上，冲突的基础格。
var _conflict_cells: Dictionary = {}


# ==================== 坐标量化（1/65536）====================

## 浮点坐标 → 1/65536 定点整数（四舍五入）。
static func quantize(value: float) -> int:
	return int(round(value * float(COORD_SCALE)))


## 1/65536 定点整数 → 浮点坐标。
static func dequantize(q: int) -> float:
	return float(q) / float(COORD_SCALE)


## 规范格集：接受 Vector2i / {"x":int,"y":int}，去重后按 (x, y) 字典序排序。
## 其他类型一律丢弃（合并入口会先分类并给出可读拒绝，这里只是兜底）。
static func canonical(raw: Array) -> Array[Vector2i]:
	var seen := {}
	var out: Array[Vector2i] = []
	for v: Variant in raw:
		var parsed: Variant = _to_pos(v)
		if parsed == null:
			continue
		var pos: Vector2i = parsed
		if seen.has(pos):
			continue
		seen[pos] = true
		out.append(pos)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y))
	return out


# ==================== 合并 / 拆分（坑①：禁止嵌套）====================

## 由一组**基础格坐标**合并成一个复合格。
## 返回 `{"ok": true, "id": int, "cells": Array[Vector2i]}`，
## 拒绝时返回 `{"ok": false, "code": String, "reason": String}`，code ∈ {"empty","nested","bad_cell"}。
## 拒绝一律**无副作用**（不分配 id、不占用任何格）。
func merge(base_cells: Array) -> Dictionary:
	if base_cells.is_empty():
		return _reject("empty", "合并需要至少 1 个基础格坐标（收到空集合）")
	# 先分类：不允许把「复合格 / 复合格集合」再合并进来（坑①：禁止嵌套）。
	var parsed: Array[Vector2i] = []
	for v: Variant in base_cells:
		var kind := _classify(v)
		if kind == "group":
			return _reject("nested", "禁止嵌套：合并输入必须是**基础格坐标**，但收到了复合格 / 复合格集合（%s）——复合格不能再合并" % str(v))
		if kind != "cell":
			return _reject("bad_cell", "合并输入里有无法识别的坐标：%s（需 Vector2i 或 {\"x\":int,\"y\":int}）" % str(v))
		var pos: Vector2i = _to_pos(v)
		parsed.append(pos)
	var canon := canonical(parsed)
	if canon.is_empty():
		return _reject("bad_cell", "合并输入解析后为空（坐标全部非法）")
	# 已被占用的格不能再进另一个复合格（同一基础格只能属于一个复合格）。
	var owners := {}
	for p: Vector2i in canon:
		var oid := owner_of(p)
		if oid != 0:
			owners[oid] = true
	if not owners.is_empty():
		var names: Array[String] = []
		for oid2 in owners:
			names.append(str(int(oid2)))
		names.sort()
		return _reject("nested", "禁止嵌套：选中的 %d 个格已被复合格 #%s 占用（同一基础格只能属于一个复合格）" % [canon.size(), ",".join(names)])
	var gid := _next_id
	_cells[gid] = canon
	for p2: Vector2i in canon:
		_owner[p2] = gid
	_next_id += 1
	return {"ok": true, "id": gid, "cells": canon.duplicate()}


## 拆分复合格：释放其占用的基础格，返回原始格集合（id 不回收）。
## 接受 id 或 merge 返回的记录（含 "id" 的字典）。
func split(mega: Variant) -> Dictionary:
	var gid := _resolve_id(mega)
	if not _cells.has(gid):
		return {"ok": false, "code": "unknown", "reason": "复合格 #%d 不存在，无法拆分" % gid}
	var freed: Array[Vector2i] = (_cells[gid] as Array[Vector2i]).duplicate()
	for p: Vector2i in freed:
		if int(_owner.get(p, 0)) == gid:
			_owner.erase(p)
	_cells.erase(gid)
	_conflict_ids.erase(gid)
	_conflict_cells.erase(gid)
	return {"ok": true, "cells": freed}


# ==================== 查询 / 下钻 ====================

func count() -> int:
	return _cells.size()


func has(mega: Variant) -> bool:
	return _cells.has(_resolve_id(mega))


## 全部分配过的 id（升序）。
func ids() -> Array[int]:
	var out: Array[int] = []
	for k in _cells:
		out.append(int(k))
	out.sort()
	return out


## 某基础格归属的复合格 id；0 = 尚未合并。
func owner_of(pos: Vector2i) -> int:
	return int(_owner.get(pos, 0))


## 下钻：复合格内部的基础格集合（规范序副本，调用方改不到内部）。
## 「逻辑一格」与内部集合**一致**：size_of() == internal_cells().size()，不重复、不丢失。
func internal_cells(mega: Variant) -> Array[Vector2i]:
	var gid := _resolve_id(mega)
	if not _cells.has(gid):
		return []
	return (_cells[gid] as Array[Vector2i]).duplicate()


## 逻辑一格包含的基础格数（= 内部集合大小）。
func size_of(mega: Variant) -> int:
	var gid := _resolve_id(mega)
	if not _cells.has(gid):
		return 0
	return (_cells[gid] as Array[Vector2i]).size()


## 区域重心（派生量，仅 UI 定位数字/标签用；不参与邻接语义）。
func centroid_of(mega: Variant) -> Vector2:
	var gid := _resolve_id(mega)
	if not _cells.has(gid):
		return Vector2.ZERO
	var cells: Array[Vector2i] = _cells[gid]
	var sum := Vector2.ZERO
	for p: Vector2i in cells:
		sum += Vector2(p)
	return sum / float(cells.size())


## 反序列化时发现的「共格嵌套」清单（正常入口 merge 不会产生）。
func conflicts() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for k in _conflict_ids:
		var others: Array[int] = []
		for o in (_conflict_ids[k] as Dictionary):
			others.append(int(o))
		others.sort()
		var cell_list: Array = []
		for p: Vector2i in (_conflict_cells.get(k, {}) as Dictionary):
			cell_list.append([p.x, p.y])
		out.append({"id": int(k), "others": others, "cells": cell_list})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["id"]) < int(b["id"]))
	return out


# ==================== 邻接计算 / 硬规则门禁 ====================

## 邻接：复合格与多少「基础格 / 复合格」相邻（**去重后**计数）。
## `provider` = `GridInterface` 实例，或 `func(pos: Vector2i) -> Array[Vector2i]`。
## 返回：
##   {ok, base: int,            # 相邻基础格数（同一格只算一次；不含自身区域内）
##    mega: int,                # 相邻复合格数（多个相邻格同属一个复合格只算 1）
##    cells: Array[Vector2i],   # 去重后的相邻基础格
##    neighbor_ids: Array[int]} # 相邻复合格 id（升序）
func adjacency(mega: Variant, provider: Variant) -> Dictionary:
	var gid := _resolve_id(mega)
	if not _cells.has(gid):
		return _empty_adjacency("复合格 #%d 不存在，无法算邻接" % gid)
	if provider == null:
		return _empty_adjacency("未提供邻接来源（GridInterface / Callable）")
	var own: Array[Vector2i] = _cells[gid]
	var seen := {}
	var owner_ids := {}
	for p: Vector2i in own:
		for nb: Variant in _neighbors(provider, p):
			if not (nb is Vector2i):
				continue
			var q: Vector2i = nb
			if _contains_cell(own, q):
				continue          # 自身区域内的格不是邻居
			seen[q] = true        # 去重：调用方重复给出同一邻居只算一次
			var oid := owner_of(q)
			if oid != 0 and oid != gid:
				owner_ids[oid] = true
	var cells: Array[Vector2i] = []
	for k: Vector2i in seen:
		cells.append(k)
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y))
	var nids: Array[int] = []
	for k2 in owner_ids:
		nids.append(int(k2))
	nids.sort()
	return {"ok": true, "base": cells.size(), "mega": nids.size(), "cells": cells, "neighbor_ids": nids}


## 硬规则门禁。`mega` 接受 id 或记录字典。
## `opts`：
##   provider            —— GridInterface 或 Callable（缺省不查邻接）
##   recommended_density —— 变体推荐密度（0~1；<=0 表示不查密度）
##   mine_cap            —— 该复合格雷数上限（默认 1）
## 返回 `{ok, level, reasons: [{code, level, text}], adjacency: {...}}`。
##   · level = "block" ⇒ `ok = false`，**调用方必须阻止该操作**（reasons 说明原因）；
##   · level = "warn"  ⇒ `ok = true`，放行但 UI 应提示 reasons；
##   · level = "ok"    ⇒ reasons 为空。
func check(mega: Variant, opts: Dictionary = {}) -> Dictionary:
	var gid := _resolve_id(mega)
	if not _cells.has(gid):
		return {
			"ok": false, "level": LEVEL_BLOCK, "adjacency": {},
			"reasons": [_reason("unknown", LEVEL_BLOCK, "复合格 #%d 不存在（无法检查门禁）" % gid)],
		}
	var reasons: Array = []
	var level := LEVEL_OK
	# ① 嵌套 / 共格（正常入口 merge 已挡；反序列化脏数据在这里兜底并 block）。
	var others: Dictionary = _conflict_ids.get(gid, {})
	if not others.is_empty():
		var names: Array[String] = []
		for o in others:
			names.append(str(int(o)))
		names.sort()
		level = LEVEL_BLOCK
		reasons.append(_reason("nested", LEVEL_BLOCK,
			"禁止嵌套：该复合格与复合格 #%s 占用了同一批基础格，请拆掉其中之一" % ",".join(names)))
	# ② 邻接上限（>30 warn、>80 block）。
	var adj := adjacency(gid, opts.get("provider", null))
	if bool(adj.get("ok", false)):
		var n := int(adj["base"])
		if n > ADJ_BLOCK:
			level = LEVEL_BLOCK
			reasons.append(_reason("neighbor_huge", LEVEL_BLOCK,
				"复合格邻接 %d 格（上限 %d）—— 这一格的数字读不出来、求解器也算不动：请缩小合并范围" % [n, ADJ_BLOCK]))
		elif n > ADJ_WARN:
			level = _max_level(level, LEVEL_WARN)
			reasons.append(_reason("neighbor_many", LEVEL_WARN,
				"复合格邻接 %d 格（超过 %d 就该警惕）—— 那格的数字会很难读" % [n, ADJ_WARN]))
	# ③ 密度稀释（区域雷数上限 1 ⇒ 实际密度 vs 变体推荐密度）。
	var rec := float(opts.get("recommended_density", 0.0))
	var cap := int(opts.get("mine_cap", DEFAULT_MINE_CAP))
	if rec > 0.0 and size_of(gid) > 0:
		var n_cells := size_of(gid)
		var density := float(cap) / float(n_cells)
		if density < rec:
			level = _max_level(level, LEVEL_WARN)
			var expect := int(round(rec * float(n_cells)))
			reasons.append(_reason("density_diluted", LEVEL_WARN,
				"密度稀释：%d 格合并成逻辑一格后最多放 %d 颗雷 ⇒ 实际密度 %.1f%%，低于变体推荐密度 %.0f%%（该区域按推荐约可放 %d 颗）—— 关卡会明显变空" % [
					n_cells, cap, density * 100.0, rec * 100.0, expect]))
	return {"ok": level != LEVEL_BLOCK, "level": level, "reasons": reasons, "adjacency": adj}


# ==================== 序列化（version 只增不改）====================

## `{version, next_id, groups:[{id, cells:[[x,y],...], centroid_q:[qx,qy]}]}`
## `cells` = 整数棋盘坐标；`centroid_q` = 1/65536 定点量化的区域重心（派生量）。
func to_dict() -> Dictionary:
	var groups: Array = []
	for gid in ids():
		var cell_pairs: Array = []
		for p: Vector2i in internal_cells(gid):
			cell_pairs.append([p.x, p.y])
		var c := centroid_of(gid)
		groups.append({
			"id": gid,
			"cells": cell_pairs,
			"centroid_q": [quantize(c.x), quantize(c.y)],
		})
	return {"version": VERSION, "next_id": _next_id, "groups": groups}


## 从 `to_dict()` 产物恢复。
## · 版本高于本模块 → push_error + 返回空实例（不猜语义）；
## · 单个复合格坏数据（id 非正 / id 重复 / cells 全空）→ push_error + 跳过该条，不牵连整盘；
## · 同一基础格被多个复合格占用 → 照常收下并记入 conflicts()，由 `check()` block（绝不静默丢复合格）。
static func from_dict(d: Dictionary) -> MegaCell:
	var reg := MegaCell.new()
	var ver := int(d.get("version", VERSION))
	if ver > VERSION:
		push_error("MegaCell.from_dict: 存档版本 %d 高于本模块支持的 %d（version 只增不改，请升级读取方）" % [ver, VERSION])
		return reg
	var raw_groups: Variant = d.get("groups", [])
	if not (raw_groups is Array):
		push_error("MegaCell.from_dict: groups 必须是数组（收到 %s）" % str(raw_groups))
		return reg
	var used := {}
	for g: Variant in raw_groups:
		if not (g is Dictionary):
			push_error("MegaCell.from_dict: groups 条目必须是字典：%s" % str(g))
			continue
		var gd: Dictionary = g
		var gid := int(gd.get("id", 0))
		if gid <= 0:
			push_error("MegaCell.from_dict: 复合格 id 必须为正整数（收到 %d），已跳过" % gid)
			continue
		if used.has(gid):
			push_error("MegaCell.from_dict: 复合格 id 重复 %d，已跳过" % gid)
			continue
		used[gid] = true
		var canon := canonical(gd.get("cells", []))
		if canon.is_empty():
			push_error("MegaCell.from_dict: 复合格 #%d 的 cells 为空或全部非法，已跳过" % gid)
			continue
		reg._cells[gid] = canon
		reg._next_id = maxi(reg._next_id, gid + 1)
		for p: Vector2i in canon:
			if reg._owner.has(p):
				var first := int(reg._owner[p])
				reg._note_conflict(first, gid, p)
				reg._note_conflict(gid, first, p)
			else:
				reg._owner[p] = gid
	reg._next_id = maxi(reg._next_id, int(d.get("next_id", 1)))
	return reg


# ==================== 内部工具 ====================

## 元素分类：base cell / group（复合格或复合格集合）/ 非法。
static func _classify(v: Variant) -> String:
	if v is Vector2i:
		return "cell"
	if v is Array:
		return "group"          # 复合格集合（"一组格"本身就是复合格语义）
	if v is Dictionary:
		var d: Dictionary = v
		if d.has("cells") or d.has("id"):
			return "group"      # 单复合格记录
		if d.has("x") and d.has("y"):
			return "cell"
		return "bad"
	return "bad"


## 解析一个基础格坐标。**只用于格集合内部与反序列化**（merge 入口先 `_classify`，
## 所以 `[x,y]` 这种「一组格」不会被 merge 当成基础格收进来）。
static func _to_pos(v: Variant) -> Variant:
	if v is Vector2i:
		return v
	if v is Dictionary:
		var d: Dictionary = v
		if d.has("x") and d.has("y"):
			return Vector2i(int(d["x"]), int(d["y"]))
	if v is Array:
		# 序列化口径：cells 写作 [[x, y], ...]（与 SaveData 的 int-pair 约定一致）。
		var a: Array = v
		if a.size() == 2 and (a[0] is int or a[0] is float) and (a[1] is int or a[1] is float):
			return Vector2i(int(a[0]), int(a[1]))
	return null


static func _contains_cell(list: Array[Vector2i], pos: Vector2i) -> bool:
	for p: Vector2i in list:
		if p == pos:
			return true
	return false


static func _neighbors(provider: Variant, pos: Vector2i) -> Array:
	if provider is Callable:
		var res: Variant = (provider as Callable).call(pos)
		if res is Array:
			return res
		return []
	if provider is GridInterface:
		return (provider as GridInterface).get_neighbors(pos)
	push_error("MegaCell: 邻接必须传入 GridInterface 或「坐标 → 邻居数组」的 Callable（收到 %s）" % str(provider))
	return []


static func _empty_adjacency(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "base": 0, "mega": 0, "cells": [], "neighbor_ids": []}


func _reject(code: String, reason: String) -> Dictionary:
	return {"ok": false, "code": code, "reason": reason}


func _resolve_id(mega: Variant) -> int:
	if mega is int:
		return mega
	if mega is Dictionary:
		return int((mega as Dictionary).get("id", 0))
	return 0


func _note_conflict(a: int, b: int, pos: Vector2i) -> void:
	var oa: Dictionary = _conflict_ids.get(a, {})
	oa[b] = true
	_conflict_ids[a] = oa
	var ca: Dictionary = _conflict_cells.get(a, {})
	ca[pos] = true
	_conflict_cells[a] = ca


static func _max_level(a: String, b: String) -> String:
	if a == LEVEL_BLOCK or b == LEVEL_BLOCK:
		return LEVEL_BLOCK
	if a == LEVEL_WARN or b == LEVEL_WARN:
		return LEVEL_WARN
	return LEVEL_OK


static func _reason(code: String, level: String, text: String) -> Dictionary:
	return {"code": code, "level": level, "text": text}


# ==================== 集成点（后续切片，勿在本轮动手）====================
# 1) 求解：求解器的「格集合」需把复合格当作**一个变量**（雷数 0/1），其邻接边按
#    `adjacency().cells` / `many` 折算成约束；线索显示值 = 复合格邻域内的雷数上限计数。
#    接线点 = `core/board.gd` / `solver/*`，本模块只提供数据与门禁。
# 2) UI：双击下钻 = `internal_cells(id)` 高亮；合并前须先跑 `check()`，block 时禁掉操作并
#    把 reasons 文本显示出来。接线点 = `core/editor_doc.gd`（新增独立字段，走 to_dict/from_dict）
#    与 `ui/level_editor.gd`，不动现有 validate() 语义。
# 3) 变体推荐密度：本模块只接受 `recommended_density` 入参，值应由变体/难度侧提供
#    （当前仓库无该表，属 W8/W9 后续切片）。
