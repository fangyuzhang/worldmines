class_name LevelThumbnail
extends RefCounted

## 数据缩略图（缺口 #13 后半）：把关卡**结果层**压成一张**确定性**的索引网格，
## 供关卡列表 / 工坊卡片在**不起场景、不渲染**（headless 可测）的前提下预览盘面。
##
## 【为什么是"数据"缩略图而不是图片】
##   · 图卡渲染要起渲染管线 / 依赖视口尺寸 / 受设备与主题影响 ⇒ 同一关在不同机器上像素不同，
##     无法在 CI 里比对，也不能用于内容去重；
##   · 本模块只产出**纯数据**（索引网格 + 调色板图例 + 内容哈希）：同输入**逐位**同输出，
##     可 JSON 落盘、可跨进程比对、可用于"这关内容是否变过"的快速判定。
##
## 【网格语义：占用 / 编号】
##   每个位置一个**调色板索引**（`grid` 里的整数），`palette[index]` 给出它的**码**：
##     · `"empty"`     —— 该位置没有格子（未占用）；
##     · `"mine"`      —— 该位置有格子且是雷；
##     · `"clue:N"`    —— 该位置有格子且非雷，N = 其**相邻雷数**（编号）。
##   调色板按**码的规范排序**生成（empty → mine → clue 升序），且只收录**实际出现**的码；
##   因此同内容 ⇒ 同调色板 ⇒ 同索引网格，且索引值不随字典遍历顺序漂移。
##
## 【有界裁剪】`max_side` 是缩略图每边硬上限。源盘任一边超过上限 ⇒ 只保留**左上角**
##   `max_side × max_side` 区域（**裁剪**，非缩放——缩放会引入采样歧义、破坏确定性），
##   并置 `cropped=true`。UI 据此决定是否加"已裁剪"角标。
##
## 【相邻雷数口径】结果层可能带 `topology`（异形盘）。本模块**不解析拓扑**，一律按
##   矩形 8 邻域统计——这是缩略图用的**近似编号**，仅用于"看盘面密度 / 雷分布"，
##   **绝不参与玩法判定**（玩法线索由 Board / 规则内核算）。此取舍保证 headless 可测、零依赖。

## 缩略图数据版本（只增不改不删）。
const VERSION := 1

## 默认每边上限：32 足够列表卡片辨识盘面，又不至于让单张缩略图膨胀。
const DEFAULT_MAX_SIDE := 32

## 三个码前缀 / 常量。`empty` 恒排调色板首位（索引 0）。
const EMPTY_CODE := "empty"
const MINE_CODE := "mine"
const CLUE_PREFIX := "clue:"


# ==================== 对外 API ====================

## 从结果层（或信封 `{result:...}`）生成缩略图。**不抛异常**。
## 成功 ⇒ `{ok=true, reason="", version, max_side, rows, cols, src_rows, src_cols, cropped,
##           palette:Array[String], grid:Array[int], hash:String}`
## 失败 ⇒ `{ok=false, reason:<可读文本>}`
static func build(result_layer: Variant, max_side: int = DEFAULT_MAX_SIDE) -> Dictionary:
	if not (result_layer is Dictionary):
		return _error("结果层不是字典（无法生成缩略图）")
	if max_side < 1:
		return _error("缩略图边长上限非法（%d），必须 ≥ 1" % max_side)
	var layer: Dictionary = result_layer
	if layer.get("result", null) is Dictionary:      # 兼容信封 {result, design}
		layer = layer["result"] as Dictionary
	var size := _size_of(layer)
	if size.is_empty():
		return _error("结果层缺少合法尺寸（size.rows / size.cols 必须 ≥ 1）")
	var src_rows := int(size["rows"])
	var src_cols := int(size["cols"])
	var occ := _occupancy_of(layer, src_rows, src_cols)
	var rows := mini(src_rows, max_side)
	var cols := mini(src_cols, max_side)
	var cropped := rows < src_rows or cols < src_cols

	# 逐格算码（empty / mine / clue:N），同时收集实际出现的码集合。
	var codes: Array = []
	var seen := {}
	for r in rows:
		for c in cols:
			var key := "%d,%d" % [r, c]
			var code := EMPTY_CODE
			if occ.has(key):
				if bool(occ[key]):
					code = MINE_CODE
				else:
					code = CLUE_PREFIX + str(_neighbor_mines(occ, r, c))
			codes.append(code)
			seen[code] = true

	# 调色板：只收实际出现的码，按规范序（empty → mine → clue 升序）排序 ⇒ 索引确定。
	var palette: Array = seen.keys()
	palette.sort_custom(func(a: Variant, b: Variant) -> bool:
		return _code_rank(str(a)) < _code_rank(str(b)))
	var index_of := {}
	for i in palette.size():
		index_of[str(palette[i])] = i

	# 网格落成**调色板索引**。
	var grid: Array = []
	for code in codes:
		grid.append(int(index_of[str(code)]))

	return _canonical(VERSION, max_side, rows, cols, src_rows, src_cols, cropped, palette, grid)


