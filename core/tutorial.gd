# tutorial.gd —— 教程盘面解析（对标游戏 doc10 §1.3）
#
# 教程用与谜题库**完全不同**的自定义文本格式（谜题库是 JSON，教程是制表符分隔的纯文本）：
#   · 按 `\n` 分行、按 `\t` 分列；**各行列数必须相等**（否则 `error = "Problem is not rectangular"`）
#   · 单元格可带 `{注解}` 前缀，写入独立的注解列表（用于教学标注）
#   · 以 `?` 开头的行终止盘面定义，其后为**提示正文**
#   · **空单元格**用于在视觉上分隔主板与副板；一旦出现空单元格则 has_empty = true
#
# 注解标记（对标 61 个教学盘面归纳）：
#   `@!`         高亮强调（教学重点格）
#   `@<clue>`    标注「这是一个线索」并给出取值（取值写在注解之后的单元格文本里）
#   `@<hover>`   标注「鼠标悬停示意」
#   `@x<wrong>`  标注「这是错误标记」（红色叉）
class_name Tutorial
extends RefCounted

const TAG_EMPHASIS := "!"
const TAG_CLUE := "clue"
const TAG_HOVER := "hover"
const TAG_WRONG := "wrong"


## 解析教程文本。返回：
##   { "rows": Array[Array[Dictionary]],  # 每格 {"value": String, "annotations": Array[String]}
##     "cols": int,
##     "has_empty": bool,                 # 含空单元格（主板/副板分隔）
##     "text": String,                    # `?` 行之后的提示正文
##     "error": String }                  # "" = 解析成功
static func parse(src: String) -> Dictionary:
	var rows: Array = []
	var text_lines: Array = []
	var in_text := false
	var has_empty := false
	var cols := -1
	var error := ""

	for raw in src.split("\n"):
		var line := str(raw)
		# 去掉行尾 \r（Windows 行尾），保留前导制表符（首列可能为空）
		if line.ends_with("\r"):
			line = line.substr(0, line.length() - 1)
		if in_text:
			text_lines.append(line)
			continue
		if line.begins_with("?"):
			in_text = true
			text_lines.append(line.substr(1))
			continue
		if line.strip_edges() == "":
			continue  # 空行（文件尾部/排版用）不算盘面行
		var cells: Array = []
		for raw_cell in line.split("\t", true):
			var cell := _parse_cell(str(raw_cell))
			if str(cell["value"]) == "" and (cell["annotations"] as Array).is_empty():
				has_empty = true
			cells.append(cell)
		if cols < 0:
			cols = cells.size()
		elif cells.size() != cols:
			error = "Problem is not rectangular"
		rows.append(cells)

	return {
		"rows": rows,
		"cols": maxi(cols, 0),
		"has_empty": has_empty,
		"text": "\n".join(text_lines).strip_edges(),
		"error": error,
	}


## 单元格解析：剥掉前导的一个或多个 `{注解}`，余下为取值。
static func _parse_cell(raw: String) -> Dictionary:
	var annotations: Array = []
	var s := raw.strip_edges()
	while s.begins_with("{"):
		var close := s.find("}")
		if close < 0:
			break  # 未闭合 → 当作普通文本，不再剥
		annotations.append(s.substr(1, close - 1))
		s = s.substr(close + 1)
	return {"value": s, "annotations": annotations}


## 注解是否表示「错误标记」（红叉）：`x<wrong>` / `@x<wrong>`。
static func is_wrong(annotations: Array) -> bool:
	for a in annotations:
		if _normalize(a).begins_with("x"):
			return true
	return false


## 注解是否表示「高亮强调」：`!` / `@!`。
static func is_emphasis(annotations: Array) -> bool:
	for a in annotations:
		if _normalize(a) == TAG_EMPHASIS:
			return true
	return false


## 注解是否表示「悬停示意」：`<hover>` / `@<hover>`。
static func is_hover(annotations: Array) -> bool:
	for a in annotations:
		if _normalize(a).find("hover") >= 0:
			return true
	return false


## 注解是否表示「线索标注」：其余非空注解（如 `<clue>` / `@<clue>`）。
static func is_clue(annotations: Array) -> bool:
	for a in annotations:
		var t := _normalize(a)
		if t.is_empty() or t == TAG_EMPHASIS or t.begins_with("x") or t.find("hover") >= 0:
			continue
		return true
	return false


## 归一化注解：去掉前导 `@`，去掉 `<...>` 尖括号占位符。
## 文档写法是 `{@<clue>}V4` / `{@x<wrong>}q`，即注解带 `@` 前缀、占位名带尖括号。
static func _normalize(a: Variant) -> String:
	var t := str(a).strip_edges()
	if t.begins_with("@"):
		t = t.substr(1)
	return t.replace("<", "").replace(">", "")


# ============ 目录与加载 ============

const DIR := "res://levels/tutorial"


## 列出全部教程页 id（形如 `tutorial_[1B]_0`），按名称排序保证顺序稳定。
static func list_ids() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".txt"):
			out.append(name.substr(0, name.length() - 4))
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


## 加载一页教程。不存在或解析失败返回 {"error": ...}。
static func load_page(id: String) -> Dictionary:
	var path := "%s/%s.txt" % [DIR, id]
	if not FileAccess.file_exists(path):
		return {"rows": [], "cols": 0, "has_empty": false, "text": "", "error": "not found: %s" % id}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"rows": [], "cols": 0, "has_empty": false, "text": "", "error": "open failed: %s" % id}
	var src := f.get_as_text()
	f.close()
	var page := parse(src)
	page["id"] = id
	return page


## 取某个规则组合下的全部页 id（`tutorial_<组合>_<序号>`），按序号数值排序。
static func pages_for(combo: String) -> Array[String]:
	var prefix := "tutorial_%s_" % combo
	var out: Array[String] = []
	for id in list_ids():
		if id.begins_with(prefix):
			out.append(id)
	out.sort_custom(func(a: String, b: String) -> bool:
		return int(a.substr(prefix.length())) < int(b.substr(prefix.length())))
	return out
