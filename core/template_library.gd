# template_library.gd —— 模板库（文档「九、辅助工具」模板库 +「十.6 新手可用性」简单/专家模式）。
#
# 【做什么】给新手一条「照着做就能出一关」的入口：官方示例（甜甜圈 / 双岛 / 护城河）
# + 最小新手教程盘，每条附带一段**可直接喂给 `EditorDoc` 的字段**（doc_build）。
#
# 【纯数据 + 纯查询（硬约束）】不 extends Node、不碰场景树、不写盘、不读盘：
#   · 模板数据（`all_templates()`）是纯字面量，每次现造（无共享可变状态）；
#   · 查询只做「按 id 取模板 / 按模式分概念可见性 / 把 doc_build 映射到 EditorDoc」；
#   · 唯一的外部依赖是 `EditorDoc`（RefCounted，非场景树），因为 doc_build 的目标就是它。
#
# 【doc_build 字段 = EditorDoc 真实字段（不伪造）】用到的键：title / rows / cols /
# shape_kind / shape_params / mines / obstacles / revealed（其余字段用 EditorDoc 默认值）。
# 形状族必须落在 `ShapeGenerator` **真实支持**的 kind 内（本案只用到 "" / "ring" / "holed_grid"）。
# 文档点名的「双岛」「护城河」在本仓**没有专门的形状族**（W8 形状子系统尚未建立，见
# docs/plans/2026-10-03-editor-feature-program.md 状态表），故用 `holed_grid` 挖洞做**语义等价近似**
# （洞 = 格不存在，正是「两块互不连通的棋盘 / 一圈环形城壕」），并在 desc 里写明近似口径，
# **不伪造**一个不存在的 "double_island" / "moat" kind。
#
# ⚠ **刻意不写 `class_name`**：headless 下新全局类不在 `.godot/global_script_class_cache.cfg` 里，
#   别人按类名引用会让整份脚本解析失败（工程坑表 #26，见 `ui/level_editor.gd:20-24`、
#   `ui/ui_icons.gd:8-12`、`docs/GEN_PERF_PLAN_0927.md:1033-1037`）。
#   调用方/测试一律走 preload：`const TemplateLibrary := preload("res://core/template_library.gd")`。
extends RefCounted

# ==================== 常量 ====================

const TIER_TUTORIAL := "tutorial"
const TIER_OFFICIAL := "official"
const TIER_ORDER: Array[String] = [TIER_TUTORIAL, TIER_OFFICIAL]

const MODE_SIMPLE := "simple"
const MODE_EXPERT := "expert"

## 本库会写进 EditorDoc 的字段名（与 `core/editor_doc.gd` 逐字一致；测试对拍用）。
const DOC_FIELDS: Array[String] = [
	"title", "rows", "cols", "shape_kind", "shape_params",
	"mines", "obstacles", "revealed",
]

# ---- 概念键：全部对应本仓**真实存在**的模块 / 界面分组（来源已在注释里点名）----
const CONCEPT_CELL_PAINT := "cell_paint"                     # ui/level_editor.gd 484「工具」（画笔/橡皮/矩形填充）
const CONCEPT_CELL_KINDS := "cell_kinds"                     # ui/level_editor.gd 501「格型」（地雷/障碍/初始已翻开）
const CONCEPT_SHAPE_LIBRARY := "shape_library"               # ui/level_editor.gd 778「形状（六边形/三角/圆/星/扇）」
const CONCEPT_BOUNDARY := "boundary_neighborhood"            # ui/level_editor.gd 716「边界与邻域」
const CONCEPT_LAYOUT_RULES := "layout_rules"                 # ui/level_editor.gd 741「布局规则」
const CONCEPT_VARIANTS := "variants"                         # ui/level_editor.gd 规则页 + 全仓「变体」概念
const CONCEPT_VERIFY_ISLANDS := "verify_islands"             # core/editor_verify.gd verify_islands + 多岛结论
const CONCEPT_BOOLEAN_OPS := "boolean_ops"                   # core/shape_boolean.gd（并/交/差/异或）
const CONCEPT_SHAPE_DAG := "shape_dag"                       # core/shape_dag.gd（形状依赖图 + 环检测）
const CONCEPT_RASTER_PRECISION := "raster_precision"         # core/shape_generator.gd build_circle/precision
const CONCEPT_MEGA_CELL := "mega_cell"                       # core/mega_cell.gd（复合格）
const CONCEPT_HOTMAP := "hotmap"                             # core/hotmap.gd + core/editor_view_state.gd（作弊信息状态机）