## 规范化 / JSON 安全化：从任意（合法的）缩略图字段重建规范字典。
## 非法输入（非字典 / ok=false）⇒ `{}`。
static func to_dict(thumb: Variant) -> Dictionary:
	if not (thumb is Dictionary):
		return {}
	var t: Dictionary = thumb
	if not bool(t.get("ok", false)):
		return {}
	return _canonical(
		int(t.get("version", VERSION)),
		int(t.get("max_side", DEFAULT_MAX_SIDE)),
		int(t.get("rows", 0)),
		int(t.get("cols", 0)),
		int(t.get("src_rows", 0)),
		int(t.get("src_cols", 0)),
		bool(t.get("cropped", false)),
		_as_string_list(t.get("palette", [])),
		_as_int_list(t.get("grid", [])))


## 反序列化：从 `to_dict` / JSON 落盘的字典重建缩略图，逐位等价。**不抛异常**。
## 缺字段 / 类型非法 / 索引越界 ⇒ `{ok=false, reason:<可读文本>}`。
static func from_dict(d: Variant) -> Dictionary:
	if not (d is Dictionary):
		return _error("缩略图不是字典（无法反序列化）")
	var dd: Dictionary = d
	for k in ["version", "max_side", "rows", "cols", "src_rows", "src_cols", "palette", "grid"]:
		if not dd.has(k):
			return _error("缩略图缺少字段：%s" % k)
	var rows := int(dd.get("rows", 0))
	var cols := int(dd.get("cols", 0))
	var max_side := int(dd.get("max_side", 0))
	if rows < 1 or cols < 1 or max_side < 1:
		return _error("缩略图尺寸非法（rows=%d cols=%d max_side=%d）" % [rows, cols, max_side])
	var palette := _as_string_list(dd.get("palette", []))
	var grid := _as_int_list(dd.get("grid", []))
	if grid.size() != rows * cols:
		return _error("缩略图网格长度（%d）与尺寸不符（应为 %d）" % [grid.size(), rows * cols])
	if palette.is_empty():
		return _error("缩略图调色板为空（网格索引无处可查）")
	for v in grid:
		if v < 0 or v >= palette.size():
			return _error("缩略图网格索引越界（%d，调色板 %d 色）" % [v, palette.size()])
	return _canonical(
		int(dd.get("version", VERSION)), max_side, rows, cols,
		int(dd.get("src_rows", 0)), int(dd.get("src_cols", 0)),
		bool(dd.get("cropped", false)), palette, grid)


## 内容哈希（确定性、跨平台、与字典顺序无关）。非法 / 非成功缩略图 ⇒ 空串。
## 用途：同一关内容是否变过的快速判定、工坊卡片去重。
static func content_hash(thumb: Variant) -> String:
	if not (thumb is Dictionary):
		return ""
	var t: Dictionary = thumb
	if not bool(t.get("ok", false)):
		return ""
	return _content_hash_parts(
		int(t.get("version", 0)),
		int(t.get("max_side", 0)),
		int(t.get("rows", 0)),
		int(t.get("cols", 0)),
		int(t.get("src_rows", 0)),
		int(t.get("src_cols", 0)),
		bool(t.get("cropped", false)),
		_as_string_list(t.get("palette", [])),
		_as_int_list(t.get("grid", [])))


# ==================== 内部 ====================

## 规范字典（固定键序 ⇒ `to_dict` / `from_dict` / `build` 三者产出逐字节一致）。
static func _canonical(version: int, max_side: int, rows: int, cols: int,
		src_rows: int, src_cols: int, cropped: bool, palette: Array, grid: Array) -> Dictionary:
	var p: Array = palette.duplicate()
	var g: Array = grid.duplicate()
	var h := _content_hash_parts(version, max_side, rows, cols, src_rows, src_cols, cropped, p, g)
	return {
		"ok": true,
		"reason": "",
		"version": version,
		"max_side": max_side,
		"rows": rows,
		"cols": cols,
		"src_rows": src_rows,
		"src_cols": src_cols,
		"cropped": cropped,
		"palette": p,
		"grid": g,
		"hash": h,
	}


