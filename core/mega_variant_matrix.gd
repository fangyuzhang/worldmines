# mega_variant_matrix.gd —— 变体 × 复合格（Mega Cell）兼容矩阵
# （文档「五、变体规则配置 · ⚠ 复合格 × 变体」的唯一事实源）
#
# 【为什么需要】`core/mega_cell.gd` 把一大片基础格合并成「逻辑一格」，而内置变体几乎全部是
#   **在基础格上**定义的（行 / 列 / 2×2 窗口 / 染色 / 骨牌 / 镜像轴 / 邻域窗口）。两边一叠
#   就会出现「用户勾了变体、求解器却按另一个口径算」的组合：显示的数字与求解结论对不上。
#   文档点名要求这些未定义组合**必须进兼容门禁**，否则运行期出错；本文件就是那张门禁表。
#
# 【唯一事实源：谁拒绝，本表就照抄谁（不凭想象）】`core/solver/mega_solver.gd:58-70` 的
#   `build()` 是全仓**唯一**把复合格表达给求解器的入口，它有两条硬拒绝：
#     ① :63-65 —— 只支持经典 8 邻线索：`clue_variant != CLASSIC` / `clue_variant2 >= 0` /
#        `rule_clue_id != ""`（即 4n / clock / hv / fr / loopruns / distsum / sc，以及任何
#        AI 自定义线索规则）一律拒绝建模；
#     ② :66-68 —— 暂不支持全局约束：`constraint_variant* >= 0` / `rule_global_ids` 非空
#        （即 mx / rl / pf / qd / dt / ep / 4c）一律拒绝建模。
#   这与 `core/board.gd:327-339`（Board 撞上 MegaSolver 的拒绝时**不改写线索、只告警**）
#   是同一口径的两侧。⇒ 内置变体里**只有 classic 在复合格上被建模**。
#
# 【另外两条文档点名的规则（各有归属，本表只登记 / 给检查器）】
#   · 「骨牌不允许跨复合格」—— 已由 `core/domino_model.gd:247` 与 `:736` 硬拒绝；
#    本表把 dt 的禁用理由同时指向那里，**不重复实现**；
#   · 「镜像轴上的复合格必须成对」—— 由本文件的 `mirror_pair_issues()` 判定，带位置
#     （UI 可跳转定位），不靠"运行时才发现"。
#
# 【不臆造】只覆盖 `VariantRegistry` 的内置变体；表外 id（AI 自定义 spec / 未登记名）
#   ⇒ `status()` 返回 ""（不判）。与 `VariantGridMatrix` 同一条保守口径。
#
# 【消费者】`core/editor_verify.gd` 的 `mega_variant_issues()` 把本表翻成
#   {code, text, pos, level} 问题条目 → 编辑器验证面板（用户可见）。
class_name MegaVariantMatrix
extends RefCounted

## 三态。取值与 `VariantGridMatrix.OK / DEGRADED / DISABLED` **同值**（契约由
## test_mega_variant_matrix.gd 断言）——两张矩阵的消费者可以用同一套比较。
const OK := "OK"
const DEGRADED := "DEGRADED"
const DISABLED := "DISABLED"

## 唯一在复合格上被建模的变体（`MegaSolver.build` 只认经典 8 邻线索）。
const MEGA_SUPPORTED: Array[String] = ["classic"]

## 线索型里不被复合格建模的（`MegaSolver.build` :63-65 拒绝）。
const CLUE_UNSUPPORTED: Array[String] = ["4n", "clock", "hv", "fr", "loopruns", "distsum", "sc"]

## 全局约束型（`MegaSolver.build` :66-68 拒绝）。
const GLOBAL_UNSUPPORTED: Array[String] = ["mx", "rl", "pf", "qd", "dt", "ep", "4c"]

const REASON_CLUE := "复合格求解只建模「经典 8 邻线索」（core/solver/mega_solver.gd:63-65 对其余线索窗口一律拒绝建模）⇒ 同盘存在复合格时，该变体的数字口径与求解口径不再是同一个（会出现「显示一个数、求解按另一个数」）"
const REASON_GLOBAL := "复合格求解暂不支持全局约束（core/solver/mega_solver.gd:66-68 对全局约束一律拒绝建模）⇒ 该约束在含复合格的盘上不生效"
const REASON_DT_EXTRA := "；另外骨牌不允许跨复合格（core/domino_model.gd:247 / :736：配对被限制在同一个复合格内）"