const CONCEPT_ORDER: Array[String] = [
	CONCEPT_CELL_PAINT, CONCEPT_CELL_KINDS, CONCEPT_SHAPE_LIBRARY, CONCEPT_BOUNDARY,
	CONCEPT_LAYOUT_RULES, CONCEPT_VARIANTS, CONCEPT_VERIFY_ISLANDS,
	CONCEPT_BOOLEAN_OPS, CONCEPT_SHAPE_DAG, CONCEPT_RASTER_PRECISION,
	CONCEPT_MEGA_CELL, CONCEPT_HOTMAP,
]

## 简单模式**必须隐藏**的进阶概念（文档十.6 明确点名 DAG / 精度 / 复合格；另加同级的布尔 / 热力图）。
const SIMPLE_HIDDEN: Array[String] = [
	CONCEPT_SHAPE_DAG, CONCEPT_RASTER_PRECISION, CONCEPT_MEGA_CELL,
	CONCEPT_BOOLEAN_OPS, CONCEPT_HOTMAP,
]

const CONCEPT_LABELS := {
	CONCEPT_CELL_PAINT: "画笔 / 橡皮 / 矩形填充（画格工具）",
	CONCEPT_CELL_KINDS: "格型：地雷 / 障碍 / 初始已翻开",
	CONCEPT_SHAPE_LIBRARY: "形状族（六边形 / 三角 / 圆 / 星 / 扇）",
	CONCEPT_BOUNDARY: "边界与邻域（环绕边界 / 邻域偏移 / 含自身）",
	CONCEPT_LAYOUT_RULES: "布局规则（雷怎么摆）",
	CONCEPT_VARIANTS: "变体与线索规则",
	CONCEPT_VERIFY_ISLANDS: "验证：可解 / 需猜（按岛分别判定）",
	CONCEPT_BOOLEAN_OPS: "形状布尔运算（并 / 交 / 差 / 异或）",
	CONCEPT_SHAPE_DAG: "形状依赖图（DAG：形状链 / 布尔链）",
	CONCEPT_RASTER_PRECISION: "栅格精度（圆 / 星形的 precision）",
	CONCEPT_MEGA_CELL: "复合格（多格合并成「逻辑一格」）",
	CONCEPT_HOTMAP: "猜点热力图（复盘 / 作弊信息）",
}

## 简单模式下「为什么先隐藏」的人话原因（键与 SIMPLE_HIDDEN 对齐）。
const CONCEPT_WHY_HIDDEN := {
	CONCEPT_SHAPE_DAG: "形状链 / 布尔链是三层依赖结构，新手先学会画格子与选形状即可；用列表存链还会在删除中间形状时悬空，属进阶。",
	CONCEPT_RASTER_PRECISION: "精度是「形状细则」旋钮（圆按内接正 precision 边形栅格化）；先按默认精度出形状，避免一上来就调参。",
	CONCEPT_MEGA_CELL: "复合格会改变「一格」的语义（逻辑一格 vs 基础格），新手容易把密度与雷数算错。",
	CONCEPT_BOOLEAN_OPS: "布尔运算属形状组合进阶，须先理解单个形状族本身。",
	CONCEPT_HOTMAP: "热力图是复盘 / 验证用的高级作弊信息（受编辑·试玩状态机管控），简单模式先只看数字。",
}

const REASON_SIMPLE := "简单模式只保留「先能画出一关」需要的概念（画笔·格型·形状族·边界邻域·布局规则·变体·验证）；" \
	+ "DAG / 栅格精度 / 复合格 / 布尔运算 / 热力图 默认隐藏——文档十.6：本编辑器概念量是普通编辑器的三倍，模板库是主要入门路径，一次只教一步。"
const REASON_EXPERT := "专家模式暴露全部概念（含形状 DAG / 布尔运算 / 栅格精度 / 复合格 / 热力图），供直接编辑形状链与复盘。"


# ==================== 模板清单 ====================

