class_name LevelFormat
extends RefCounted

## 关卡格式内核：结果层 / 设计层分离 + 版本迁移 + 原型引用 + UUID 派生 + 体积护栏。
##
## 【为什么必须先分层（文档「八、导入导出」的核心架构决策）】
##   · **结果层** 只放游戏必需项（格子 / 雷 / 规则 / 拓扑 / 原型几何）——游戏开局**只读它**，
##     不去解析形状定义。否则 5000 格异形盘光"解析形状"就要把加载时间翻倍。
##   · **设计层** 放"这张盘是怎么造出来的"（形状族、形状参数、生成种子/参数、备注）。
##     它坏了游戏照样能玩，只是编辑器无法再编辑 ⇒ 故障被隔离在编辑侧，不传染给玩家。
##   两层字段**互不重叠**（本文件用显式键表保证，由单测钉死）。
##
## 【版本迁移纪律：只增不改不删】
##   格式带版本号；新版本只**新增**字段，绝不改名 / 删字段 / 改语义。
##   `migrate()` 把 v1 / v2 逐级补上缺失的新字段（旧字段原样保留）到 `CURRENT_VERSION`。
##   遇到**高于**本程序支持版本的文件 ⇒ **拒载**并给出可读原因（绝不猜更高版本的语义）。
##
## 【E① 原型引用制】格子只存 `prototype_id + transform`，顶点只在 `prototypes` 库存一份。
## 【E④ UUID 派生制】生成的格子**不存** UUID，用 `derive_id(seed, pos)` 从「种子 + 坐标」
##   确定性派生；只有**被手工改过**的格子才显式写 `manual_identity`。
## 【E③ 坐标量化】几何坐标定点整数，1/65536 量化（同一 2^-16 栅格，本项目新增的统一口径；
##   本仓原无此约定，规格由本次落地定义）。
##
## 【模块独立性】本文件只吃 / 吐 `Dictionary`，**不依赖 `EditorDoc` 类**——唯一例外是
##   只读复用它的 `MAX_CELL_BUDGET` 常量（口径单一真源）。这样批量生产 / 工坊打包 / 玩家侧
##   都能直接用，不必先建一个编辑器文档对象。

const CURRENT_VERSION := 3

## 坐标量化口径：几何坐标 = round(浮点 × QUANT) 的整数。1/65536 = 本项目新增的统一口径
## （本仓原无此约定，规格由本次落地定义）。
const QUANT := 65536

## 体积/格数硬上限复用编辑器口径（**只读**，绝不改它）。
const MAX_CELL_BUDGET := EditorDoc.MAX_CELL_BUDGET

## 结果层字段（游戏必需项；游戏侧只认这些）。
const RESULT_KEYS: Array = [
	"version", "size", "total_mines", "cells", "revealed", "rule", "topology", "prototypes",
]

## 设计层字段（编辑器必需项；游戏侧一概不读）。
const DESIGN_KEYS: Array = [
	"name", "shape_kind", "shape_params", "generation", "blueprint", "notes", "editor_meta",
]

## 输入文档里"已被消费进结果层"的字段（迁移 / 拆分时不再原样抄进设计层，避免冗余双存）。
const CONSUMED_INPUT: Array = [
	"version", "schema", "size", "rows", "cols", "total_mines", "mines", "revealed",
	"cells", "rule", "rule_level", "clue_rule", "rule_spec", "custom", "topology", "prototypes",
]


# ==================== 坐标量化（E③，1/65536）====================

## 浮点 → 定点整数（四舍五入）。用本项目新增的统一坐标口径
## （本仓原无此约定，规格由本次落地定义）；往返误差 ≤ 1/65536 由单测钉死。
static func quantize(v: float) -> int:
	return roundi(v * float(QUANT))


## 定点整数 → 浮点。往返误差 ≤ 1/65536（由单测钉死）。
static func dequantize(q: int) -> float:
	return float(q) / float(QUANT)


## 量化一个 {x, y} 点 → [qx, qy]。
static func quantize_point(p: Dictionary) -> Array:
	return [quantize(float(p.get("x", 0.0))), quantize(float(p.get("y", 0.0)))]