static func _content_hash_parts(version: int, max_side: int, rows: int, cols: int,
		src_rows: int, src_cols: int, cropped: bool, palette: Array, grid: Array) -> String:
	var s := "tn|v=%d|max=%d|r=%d|c=%d|sr=%d|sc=%d|cr=%d|p=%s|g=%s" % [
		version, max_side, rows, cols, src_rows, src_cols, 1 if cropped else 0,
		_join(palette, ","), _join(grid, ",")]
	return "tn_%08x" % _fnv1a(s)


## 取结果层尺寸；缺失 / 非法 ⇒ 空字典。
static func _size_of(layer: Dictionary) -> Dictionary:
	var s: Variant = layer.get("size", null)
	var rows := 0
	var cols := 0
	if s is Dictionary:
		rows = int((s as Dictionary).get("rows", 0))
		cols = int((s as Dictionary).get("cols", 0))
	if rows < 1 or cols < 1:
		rows = int(layer.get("rows", 0))
		cols = int(layer.get("cols", 0))
	if rows < 1 or cols < 1:
		return {}
	return {"rows": rows, "cols": cols}


## 占用表：键 `"r,c"` → 是否雷（仅含有格子的位置）。显式 `cells` 优先，否则由 `mines` + `revealed` 派生。
static func _occupancy_of(layer: Dictionary, rows: int, cols: int) -> Dictionary:
	var out := {}
	var cells: Variant = layer.get("cells", null)
	if cells is Array and not (cells as Array).is_empty():
		for it in (cells as Array):
			if not (it is Dictionary):
				continue
			var d: Dictionary = it
			var r := int(d.get("r", 0))
			var c := int(d.get("c", 0))
			if r < 0 or c < 0 or r >= rows or c >= cols:
				continue
			out["%d,%d" % [r, c]] = bool(d.get("mine", false))
		return out
	for m in _coords(layer.get("mines", [])):
		var r2 := int(m[0])
		var c2 := int(m[1])
		if r2 >= 0 and c2 >= 0 and r2 < rows and c2 < cols:
			out["%d,%d" % [r2, c2]] = true
	for rv in _coords(layer.get("revealed", [])):
		var r3 := int(rv[0])
		var c3 := int(rv[1])
		if r3 >= 0 and c3 >= 0 and r3 < rows and c3 < cols:
			var k := "%d,%d" % [r3, c3]
			if not out.has(k):
				out[k] = false
	return out


## 归一化坐标列表：`{r,c}` 与 `[r,c]` 两种历史写法都收。
static func _coords(raw: Variant) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for it in (raw as Array):
		if it is Dictionary:
			var d: Dictionary = it
			out.append([int(d.get("r", 0)), int(d.get("c", 0))])
		elif it is Array and (it as Array).size() >= 2:
			var a: Array = it
			out.append([int(a[0]), int(a[1])])
	return out


## 8 邻域雷数（矩形近似口径，见文件头说明）。
static func _neighbor_mines(occ: Dictionary, r: int, c: int) -> int:
	var n := 0
	for dr in [-1, 0, 1]:
		for dc in [-1, 0, 1]:
			if dr == 0 and dc == 0:
				continue
			var k := "%d,%d" % [r + dr, c + dc]
			if occ.has(k) and bool(occ[k]):
				n += 1
	return n


## 码的规范排序键：empty(0) < mine(1) < clue:N(2, 按 N 升序)。
static func _code_rank(code: String) -> int:
	if code == EMPTY_CODE:
		return 0
	if code == MINE_CODE:
		return 1
	if code.begins_with(CLUE_PREFIX):
		return 1000000 + int(code.substr(CLUE_PREFIX.length()))
	return 2000000


static func _as_string_list(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for x in (v as Array):
			out.append(str(x))
	return out


static func _as_int_list(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for x in (v as Array):
			out.append(int(x))
	return out


static func _join(arr: Array, sep: String) -> String:
	var out := ""
	for i in arr.size():
		if i > 0:
			out += sep
		out += str(arr[i])
	return out


static func _error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


## 32 位 FNV-1a（确定性、跨平台、与字典顺序无关）。用 Unicode 码点，避免编码差异。
static func _fnv1a(text: String) -> int:
	var h := 2166136261
	for i in text.length():
		h = h ^ text.unicode_at(i)
		h = (h * 16777619) & 0xFFFFFFFF
	return h