## 全部模板（纯数据，每次现造 ⇒ 调用方拿到的是可自由改的副本，不会污染库）。
## 每条 = {id, name, desc, tier, doc_build}；doc_build 的字段名见 DOC_FIELDS。
static func all_templates() -> Array:
	return [
		{
			"id": "tutorial_open_5x5",
			"name": "新手 · 5×5 全开放盘",
			"desc": "最小可玩盘：5×5 全开放（无洞）、只有经典扫雷规则。先用画笔摆几颗雷，再点试玩。",
			"tier": TIER_TUTORIAL,
			"doc_build": {
				"title": "新手 5x5 全开放",
				"rows": 5,
				"cols": 5,
				"shape_kind": "",
				"shape_params": {},
				"mines": [Vector2i(1, 1), Vector2i(3, 2), Vector2i(2, 4)],
				"obstacles": [],
				"revealed": {Vector2i(0, 0): null, Vector2i(1, 0): null, Vector2i(0, 1): null},
			},
		},
		{
			"id": "tutorial_ring_2ring",
			"name": "新手 · 甜甜圈入门（双环）",
			"desc": "甜甜圈形状的最小版：2 圈共 18 格（6 + 12 扇区），角向首尾相接。用最小的环形盘先感受「环绕」手感。",
			"tier": TIER_TUTORIAL,
			"doc_build": {
				"title": "新手 甜甜圈入门",
				"rows": 2,
				"cols": 12,
				"shape_kind": "ring",
				"shape_params": {"sectors": [6, 12], "step_deg": 10.0, "r0": 1.0, "dr": 1.0},
				"mines": [Vector2i(0, 0), Vector2i(3, 1)],
				"obstacles": [],
				"revealed": {Vector2i(1, 0): null},
			},
		},
		{
			"id": "official_donut_ring",
			"name": "甜甜圈（环形盘）",
			"desc": "官方示例：3 圈同心环（6 / 12 / 18 扇区，共 36 格），角向首尾相接 = 拓扑上的环（甜甜圈）。形状族 = ring。",
			"tier": TIER_OFFICIAL,
			"doc_build": {
				"title": "甜甜圈（环形）",
				"rows": 3,
				"cols": 18,
				"shape_kind": "ring",
				"shape_params": {"sectors": [6, 12, 18], "step_deg": 10.0, "r0": 1.0, "dr": 1.0},
				"mines": [Vector2i(0, 0), Vector2i(3, 1), Vector2i(9, 2)],
				"obstacles": [],
				"revealed": {Vector2i(1, 0): null},
			},
		},
		{
			"id": "official_double_island",
			"name": "双岛",
			"desc": "官方示例：7×7 盘中间一整列挖空（洞 = 格不存在），把盘切成左 / 右两块互不连通的岛。" \
				+ "近似说明：本仓没有专门的「多岛屿底板」形状族（W8 待建），故用 holed_grid 挖洞近似，语义等价于两块独立棋盘。",
			"tier": TIER_OFFICIAL,
			"doc_build": {
				"title": "双岛",
				"rows": 7,
				"cols": 7,
				"shape_kind": "holed_grid",
				"shape_params": {
					"rows": 7, "cols": 7,
					"holes": [
						{"x": 3, "y": 0}, {"x": 3, "y": 1}, {"x": 3, "y": 2}, {"x": 3, "y": 3},
						{"x": 3, "y": 4}, {"x": 3, "y": 5}, {"x": 3, "y": 6},
					],
				},
				"mines": [Vector2i(0, 0), Vector2i(5, 6), Vector2i(4, 3)],
				"obstacles": [],
				"revealed": {Vector2i(1, 0): null},
			},
		},
		{
			"id": "official_moat",
			"name": "护城河",
			"desc": "官方示例：7×7 盘中心挖掉 3×3 空院，四周留一圈 40 格的「护城河」。" \
				+ "近似说明：本仓没有独立的「护城河」形状族，用 holed_grid 中心挖洞实现（洞 = 格不存在）。",
			"tier": TIER_OFFICIAL,
			"doc_build": {
				"title": "护城河",
				"rows": 7,
				"cols": 7,
				"shape_kind": "holed_grid",
				"shape_params": {
					"rows": 7, "cols": 7,
					"holes": [
						{"x": 2, "y": 2}, {"x": 3, "y": 2}, {"x": 4, "y": 2},
						{"x": 2, "y": 3}, {"x": 3, "y": 3}, {"x": 4, "y": 3},
						{"x": 2, "y": 4}, {"x": 3, "y": 4}, {"x": 4, "y": 4},
					],
				},
				"mines": [Vector2i(0, 0), Vector2i(6, 3), Vector2i(3, 0)],
				"obstacles": [],
				"revealed": {Vector2i(0, 1): null},
			},
		},
	]


static func ids() -> Array[String]:
	var out: Array[String] = []
	for t: Dictionary in all_templates():
		out.append(str(t["id"]))
	return out


static func has_template(template_id: String) -> bool:
	return not find_template(template_id).is_empty()


## 按 id 取模板（副本）。找不到 ⇒ 空字典（调用方据此兜底，不崩）。
static func find_template(template_id: String) -> Dictionary:
	for t: Dictionary in all_templates():
		if str(t["id"]) == template_id:
			return t
	return {}