## 变体 id 是否在 `VariantRegistry` 的内置名单里。表就是那张名单（单一事实源）。
static func is_known_variant(variant_id: String) -> bool:
	return VariantRegistry.all_codes().has(variant_id)


## 内置变体全名单（保序 = `VariantRegistry.all_codes()`，用于测试逐项覆盖防漏登记）。
static func variant_ids() -> Array[String]:
	return VariantRegistry.all_codes()


## 复合格 × 变体 的三态。
## `has_mega = false` ⇒ 一律 OK：本表只管「盘上有复合格」这一件事，无复合格时不产噪音。
## 表外 id ⇒ ""（不判，调用方应跳过）。
static func status(variant_id: String, has_mega: bool = true) -> String:
	if not is_known_variant(variant_id):
		return ""
	if not has_mega:
		return OK
	if MEGA_SUPPORTED.has(variant_id):
		return OK
	return DISABLED


## DISABLED 的可读原因（非空、且点名可查证的 file:line）。OK / 表外 id ⇒ ""。
static func reason(variant_id: String, has_mega: bool = true) -> String:
	if status(variant_id, has_mega) != DISABLED:
		return ""
	var base := REASON_CLUE if CLUE_UNSUPPORTED.has(variant_id) else REASON_GLOBAL
	if variant_id == "dt":
		base += REASON_DT_EXTRA
	return "变体「%s」与复合格是未定义组合：%s" % [variant_id, base]


## 退化清单。本表当前**无 DEGRADED 格**（复合格上要么被建模、要么未定义），保留态位是
## 三态契约的一部分：将来某变体在复合格上确有可解释的弱语义时再填（必须非空）。
static func degradations(variant_id: String, has_mega: bool = true) -> Array:
	if status(variant_id, has_mega) != DEGRADED:
		return []
	return []


# ==================== 文档点名的可判定检查：镜像轴上的复合格必须成对 ====================

## 镜像轴 = **竖轴**，列配对 `c ↔ cols-1-c`（与 `VariantGridMatrix` 里 mx 的语义同源，
## 见 core/rule_registry.gd:211-219）。判定：每个复合格的**镜像格集**必须仍是**同一个**
## 复合格（对称且自配对），或是**另一个**复合格（一对成对）。
## 返回 [{code, text, pos}]；`pos` = 出问题复合格的首格（UI 可跳转），无问题 ⇒ 空数组。
## 说明：`cols` 由调用方给（本模块不猜棋盘尺寸；网格尺寸口径见 GridInterface）。
static func mirror_pair_issues(mega: MegaCell, cols: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if mega == null or cols <= 0 or mega.count() == 0:
		return out
	# internal_cells() 已按 (x, y) 字典序（规范序）⇒ 直接拼键即可当格集的标识。
	var key_of := {}
	var by_key := {}
	for id in mega.ids():
		var k := _cells_key(mega.internal_cells(id))
		key_of[id] = k
		by_key[k] = int(id)
	for id2 in mega.ids():
		var cells: Array[Vector2i] = mega.internal_cells(id2)
		var mirrored: Array[Vector2i] = []
		var out_of_axis := false
		for c: Vector2i in cells:
			var mx := cols - 1 - c.x
			if mx < 0 or mx >= cols:
				out_of_axis = true
				break
			mirrored.append(Vector2i(mx, c.y))
		if out_of_axis:
			out.append(_pair_issue(cells,
					"复合格 #%d 有基础格不在 0~%d 列内，镜像轴（列配对 c ↔ cols-1-c）对它无定义" % [id2, cols - 1]))
			continue
		mirrored.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return a.x < b.x or (a.x == b.x and a.y < b.y))
		var mk := _cells_key(mirrored)
		if not by_key.has(mk):
			out.append(_pair_issue(cells,
					"镜像轴上的复合格必须成对：复合格 #%d（%d 格）镜像后既不是它自己、也不是任何另一个复合格 —— 请把它与镜像位置合并成同一批（文档「复合格 × 变体」）" % [id2, cells.size()]))
	return out


static func _cells_key(cells: Array[Vector2i]) -> String:
	var parts := PackedStringArray()
	for c: Vector2i in cells:
		parts.append("%d,%d" % [c.x, c.y])
	return "|".join(parts)


static func _pair_issue(cells: Array[Vector2i], text: String) -> Dictionary:
	var pos := Vector2i(-1, -1)
	if not cells.is_empty():
		pos = cells[0]          # 规范序首格：给 UI 一个可跳转的落点
	return {"code": "mega_mirror_unpaired", "text": text, "pos": pos}