## 量化一组顶点。顶点两种写法都收：{x, y} 字典、或 [x, y] 数组。
static func quantize_vertices(verts: Variant) -> Array:
	var out: Array = []
	if not (verts is Array):
		return out
	for v in (verts as Array):
		if v is Dictionary:
			out.append(quantize_point(v as Dictionary))
		elif v is Array and (v as Array).size() >= 2:
			var a: Array = v
			out.append([quantize(float(a[0])), quantize(float(a[1]))])
	return out


# ==================== E④ UUID 派生 ====================

## 从「种子 + 坐标」确定性派生格子身份。
## **与字典遍历顺序无关**：坐标一律按 `r`、`c` 显式取值拼成规范串，绝不迭代字典键。
static func derive_id(seed: int, pos: Variant) -> String:
	var r := 0
	var c := 0
	if pos is Vector2i:
		var p := pos as Vector2i
		r = p.y
		c = p.x
	elif pos is Dictionary:
		var d: Dictionary = pos
		r = int(d.get("r", 0))
		c = int(d.get("c", 0))
	elif pos is Array and (pos as Array).size() >= 2:
		var a: Array = pos
		r = int(a[0])
		c = int(a[1])
	var canonical := "%d:%d:%d" % [seed, r, c]
	# 双 FNV-1a（不同盐）拼成 16 位十六进制，降低碰撞面。
	var h1 := _fnv1a(canonical)
	var h2 := _fnv1a("salt|%s" % canonical)
	return "lv_%08x%08x" % [h1, h2]


## 位置的规范键（`r,c`，显式顺序 ⇒ 与字典插入顺序无关）。
static func pos_key(pos: Variant) -> String:
	var r := 0
	var c := 0
	if pos is Vector2i:
		r = (pos as Vector2i).y
		c = (pos as Vector2i).x
	elif pos is Dictionary:
		var d: Dictionary = pos
		r = int(d.get("r", 0))
		c = int(d.get("c", 0))
	elif pos is Array and (pos as Array).size() >= 2:
		var a: Array = pos
		r = int(a[0])
		c = int(a[1])
	return "%d,%d" % [r, c]


## 该格是否需要**显式**身份映射（E④）：只有被手工改过、或已带 `manual_identity` 的格子才需要；
## 生成的格子一律靠 `derive_id(seed, pos)` 派生，不落盘 UUID（省体积）。
static func needs_explicit_identity(cell: Dictionary) -> bool:
	if str(cell.get("manual_identity", "")) != "":
		return true
	if str(cell.get("identity_source", "")) == "manual":
		return true
	return bool(cell.get("edited", false))


## 取一格的最终身份：显式 `manual_identity` 优先，否则从种子 + 坐标派生。
static func identity_of(cell: Dictionary, seed: int) -> String:
	var mid := str(cell.get("manual_identity", ""))
	if mid != "":
		return mid
	return derive_id(seed, {"r": int(cell.get("r", 0)), "c": int(cell.get("c", 0))})


## 收集"需要显式身份"的格子映射：位置键 → 身份。返回空 = 全部可派生（无需落盘身份）。
static func manual_identities(cells: Variant) -> Dictionary:
	var out := {}
	if not (cells is Array):
		return out
	for c in (cells as Array):
		if not (c is Dictionary):
			continue
		var d: Dictionary = c
		if needs_explicit_identity(d):
			out[pos_key(d)] = identity_of(d, 0)
	return out


# ==================== 两层拆分 ====================

## 文档 → 结果层（**游戏必需项**：尺寸 / 雷 / 已翻开 / 规则 / 拓扑 / 原型几何 / 格子）。
## 结果层里**绝不**出现 `DESIGN_KEYS` 任何字段（由单测钉死）。
static func to_result_layer(doc: Dictionary) -> Dictionary:
	var out := {}
	out["version"] = int(doc.get("version", doc.get("schema", CURRENT_VERSION)))
	out["size"] = _normalize_size(doc)
	out["total_mines"] = _total_mines(doc)
	out["cells"] = _cells_of(doc)
	out["revealed"] = _revealed_of(doc)
	out["rule"] = _rule_of(doc)
	if doc.get("topology", null) is Dictionary:
		out["topology"] = (doc["topology"] as Dictionary).duplicate(true)
	out["prototypes"] = _prototypes_of(doc)
	return out