## 取某档位的模板（tier ∈ TIER_ORDER）；未知档位 ⇒ 空数组。
static func templates_of_tier(tier: String) -> Array:
	var out: Array = []
	for t: Dictionary in all_templates():
		if str(t["tier"]) == tier:
			out.append(t)
	return out


# ==================== 应用 ====================

## 取模板的 doc_build。返回 {ok, doc_build, reason}；未知 id ⇒ ok=false + 可读原因（不崩）。
static func apply(template_id: String) -> Dictionary:
	var t := find_template(template_id)
	if t.is_empty():
		return {
			"ok": false,
			"doc_build": {},
			"reason": "未知模板 id「%s」；可用模板：%s" % [template_id, ", ".join(ids())],
		}
	return {"ok": true, "doc_build": (t["doc_build"] as Dictionary).duplicate(true), "reason": ""}


## 按模板 id 造一个 EditorDoc（不写盘）。未知 id ⇒ null。
static func build_doc(template_id: String) -> EditorDoc:
	var r := apply(template_id)
	if not bool(r["ok"]):
		return null
	var doc := EditorDoc.new()
	apply_to_doc(doc, r["doc_build"])
	return doc


## 把 doc_build 写进现有 EditorDoc（只碰 DOC_FIELDS，其余字段保持原样；形状盘顺手同步行列）。
static func apply_to_doc(doc: EditorDoc, doc_build: Dictionary) -> void:
	if doc == null:
		return
	doc.title = str(doc_build.get("title", doc.title))
	doc.rows = int(doc_build.get("rows", doc.rows))
	doc.cols = int(doc_build.get("cols", doc.cols))
	doc.mines.assign(_vec_array(doc_build.get("mines", [])))
	doc.obstacles.assign(_vec_array(doc_build.get("obstacles", [])))
	doc.revealed = _revealed_map(doc_build.get("revealed", {}))
	doc.shape_kind = str(doc_build.get("shape_kind", ""))
	var sp: Variant = doc_build.get("shape_params", {})
	doc.shape_params = (sp as Dictionary).duplicate(true) if sp is Dictionary else {}
	if doc.shape_kind != "":
		# 形状盘的 size 必须与拓扑自洽（否则雷位全越界）；口径与 UI 选形状后一致。
		doc.sync_size_to_shape()


# ==================== 概念可见性（简单 / 专家模式）====================

## 返回 {mode, visible, hidden, labels, why_hidden, reason}。
## 简单模式**必须**隐藏 DAG / 精度 / 复合格（文档十.6）；专家模式全部可见。
## 未知模式按简单模式处理（fail-safe，并在 reason 里注明）。
static func concepts_for(mode: String) -> Dictionary:
	var simple := mode != MODE_EXPERT
	var resolved := MODE_SIMPLE if simple else MODE_EXPERT
	var visible: Array[String] = []
	var hidden: Array[String] = []
	for c: String in CONCEPT_ORDER:
		if simple and SIMPLE_HIDDEN.has(c):
			hidden.append(c)
		else:
			visible.append(c)
	var why: Dictionary = {}
	for c: String in hidden:
		why[c] = str(CONCEPT_WHY_HIDDEN.get(c, ""))
	var reason := REASON_SIMPLE if simple else REASON_EXPERT
	if mode != MODE_SIMPLE and mode != MODE_EXPERT:
		reason = "未知模式「%s」已按简单模式处理（fail-safe：宁可少暴露概念，也不一次压垮新手）。" % mode + reason
	return {
		"mode": resolved,
		"visible": visible,
		"hidden": hidden,
		"labels": CONCEPT_LABELS.duplicate(),
		"why_hidden": why,
		"reason": reason,
	}


# ==================== 内部工具 ====================

## 坐标归一：Vector2i / Vector2 / {"x","y"} → Vector2i（其余 → Vector2i.ZERO）。
static func _to_vec(v: Variant) -> Vector2i:
	if v is Vector2i:
		return v
	if v is Vector2:
		return Vector2i(int(v.x), int(v.y))
	if v is Dictionary:
		return Vector2i(int(v.get("x", 0)), int(v.get("y", 0)))
	return Vector2i.ZERO


static func _vec_array(raw: Variant) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if raw is Array:
		for e: Variant in raw:
			out.append(_to_vec(e))
	elif raw is Dictionary:
		for k: Variant in raw:
			out.append(_to_vec(k))
	return out


static func _revealed_map(raw: Variant) -> Dictionary:
	var out: Dictionary = {}
	if raw is Dictionary:
		for k: Variant in raw:
			out[_to_vec(k)] = null
	elif raw is Array:
		for e: Variant in raw:
			out[_to_vec(e)] = null
	return out
