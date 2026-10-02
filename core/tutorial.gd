# tutorial.gd —— 教程盘面解析（对标游戏 doc10 §1.3）
#
# 教程用与谜题库**完全不同**的自定义文本格式（谜题库是 JSON，教程是制表符分隔的纯文本）：
#   · 按 `\n` 分行、按 `\t` 分列；**各行列数必须相等**（否则 `error = "Problem is not rectangular"`）
#   · 单元格可带 `{注解}` 前缀，写入独立的注解列表（用于教学标注）
#   · 以 `?` 开头的行终止盘面定义，其后为**提示正文**
#   · **空单元格**用于视觉留白（把一组格与另一组格在视觉上分开）；
#     一旦出现空单元格则 has_empty = true
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
##     "has_empty": bool,                 # 含空单元格（视觉留白/分组分隔）
##     "text": String,                    # `?` 行之后的提示正文
##     "error": String }                  # "" = 解析成功
static func parse(src: String) -> Dictionary:
	var rows: Array = []
	# 【2026-10-02 用户口径 B2：一页多盘】`boards` = 本页的**全部**盘；`rows`/`cols` 仍是**第一张盘**
	# ⇒ 老消费方（与既有断言"盘面行数 = DEMO_SIDE"）一行都不用改。
	var boards: Array = []
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
		# 【2026-10-02 用户口径 B2】单独一行 `--` = **盘面分隔符**：本行之前与之后各是一张盘。
		# 为什么必须显式分隔：两张盘列数不同会被判"不矩形"，列数相同则会被**悄悄拼成一张大盘**（实测）。
		if line.strip_edges() == "--":
			if not rows.is_empty():
				boards.append({"rows": rows, "cols": maxi(cols, 0)})
			rows = []
			cols = -1
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

	if not rows.is_empty():
		boards.append({"rows": rows, "cols": maxi(cols, 0)})
	var first: Dictionary = boards[0] if not boards.is_empty() else {"rows": [], "cols": 0}
	return {
		"rows": first["rows"],        # 兼容：老消费方读这一份 = 第一张盘
		"cols": first["cols"],
		"boards": boards,             # B2：本页的全部盘（≥1；单盘时只有一张）
		"has_empty": has_empty,
		"text": "\n".join(text_lines).strip_edges(),
		"error": error,
	}


## 【2026-10-02 真机截图修：教程"只有文字、没有棋盘网格"】把**生成器风格的页字典**归一成绘制端要的形状。
## 生成器（`core/rule_legend.gd`）给的页是
## `{"id", "title", "text": 整份原文（含盘面行）, "layout", "kind"}`，
## 而绘制端读的是 `rows` / `cols` / 纯人话的 `text` ⇒ 后果正如用户截图：
## **左边一个格子都画不出来，右边把 `{@!}F{@clue}0…` 这些盘面行当正文打印**。
## 归一规则：缺 `rows` 且 `text` 非空 ⇒ 就地按教程格式解析一遍；标题优先用生成器的 `title`。
static func normalize_page(page: Dictionary) -> Dictionary:
	var out := page
	var raw := str(out.get("text", ""))
	# 只有**确实带盘面**的原文才值得重解析（生成器把 `q\n? 说明` 这种整份原文塞在 `text` 里）。
	# 纯人话（既没有制表符、也没有 `?` 行）**不许**当盘面解析：否则会凭空多出一个 1×1 棋盘、
	# 正文还会被吃掉（实测踩过：`{"text": "只有人话"}` 被解析成一行一格）。
	var looks_like_doc := raw.contains("\t") or raw.contains("\n?") or raw.begins_with("?")
	if (out.get("rows", []) as Array).is_empty() and looks_like_doc:
		var reparsed := parse(raw)
		reparsed["id"] = str(out.get("id", reparsed.get("id", "")))
		if out.has("title"):
			reparsed["title"] = str(out["title"])
		out = reparsed
	return out


## 教程文档里的**占位字母** → 视觉语义（纯函数，便于单测）。
## 【2026-10-02 用户反馈修：教程界面"乱码、没有棋盘"】文档用单字母表示特殊格：
##   · `q` = 未知/未翻开（应画成"盖着的瓦片"）
##   · `F` = 雷（**画成雷，不是旗**：[2026-10-02 用户口径] 雷更直观）
## 而绘制端原来把这些字母**当文字直接画** ⇒ 满屏 q/F 字母，看着就是乱码、也不像棋盘。
## 返回："covered" / "mine" / "text"（数字等仍按文字画）。
static func cell_visual(value: String) -> String:
	var v := value.strip_edges().to_lower()
	if v == "q":
		return "covered"
	if v == "f":
		return "mine"
	return "text"


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
## 额外搜索目录（P6）：Mod / 工坊包自带的图例落在 `user://mods/<id>/tutorial/`。
## 没有这层搜索，自创变体的图文图例就**只存在于包里**——玩家进关卡点书本图标看不到，
## 而且不会报错（静默缺失，正是本仓最忌讳的那种失败）。
const MODS_DIR := "user://mods"


## 全部搜索目录：官方在前、Mod 在后（同名页官方优先）。
static func search_dirs() -> Array[String]:
	var out: Array[String] = [DIR]
	var d := DirAccess.open(MODS_DIR)
	if d == null:
		return out
	for sub in d.get_directories():
		var p := "%s/%s/tutorial" % [MODS_DIR, str(sub)]
		if DirAccess.dir_exists_absolute(p):
			out.append(p)
	return out


## 列出全部教程页 id（形如 `tutorial_[1B]_0`），按名称排序保证顺序稳定。
static func list_ids() -> Array[String]:
	var out: Array[String] = []
	var seen := {}
	for root in search_dirs():
		var dir := DirAccess.open(root)
		if dir == null:
			continue
		for f in dir.get_files():
			var n := str(f)
			if not n.ends_with(".txt"):
				continue
			var id := n.substr(0, n.length() - 4)
			if seen.has(id):
				continue
			seen[id] = true
			out.append(id)
	out.sort()
	return out


## 加载一页教程。不存在或解析失败返回 {"error": ...}。
static func load_page(id: String) -> Dictionary:
	var path := ""
	for root in search_dirs():
		var p := "%s/%s.txt" % [root, id]
		if FileAccess.file_exists(p):
			path = p
			break
	if path == "":
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
##
## 序号必须是纯数字（2026-09-23 审查加固）：只做前缀匹配的话，`pages_for("s1")` 会把
## 将来的混合档页 `tutorial_s1_o1_0` 一并匹配进来（单席教程里混进混合档内容）。
## 现在混合档还没有教程页，但名单一旦增长这个误匹配是静默的，先堵上。
static func pages_for(combo: String) -> Array[String]:
	var prefix := "tutorial_%s_" % combo
	var out: Array[String] = []
	for id in list_ids():
		if not id.begins_with(prefix):
			continue
		var seq := id.substr(prefix.length())
		if not seq.is_valid_int():
			continue
		out.append(id)
	out.sort_custom(func(a: String, b: String) -> bool:
		return int(a.substr(prefix.length())) < int(b.substr(prefix.length())))
	return out