## 文档 → 设计层（**编辑器必需项**：形状族 / 形状参数 / 生成参数 / 备注）。
## 未识别的字段也收进设计层 ⇒ 不丢数据；且这些键必然不在 `RESULT_KEYS` 里 ⇒ 两层不重叠。
static func to_design_layer(doc: Dictionary) -> Dictionary:
	var out := {}
	for k in DESIGN_KEYS:
		if doc.has(k):
			out[k] = _dup(doc[k])
	if not out.has("name") and doc.has("title"):
		out["name"] = str(doc["title"])
	for k in doc.keys():
		var ks := str(k)
		if RESULT_KEYS.has(ks) or CONSUMED_INPUT.has(ks) or out.has(ks):
			continue
		out[ks] = _dup(doc[k])
	return out


## 只读结果层开局。**输入可以是"信封"（含 result / design）也可以是纯结果层**；
## 无论哪种，本函数**只读**结果层 —— 设计层缺失 / 损坏 / 是垃圾，都不影响开局（单测钉死）。
## 返回 `{ok, reason, level}`：`level` 是 `Board.load_level` 能直接吃的关卡字典。
static func load_result(layer: Dictionary) -> Dictionary:
	var r: Dictionary = layer
	if layer.get("result", null) is Dictionary:
		r = layer["result"] as Dictionary
	var size_v: Variant = r.get("size", {})
	if not (size_v is Dictionary):
		return {"ok": false, "reason": "结果层缺少 size（无法开局）", "level": {}}
	var rows := int((size_v as Dictionary).get("rows", 0))
	var cols := int((size_v as Dictionary).get("cols", 0))
	if rows < 1 or cols < 1:
		return {"ok": false, "reason": "结果层尺寸非法（%dx%d）" % [rows, cols], "level": {}}
	var cells: Array = []
	if r.get("cells", null) is Array:
		cells = (r["cells"] as Array).duplicate(true)
	var mines: Array = []
	for c in cells:
		if c is Dictionary and bool((c as Dictionary).get("mine", false)):
			var d: Dictionary = c
			mines.append({"r": int(d.get("r", 0)), "c": int(d.get("c", 0))})
	var level := {
		"version": int(r.get("version", CURRENT_VERSION)),
		"size": {"rows": rows, "cols": cols},
		"total_mines": int(r.get("total_mines", mines.size())),
		"mines": mines,
		"revealed": _dup(r.get("revealed", [])),
		"cells": cells,
		"prototypes": _dup(r.get("prototypes", {})),
	}
	if r.get("rule", null) is Dictionary:
		level["rule"] = (r["rule"] as Dictionary).duplicate(true)
	if r.get("topology", null) is Dictionary:
		level["topology"] = (r["topology"] as Dictionary).duplicate(true)
	return {"ok": true, "reason": "", "level": level}


# ==================== 版本迁移（只增不改不删）====================

## 迁移到 `CURRENT_VERSION`。返回 `{ok, reason, from_version, version, doc}`。
##   · 旧版本：逐级补上缺失的新字段（**旧字段原样保留**）。
##   · 未知更高版本：`ok=false` + 可读原因（**不猜**语义）。
static func migrate(old: Dictionary) -> Dictionary:
	var from := version_of(old)
	if from > CURRENT_VERSION:
		return {
			"ok": false,
			"reason": "格式版本 v%d 高于本程序支持的最高版本 v%d，拒绝加载（不猜测更高版本的语义）" % [from, CURRENT_VERSION],
			"from_version": from, "version": from, "doc": {},
		}
	var doc := old.duplicate(true)
	var v := from
	if v <= 1:
		doc = _upgrade_v1_to_v2(doc)
		v = 2
	if v <= 2:
		doc = _upgrade_v2_to_v3(doc)
		v = 3
	doc["version"] = CURRENT_VERSION
	return {"ok": true, "reason": "", "from_version": from, "version": CURRENT_VERSION, "doc": doc}


## 判定一份文档的版本号：`version` 优先，其次旧字段 `schema`，都没有 ⇒ 视作 v1。
static func version_of(old: Dictionary) -> int:
	if old.has("version"):
		return int(old["version"])
	if old.has("schema"):
		return int(old["schema"])
	return 1


## v1 → v2：只**新增** `size` / `revealed` / `total_mines`；`rows` / `cols` / `mines` / `name` 原样保留。
static func _upgrade_v1_to_v2(doc: Dictionary) -> Dictionary:
	var out := doc.duplicate(true)
	if not out.has("size"):
		out["size"] = {"rows": int(out.get("rows", 0)), "cols": int(out.get("cols", 0))}
	if not (out.get("revealed", null) is Array):
		out["revealed"] = []
	if not out.has("total_mines"):
		out["total_mines"] = _cell_list(out.get("mines", [])).size()
	return out


## v2 → v3：只**新增** `cells` / `prototypes` / `rule`（把旧字段翻译过来，旧字段本身不动）。
static func _upgrade_v2_to_v3(doc: Dictionary) -> Dictionary:
	var out := doc.duplicate(true)
	if not (out.get("cells", null) is Array):
		out["cells"] = _cells_of(out)
	if not (out.get("prototypes", null) is Dictionary):
		out["prototypes"] = {}
	if not (out.get("rule", null) is Dictionary):
		out["rule"] = _rule_of(out)
	return out


# ==================== 体积护栏 ====================

## 写入前的体积 / 格数估算。格数上限复用 `EditorDoc.MAX_CELL_BUDGET`；超限 **block** 并给可读原因。
## 返回 `{ok, level, cells, est_bytes, reason}`。
static func check_write_budget(payload: Dictionary) -> Dictionary:
	var cells := count_cells(payload)
	var est_bytes := estimate_bytes(payload)
	if cells > MAX_CELL_BUDGET:
		return {
			"ok": false, "level": "block", "cells": cells, "est_bytes": est_bytes,
			"reason": "预计 %d 格，超过最高上限 %d（拒绝写入：编辑器与加载器都扛不住）" % [cells, MAX_CELL_BUDGET],
		}
	return {"ok": true, "level": "ok", "cells": cells, "est_bytes": est_bytes, "reason": ""}


## 估格数：显式 `cells` 优先，其次 `mines`，最后按 `size`（rows×cols）估算。
static func count_cells(payload: Dictionary) -> int:
	var p := _unwrap(payload)
	if p.get("cells", null) is Array and not (p["cells"] as Array).is_empty():
		return (p["cells"] as Array).size()
	if p.get("mines", null) is Array and not (p["mines"] as Array).is_empty():
		return (p["mines"] as Array).size()
	var s: Variant = p.get("size", {})
	if s is Dictionary:
		return maxi(int((s as Dictionary).get("rows", 0)), 0) * maxi(int((s as Dictionary).get("cols", 0)), 0)
	return maxi(int(p.get("rows", 0)), 0) * maxi(int(p.get("cols", 0)), 0)


## 粗估 JSON 字节数（每格 ~32B + 顶点几何 + 信封开销），仅作提示，不作硬阈值。
static func estimate_bytes(payload: Dictionary) -> int:
	var p := _unwrap(payload)
	var total := count_cells(p) * 32 + 128
	var pr: Variant = p.get("prototypes", {})
	if pr is Dictionary:
		for k in (pr as Dictionary).keys():
			var e: Variant = (pr as Dictionary)[k]
			if e is Dictionary and (e as Dictionary).get("vertices", null) is Array:
				total += ((e as Dictionary)["vertices"] as Array).size() * 16
	return total


# ==================== 内部 ====================

## 信封（{version, result, design}）→ 结果层；纯结果层原样返回。
static func _unwrap(payload: Dictionary) -> Dictionary:
	if payload.get("result", null) is Dictionary:
		return payload["result"] as Dictionary
	return payload


static func _normalize_size(doc: Dictionary) -> Dictionary:
	var s: Variant = doc.get("size", null)
	if s is Dictionary:
		return {"rows": int((s as Dictionary).get("rows", 0)), "cols": int((s as Dictionary).get("cols", 0))}
	return {"rows": int(doc.get("rows", 0)), "cols": int(doc.get("cols", 0))}


static func _total_mines(doc: Dictionary) -> int:
	if doc.has("total_mines"):
		return int(doc["total_mines"])
	return _cell_list(doc.get("mines", [])).size()


## 结果层格子：显式 `cells` 优先；否则由 `mines` / `revealed` 派生（保留雷 / 原型引用 / 身份）。
static func _cells_of(doc: Dictionary) -> Array:
	var raw: Variant = doc.get("cells", null)
	if raw is Array and not (raw as Array).is_empty():
		var listed: Array = []
		for c in (raw as Array):
			if c is Dictionary:
				listed.append(_normalize_cell(c as Dictionary))
		return listed
	var out: Array = []
	var seen := {}
	for m in _cell_list(doc.get("mines", [])):
		var key := pos_key(m)
		seen[key] = true
		out.append(_normalize_cell({"r": m["r"], "c": m["c"], "mine": true}))
	for rv in _cell_list(doc.get("revealed", [])):
		var key2 := pos_key(rv)
		if seen.has(key2):
			continue
		out.append(_normalize_cell({"r": rv["r"], "c": rv["c"]}))
	return out


static func _normalize_cell(cell: Dictionary) -> Dictionary:
	var out := {"r": int(cell.get("r", 0)), "c": int(cell.get("c", 0))}
	var pid := str(cell.get("prototype_id", ""))
	if pid != "":
		out["prototype_id"] = pid
	if cell.get("transform", null) is Dictionary:
		out["transform"] = _normalize_transform(cell["transform"] as Dictionary)
	if bool(cell.get("mine", false)):
		out["mine"] = true
	var mid := str(cell.get("manual_identity", ""))
	if mid != "":
		out["manual_identity"] = mid
	return out


static func _normalize_transform(t: Dictionary) -> Dictionary:
	return {
		"tx": quantize(float(t.get("tx", 0.0))),
		"ty": quantize(float(t.get("ty", 0.0))),
		"rot": int(t.get("rot", 0)) % 360,
		"flip": int(t.get("flip", 0)),
	}


static func _prototypes_of(doc: Dictionary) -> Dictionary:
	var out := {}
	var raw: Variant = doc.get("prototypes", null)
	if not (raw is Dictionary):
		return out
	for k in (raw as Dictionary).keys():
		var entry: Variant = (raw as Dictionary)[k]
		var verts: Variant = []
		if entry is Dictionary:
			verts = (entry as Dictionary).get("vertices", [])
		elif entry is Array:
			verts = entry
		out[str(k)] = {"vertices": quantize_vertices(verts)}
	return out


static func _revealed_of(doc: Dictionary) -> Array:
	var out: Array = []
	var raw: Variant = doc.get("revealed", [])
	if not (raw is Array):
		return out
	for rc in (raw as Array):
		if not (rc is Dictionary):
			continue
		var d: Dictionary = rc
		var e := {"r": int(d.get("r", 0)), "c": int(d.get("c", 0))}
		if d.has("interval"):
			e["interval"] = _dup(d["interval"])
		out.append(e)
	return out


static func _rule_of(doc: Dictionary) -> Dictionary:
	var out := {"id": "classic", "level": false}
	var rid := str(doc.get("clue_rule", ""))
	if rid == "" and doc.get("rule_spec", null) is Dictionary:
		rid = str((doc["rule_spec"] as Dictionary).get("id", ""))
	if rid != "":
		out["id"] = rid
	out["level"] = bool(doc.get("rule_level", false))
	if doc.get("rule_spec", null) is Dictionary and not (doc["rule_spec"] as Dictionary).is_empty():
		out["spec"] = (doc["rule_spec"] as Dictionary).duplicate(true)
	elif doc.get("custom", null) is Dictionary:
		var c: Dictionary = doc["custom"]
		if c.get("spec", null) is Dictionary and not (c["spec"] as Dictionary).is_empty():
			out["spec"] = (c["spec"] as Dictionary).duplicate(true)
	return out


## 归一化坐标列表：`{r, c}` 字典与 `[r, c]` 数组两种历史写法都收。
static func _cell_list(raw: Variant) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for it in (raw as Array):
		if it is Dictionary:
			var d: Dictionary = it
			out.append({"r": int(d.get("r", 0)), "c": int(d.get("c", 0))})
		elif it is Array and (it as Array).size() >= 2:
			var a: Array = it
			out.append({"r": int(a[0]), "c": int(a[1])})
	return out


static func _dup(v: Variant) -> Variant:
	if v is Dictionary:
		return (v as Dictionary).duplicate(true)
	if v is Array:
		return (v as Array).duplicate(true)
	return v


## 32 位 FNV-1a（确定性、跨平台、与字典顺序无关）。用 Unicode 码点，避免编码差异。
static func _fnv1a(text: String) -> int:
	var h := 2166136261
	for i in text.length():
		h = h ^ text.unicode_at(i)
		h = (h * 16777619) & 0xFFFFFFFF
	return h
