# spec_helper.gd —— 零代码创作辅助：把「小白 + 他自己的 AI」这条路径打通（纯逻辑，无 UI）
#
# 【为什么需要这个文件】
# 声明式规格（spec v1）已经把"写规则"从编程降级成"填 JSON"，但前置知识仍全在
# 《变体规则编写规范》里 —— 普通玩家不会读规范，更不会手写 JSON。真实可行的创作路径是：
#   玩家用一句日常语言说想法 → 交给**他自己电脑上的 AI**（DeepSeek / 豆包 / ChatGPT 都行）
#   → AI 回一段 JSON → 玩家把整段回复粘回编辑器 → 编辑器读懂、校验、立刻能用。
# 本文件就是这条路径的**纯逻辑层**（不碰 UI、不写全局状态）：
#   · ai_prompt()     生成"自包含"提示词 —— 关键：对方的 AI **看不到本仓库**，
#                     所以字段表、硬约束、正确示例、输出格式必须全部写进提示词里；
#   · extract_json()  宽容解析 —— AI 的回复几乎总带解释文字、``` 围栏，甚至夹着注释，
#                     直接 JSON.parse_string 会全军覆没（这是"编辑器读不懂用户"的第一大原因）；
#   · kind_of()       判断粘回来的是"规则"还是"关卡"，分流到各自的入口；
#   · explain_spec()  把 JSON 说成人话（"数字 = 周围 8 格里的雷数"），让用户确认"这就是我要的"；
#   · friendly()      把校验器的技术报错翻译成"小白能懂 + 下一步干什么"；
#   · repair_prompt() 失败不是死路：把报错交回给 AI 让它自己修（用户不会改 JSON，但他会复制粘贴）；
#   · recipes()       零 AI 兜底：现成配方一键用（也用于自检这条链路本身是通的）。
#
# 【纪律】本文件只**读**注册表（is_replaceable_spec），不注册/不注销任何规则；
# 谁导入谁负责（UI 层走 `EditorDoc.register_rule` 这一个入口）。
class_name SpecHelper
extends RefCounted


## 方向偏移 → 中文说法（键是 "dx,dy"）。只覆盖八邻；其余（马步等）回退成"偏移(dx,dy)"。
const DIR_NAMES := {
	"0,-1": "上", "1,-1": "右上", "1,0": "右", "1,1": "右下",
	"0,1": "下", "-1,1": "左下", "-1,0": "左", "-1,-1": "左上",
}

## 报错关键词 → 小白该怎么办。按顺序取**第一条**全部关键词都命中的规则。
## 为什么要这层翻译：校验器的报错已经是"哪里错 + 怎么改"，但用词是 IR/原子/refs/geometry
## 这类面向作者的术语；小白看到"clue.refs 为固定偏移，但 geometry=\"adj_generic\""只会关掉窗口。
const _HINT_RULES := [
	{"need": ["spec_version"], "hint": "版本号照抄这一行即可：\"spec_version\": 1（不要写成 2，也不要加引号）"},
	{"need": ["已被注册"], "hint": "这个名字已经有规则在用了。若这是同一条规则的新版本，编辑器会自动替换同名的规格规则；否则让 AI 换一个 id（spec_ 后面改几个字母即可）。"},
	{"need": ["id", "spec_"], "hint": "id 要以 spec_ 开头，只能用小写英文、数字、下划线，例如 spec_wodeguize。让 AI 换一个不重名的 id。"},
	{"need": ["title"], "hint": "给规则补一个中文名（玩家在图鉴里看到的就是它），例如 \"title\": \"周围8格加一\""},
	{"need": ["固定偏移"], "hint": "你用了具体方向（如上下左右、斜角），必须再加一行 \"geometry\": \"rect_only\"。"},
	{"need": ["topo", "冲突"], "hint": "\"refs\": \"topo\"（相邻格）与 \"geometry\": \"rect_only\" 不能同时用：要么把 geometry 改成 \"adj_generic\"，要么把 refs 改成具体方向数组。"},
	{"need": ["geometry"], "hint": "geometry 决定能用在哪：只用具体方向 → \"rect_only\"（方盘）；只用「相邻格」→ \"adj_generic\"（环绕盘/六边形盘也能用）。"},
	{"need": ["hidden_state"], "hint": "这种格式不支持「隐藏状态」：让 AI 去掉 hidden_state，用普通写法表达。"},
	{"need": ["ref", "索引"], "hint": "数字引用了一个不存在的方向/邻居：refs 里有几个方向，ref 的 i 就只能从 0 数到「个数-1」。"},
	{"need": ["aux"], "hint": "aux 是高级功能（隐藏的辅助变量），日常玩法用不到：让 AI 改成只用 ref / sum / wsum 的写法。"},
	{"need": ["globals"], "hint": "globals 是「棋盘级条件」，不是单格数字。如果你只想要「数字怎么算」，让 AI 不要写 globals。"},
	{"need": ["clue"], "hint": "至少要写 clue（每格数字怎么算）或 globals（棋盘级条件）之一，不能两个都空着。"},
]

## 兜底建议：用户不需要自己改 JSON，把报错交回给 AI 即可（这正是本文件存在的意义）。
const _HINT_FALLBACK := "不用你自己改：点下面的「让 AI 修」按钮，把它生成的话复制给 AI，AI 会给你一份修好的完整 JSON。"


# ==================== 1. 给 AI 的提示词（自包含：对方的 AI 看不到本仓库） ====================

## 生成可直接粘给任意 AI 的提示词。ctx 可含：
##   idea（用户一句话想法）、rows/cols/mines（当前棋盘）、wrap（是否环绕）、
##   shape（形状族名，来自编辑器形状下拉）、foreign（是否外部异形盘）。
static func ai_prompt(ctx: Dictionary = {}) -> String:
	var idea := str(ctx.get("idea", "")).strip_edges()
	if idea == "":
		idea = "（我还没想好，请你从这几个里挑一个稳妥的实现：只算上下左右 4 格 / 周围 8 格再加 1 / 斜角算双倍）"
	var parts: Array[String] = []
	parts.append("""你是一位「变体扫雷」规则设计师。请把我的想法写成一条规则，输出一个 JSON 文件即可。
不要写 GDScript、不要写别的代码、不要输出其它格式。""")
	parts.append("【我的想法（可以用日常语言补充或修改）】\n" + idea)
	parts.append("【我当前的棋盘】\n" + _board_sentence(ctx))
	parts.append("""【你可以使用的全部写法（这是「声明式规格 v1」，平台会严格校验）】
顶层字段：
1) "spec_version"：固定写 1
2) "id"：必须以 spec_ 开头，只能用小写英文、数字、下划线（例如 spec_wodeguize），不能和已有规则重名
3) "title"：中文名字，给玩家看（例如 "斜角扫雷"）
4) "geometry"：二选一
   - "rect_only"：用到了具体方向（上下左右 / 斜角 / 行列）→ 只能在方方正正的棋盘上用
   - "adj_generic"：只用「相邻格」这一个概念 → 环绕盘 / 六边形盘都能用（此时 "clue.refs" 必须写 "topo"）
5) "clue"：每格显示的数字怎么算（大多数玩法只需要它）
   - "clue.refs" 二选一：
     a) 固定方向数组（dx 是左右偏移，dy 是上下偏移，y 向下为正）：
        [{"dx":0,"dy":-1},{"dx":1,"dy":0},{"dx":0,"dy":1},{"dx":-1,"dy":0}]   ← 必须配 "geometry":"rect_only"
     b) 字符串 "topo"：表示「本格的全部相邻格」，邻居按位置从上到下、从左到右编号
        必须配 "geometry":"adj_generic"
   - "clue.expr"：只允许下面 4 种节点（可以嵌套）
     {"t":"const","v":整数}                                  一个固定数值
     {"t":"ref","i":编号}                                    第 i 个方向/邻居里有雷记 1、没雷记 0
     {"t":"sum","xs":[节点, 节点, ...]}                       把它们加起来
     {"t":"wsum","ws":[整数权重,...],"xs":[ref 或 const,...]}  加权求和（两个数组必须一样长）
   - "clue.max"：数字最大可能是多少（整数）
6) 可选 "globals"：棋盘级条件（新手玩法一般不需要，能不用就不用）""")
	parts.append("""【明确做不到的（不要硬编字段，宁可告诉我做不到）】
- 不能有乘法、平方、除法、小数（所有数字必须是整数）
- 不能有「最大 / 最小」「如果…就…」这类分支，也不能有隐藏状态
- 数字只能是「若干相邻格的雷数」的整数加权和，可以再加一个整数常数
  （例：数字 = 周围雷数 + 1 → 用 wsum：前面几项是 ref，最后一项是 {"t":"const","v":1}）
- 数字不要写成负数（平台按非负值域工作）：要"加大"就加正数
- 如果我的想法做不到，请直接说明，并给我一条最接近的可行规则""")
	parts.append("""【输出格式（严格）】
只输出一个 json 代码块（用三个反引号包起来），里面是完整 JSON；代码块之外最多再写两句中文玩法说明。""")
	parts.append("""【两个正确示例（照着写即可）】
例 1：数字 = 周围 8 格里的雷数（方盘）
```json
{
  "spec_version": 1,
  "id": "spec_zhuwei8",
  "title": "周围 8 格计数",
  "geometry": "rect_only",
  "clue": {
    "refs": [{"dx":0,"dy":-1},{"dx":1,"dy":-1},{"dx":1,"dy":0},{"dx":1,"dy":1},
             {"dx":0,"dy":1},{"dx":-1,"dy":1},{"dx":-1,"dy":0},{"dx":-1,"dy":-1}],
    "expr": {"t":"sum","xs":[{"t":"ref","i":0},{"t":"ref","i":1},{"t":"ref","i":2},{"t":"ref","i":3},
                             {"t":"ref","i":4},{"t":"ref","i":5},{"t":"ref","i":6},{"t":"ref","i":7}]},
    "max": 8
  }
}
```
例 2：数字 = 所有相邻格里的雷数（任何棋盘；相邻关系由棋盘自己决定）
```json
{
  "spec_version": 1,
  "id": "spec_xianglin",
  "title": "相邻格雷数（任意棋盘）",
  "geometry": "adj_generic",
  "clue": {
    "refs": "topo",
    "expr": {"t":"sum","xs":[{"t":"ref","i":0},{"t":"ref","i":1},{"t":"ref","i":2},{"t":"ref","i":3},
                             {"t":"ref","i":4},{"t":"ref","i":5},{"t":"ref","i":6},{"t":"ref","i":7}]},
    "max": 8
  }
}
```""")
	return "\n\n".join(parts)


## 把当前棋盘说给 AI 听，并**直接指定该用哪种 geometry**——
## 因为"选错写法"是唯一一个 validate 拦不住、却会让数字静默算错的坑：
## 普通方盘没有邻接表，`refs="topo"` 的规格走 `compute_clue` 会返回 empty_value（全 0）。
static func _board_sentence(ctx: Dictionary) -> String:
	var rows := int(ctx.get("rows", 0))
	var cols := int(ctx.get("cols", 0))
	var mines := int(ctx.get("mines", 0))
	var lines: Array[String] = []
	lines.append("大小：%s" % ("%d 行 × %d 列" % [rows, cols] if rows > 0 and cols > 0 else "还没定（默认 9×9）"))
	if mines > 0:
		lines.append("雷数：大约 %d 颗" % mines)
	var shape := str(ctx.get("shape", ""))
	if shape != "" or bool(ctx.get("foreign", false)):
		lines.append("盘型：%s（不规则棋盘，只有「相邻格」一个概念可用）" % (shape if shape != "" else "外部导入的异形棋盘"))
		lines.append("→ 必须用 \"geometry\":\"adj_generic\" 且 \"clue.refs\":\"topo\"")
	elif bool(ctx.get("wrap", false)):
		lines.append("边界：环绕边界（上下、左右相通），相邻关系由邻接表给出")
		lines.append("→ 用 \"geometry\":\"adj_generic\" 且 \"clue.refs\":\"topo\"（这样在环绕盘上才算得出数字）")
	else:
		lines.append("盘型：普通矩形棋盘（没有邻接表）")
		lines.append("→ 必须用具体方向数组 + \"geometry\":\"rect_only\"；写成 \"refs\":\"topo\" 会算不出数字（全是 0）")
	return "\n".join(lines)


# ==================== 2. 宽容解析（AI 的回复不是纯 JSON） ====================

## 安全解析：失败时**不打印引擎错误**。
## 为什么不能用 `JSON.parse_string`：它在失败时会 ERR_PRINT（"Parse JSON failed..."），
## 而本文件的工作就是"替用户试读他粘进来的东西"——读不懂是常态，不该污染日志
##（本仓 GUT 把引擎错误记为测试失败，这条纪律在 2026-10-02 被本文件的测试当场抓到）。
static func parse_json_safe(text: String) -> Variant:
	var j := JSON.new()
	if j.parse(text) != OK:
		return null
	return j.data


## 从任意文本里取出 JSON 对象。返回 {"ok","data","note","errors"}。
## 顺序：``` 围栏内容 → 正文里第一个配平的 {...} → 整段原文；每一步先严格解析，
## 失败再过一遍"常见手误修补"（字符串外的 // 与 /* */ 注释），并在 note 里如实说明。
static func extract_json(text: String) -> Dictionary:
	var t := text.replace("\r\n", "\n").replace("\r", "\n")
	if t.strip_edges() == "":
		return {"ok": false, "data": {}, "note": "", "errors": PackedStringArray(["内容是空的——请把 AI 的整段回复粘进来"])}
	var candidates: Array[String] = []
	for block in _fenced_blocks(t):
		candidates.append(block)
	candidates.append(_brace_span(t))
	candidates.append(t.strip_edges())
	for cand in candidates:
		if cand.strip_edges() == "":
			continue
		var v: Variant = parse_json_safe(cand)
		if v is Dictionary:
			return {"ok": true, "data": v, "note": "", "errors": PackedStringArray()}
		var mended := _mend_common(cand)
		if mended != cand:
			var v2: Variant = parse_json_safe(mended)
			if v2 is Dictionary:
				return {"ok": true, "data": v2, "note": "（已自动修掉注释）", "errors": PackedStringArray()}
	return {"ok": false, "data": {}, "note": "", "errors": PackedStringArray([
		"没找到能读的 JSON——请把 AI 的整段回复（含 json 代码块）原样粘进来"])}


## 取出所有 ``` 围栏内容（含 ```json 开头、``` 结尾；未闭合时取到文末）。
static func _fenced_blocks(t: String) -> Array[String]:
	var out: Array[String] = []
	var lines := t.split("\n")
	var buf: Array[String] = []
	var inside := false
	for line in lines:
		if line.strip_edges().begins_with("```"):
			if inside:
				out.append("\n".join(buf))
				buf = []
				inside = false
			else:
				inside = true
			continue
		if inside:
			buf.append(line)
	if inside and not buf.is_empty():
		out.append("\n".join(buf))
	return out


## 正文里第一个「配平」的 {...} 片段。会跳过字符串内部的括号与 \" 转义
##（AI 的 title 里带 { } 是常事，直接 last_index_of("}") 会切坏）。
static func _brace_span(t: String) -> String:
	var start := t.find("{")
	if start < 0:
		return ""
	var depth := 0
	var in_str := false
	var esc := false
	for i in range(start, t.length()):
		var ch := t[i]
		if in_str:
			if esc:
				esc = false
			elif ch == "\\":
				esc = true
			elif ch == "\"":
				in_str = false
			continue
		if ch == "\"":
			in_str = true
		elif ch == "{":
			depth += 1
		elif ch == "}":
			depth -= 1
			if depth == 0:
				return t.substr(start, i - start + 1)
	return ""


## 常见手误修补：去掉字符串外的 // 与 /* */ 注释。
## 只在严格解析失败后作为**兜底**调用，并在结果里注明"已自动修过"（不静默）。
## 【为什么只管注释、不管尾随逗号】Godot 的 JSON 解析器**本来就接受尾随逗号**
##（`{"a":1,}` 能解析成功；`test_spec_helper.gd` 里有一条用例把这条引擎行为钉住）。
## 原先这里还写了"去掉 } 前的多余逗号"——它永远走不到，留着会让读代码的人以为它在干活，
## 故删除（本仓纪律：不留不会触发的分支）。
static func _mend_common(s: String) -> String:
	var out := ""
	var in_str := false
	var esc := false
	var i := 0
	var n := s.length()
	while i < n:
		var ch := s[i]
		if in_str:
			out += ch
			if esc:
				esc = false
			elif ch == "\\":
				esc = true
			elif ch == "\"":
				in_str = false
			i += 1
			continue
		if ch == "/" and i + 1 < n and s[i + 1] == "/":
			while i < n and s[i] != "\n":
				i += 1
			continue
		if ch == "/" and i + 1 < n and s[i + 1] == "*":
			i += 2
			while i + 1 < n and not (s[i] == "*" and s[i + 1] == "/"):
				i += 1
			i += 2
			continue
		if ch == "\"":
			in_str = true
		out += ch
		i += 1
	return out


# ==================== 3. 判断粘回来的是什么 ====================

## 返回 "spec"（规则规格）| "level"（关卡）| "manifest"（Mod 清单）| "unknown"。
static func kind_of(data: Dictionary) -> String:
	if data.has("spec_version") or (data.has("id") and (data.has("clue") or data.has("globals"))):
		return "spec"
	if data.has("mines") or data.has("size") or data.has("cells") or data.has("total_mines"):
		return "level"
	if data.has("entry") and data.has("version"):
		return "manifest"
	return "unknown"


# ==================== 4. 把规则说成人话 ====================

## 白话说清这条规则怎么玩（用户据此确认"这就是我要的"）。校验不过时也照实说明。
static func explain_spec(spec: Dictionary) -> String:
	var lines: Array[String] = []
	var title := str(spec.get("title", "")).strip_edges()
	var sid := str(spec.get("id", "")).strip_edges()
	lines.append("规则名字：%s（%s）" % [title if title != "" else "（还没起名）", sid if sid != "" else "缺 id"])
	var v := validate_spec_for_editing(spec)
	if not bool(v["ok"]):
		lines.append("注意：这条规则现在还**不能生效**（原因见下面的「问题」）。")
	var is_topo := false
	if spec.has("clue"):
		var clue: Dictionary = spec.get("clue", {})
		var refs_v: Variant = clue.get("refs")
		is_topo = refs_v is String
		var names := _ref_names(refs_v)
		lines.append("数字怎么算：%s" % _describe_clue(clue.get("expr", {}), names, is_topo))
		if is_topo:
			lines.append("　· 每一项 = 一个相邻格：有雷记 1、没雷记 0")
		else:
			lines.append("　· 每一项 = 一个方向上的那格：有雷记 1、没雷记 0")
		if clue.has("max"):
			lines.append("数字最大可能是：%d" % int(clue.get("max", 0)))
	if str(spec.get("geometry", "adj_generic")) == "rect_only":
		lines.append("适用棋盘：只有方方正正的矩形盘（因为用到了具体方向）。")
	else:
		lines.append("适用棋盘：任意棋盘都行（只用「相邻格」这个概念；环绕盘、六边形盘也能用）。")
	if is_topo:
		lines.append("　· 注意：这一条依赖棋盘的「邻接表」。普通方盘没有邻接表，数字会算成 0 —— 请用环绕边界或六边形盘。")
	var globals_v: Variant = spec.get("globals", [])
	if globals_v is Array and not (globals_v as Array).is_empty():
		lines.append("额外条件：还有 %d 条**棋盘级**条件（管整张棋盘，不是单格数字）。" % (globals_v as Array).size())
	lines.append("提示：有雷的格子不显示数字。")
	return "\n".join(lines)


## 方向说法的中文名表（topo 形态没有方向名，返回空数组）。
static func _ref_names(refs_v: Variant) -> Array[String]:
	var out: Array[String] = []
	if refs_v is Array:
		for r in (refs_v as Array):
			if r is Dictionary:
				var d: Dictionary = r
				out.append(_dir_name(Vector2i(int(d.get("dx", 0)), int(d.get("dy", 0)))))
	return out


static func _dir_name(d: Vector2i) -> String:
	var key := "%d,%d" % [d.x, d.y]
	if DIR_NAMES.has(key):
		return DIR_NAMES[key]
	if d == Vector2i.ZERO:
		return "自身"
	return "偏移(%d,%d)" % [d.x, d.y]


## 线索表达式 → 人话（**常见形态优先**）。
## 为什么不能直接打印表达式："第 0 个相邻格 + 第 1 个相邻格 + …" 对小白等于没解释；
## 真实玩法里 99% 是「若干方向求和」或「求和再加一个常数」，这两种直接说成中文。
static func _describe_clue(e: Variant, names: Array[String], topo: bool) -> String:
	var k := _pure_refs_count(e)
	if k > 0:
		if topo:
			return "所有相邻格（最多 %d 个）里的雷数之和" % k
		if names.size() >= k:
			return "这几个方向上的雷数之和：%s" % "、".join(_head(names, k))
		return "前 %d 个方向上的雷数之和" % k
	# 「纯求和 + 一个整数常数」= 加减偏移（例如"周围雷数 + 1"）
	var shifted := _count_plus_const(e)
	if not shifted.is_empty():
		var c := int(shifted["c"])
		var base := _describe_clue(shifted["base"], names, topo)
		if c > 0:
			return "%s，再加 %d" % [base, c]
		return "%s，再减 %d" % [base, -c]
	return _expr_text(e, names, topo)


## 若 e 等价于"ref 0..K-1 各一次求和"（= 计数语义）则返回 K，否则 -1。
static func _pure_refs_count(e: Variant) -> int:
	if not (e is Dictionary):
		return -1
	var d: Dictionary = e
	if str(d.get("t", "")) != "sum":
		return -1
	var xs: Variant = d.get("xs", [])
	if not (xs is Array):
		return -1
	var seen := {}
	for x in (xs as Array):
		if not (x is Dictionary):
			return -1
		var xd: Dictionary = x
		if str(xd.get("t", "")) != "ref":
			return -1
		var i := int(xd.get("i", -1))
		if i < 0 or seen.has(i):
			return -1
		seen[i] = true
	var k := seen.size()
	if k == 0:
		return -1
	for i in k:
		if not seen.has(i):
			return -1
	return k


## 「纯计数 + 恰一个整数常数」→ {base, c}；否则空字典。
## 形态：wsum(ws 全 1 的 ref 0..K-1 各一次 + 一个 const)，或 sum(ref 0..K-1 + 一个 const)。
static func _count_plus_const(e: Variant) -> Dictionary:
	if not (e is Dictionary):
		return {}
	var d: Dictionary = e
	var t := str(d.get("t", ""))
	var xs: Variant = d.get("xs", [])
	if not (xs is Array):
		return {}
	var ws: Variant = d.get("ws", [])
	var refs_seen := {}
	var consts: Array[int] = []
	var n := (xs as Array).size()
	for idx in n:
		var x: Variant = (xs as Array)[idx]
		if not (x is Dictionary):
			return {}
		var xd: Dictionary = x
		var xt := str(xd.get("t", ""))
		if t == "wsum":
			if not (ws is Array) or (ws as Array).size() != n or int((ws as Array)[idx]) != 1:
				return {}
		elif t != "sum":
			return {}
		if xt == "ref":
			var i := int(xd.get("i", -1))
			if i < 0 or refs_seen.has(i):
				return {}
			refs_seen[i] = true
		elif xt == "const":
			consts.append(int(xd.get("v", 0)))
		else:
			return {}
	var k := refs_seen.size()
	if k == 0 or consts.size() != 1:
		return {}
	for i in k:
		if not refs_seen.has(i):
			return {}
	var base: Dictionary = {"t": "sum", "xs": []}
	var base_xs: Array = []
	for i in k:
		base_xs.append({"t": "ref", "i": i})
	base["xs"] = base_xs
	return {"base": base, "c": consts[0]}


static func _head(arr: Array[String], n: int) -> Array[String]:
	var out: Array[String] = []
	for i in mini(n, arr.size()):
		out.append(arr[i])
	return out


## 线索表达式 → 人话。names = 各 ref 的方向名（topo 形态传空数组）。
static func _expr_text(e: Variant, names: Array[String], topo: bool) -> String:
	if not (e is Dictionary):
		return "（没有写 expr，无法解释）"
	var d: Dictionary = e
	match str(d.get("t", "")):
		"const":
			return "固定值 %d" % int(d.get("v", 0))
		"ref":
			var i := int(d.get("i", -1))
			if topo:
				return "第 %d 个相邻格" % i
			if i >= 0 and i < names.size():
				return "「%s」方向" % names[i]
			return "第 %d 个方向" % i
		"sum":
			var xs: Variant = d.get("xs", [])
			if not (xs is Array) or (xs as Array).is_empty():
				return "（sum 是空的）"
			var parts: Array[String] = []
			for x in (xs as Array):
				parts.append(_expr_text(x, names, topo))
			return " + ".join(parts)
		"wsum":
			var ws: Variant = d.get("ws", [])
			var xs2: Variant = d.get("xs", [])
			if not (ws is Array) or not (xs2 is Array):
				return "（wsum 写得不完整）"
			var parts2: Array[String] = []
			for k in (ws as Array).size():
				var w := int((ws as Array)[k])
				var item := _expr_text((xs2 as Array)[k], names, topo)
				parts2.append(item if w == 1 else "%d×%s" % [w, item])
			return " + ".join(parts2)
	return "（不认识的写法：%s）" % str(d.get("t", "?"))


# ==================== 5. 校验结果 → 小白能懂的话 ====================

## 把 SpecSchema.validate 的结果整理成 [{level, text, hint}]：
## text = 校验器原文（保留，供作者/再次交给 AI 时使用），hint = 小白该干什么。
static func friendly(v: Dictionary) -> Array:
	var out: Array = []
	for e in _to_texts(v.get("errors", [])):
		out.append({"level": "error", "text": e, "hint": _hint_for(e)})
	var warns := _to_texts(v.get("warnings", []))
	var codes := _to_texts(v.get("warning_codes", []))
	for i in warns.size():
		var code := codes[i] if i < codes.size() else ""
		out.append({"level": "warn", "text": warns[i], "hint": _warn_hint(code)})
	return out


static func _hint_for(err_text: String) -> String:
	var low := err_text.to_lower()
	for rule in _HINT_RULES:
		var ok := true
		for kw in (rule as Dictionary)["need"]:
			if low.find(str(kw).to_lower()) < 0:
				ok = false
				break
		if ok:
			return str((rule as Dictionary)["hint"])
	return _HINT_FALLBACK


## 告警的 code → 白话含义。未知 code 一律给"看看就好"的中性说法（不误报严重性）。
static func _warn_hint(code: String) -> String:
	match code:
		"ref_order":
			return "邻居的编号是固定的（按位置从上到下、从左到右），存档再读档也不会变，可以放心用。"
		"coverage":
			return "这条规则只用了前几个邻居，剩下的邻居不参与计算——如果这不是你的本意，让 AI 把「所有相邻格」都写进去。"
		"compute_clue_na":
			return "这条规则按「相邻格」定义：在环绕盘 / 六边形盘上正常，在普通方盘上数字会全是 0（请改用固定方向 + rect_only，或把棋盘改成环绕 / 异形）。"
		_:
			return "这是一条提醒（不影响能不能用）：看不懂可以忽略，或把它连同 JSON 一起交给 AI 解释。"


# ==================== 6. 失败回喂：让 AI 自己修 ====================

## 生成"把错误交回给 AI"的话。用户不会改 JSON，但他会复制粘贴——这是闭环的关键一步。
static func repair_prompt(ai_text: String, errors: Variant) -> String:
	var errs := _to_texts(errors)
	var lines: Array[String] = []
	lines.append("我按你的建议把这份 JSON 粘进编辑器，但平台的校验器拒绝了。请给我**修正后的完整 JSON**，")
	lines.append("保持我的原始意图不变，只修错误。")
	lines.append("")
	lines.append("【校验器的报错】")
	if errs.is_empty():
		lines.append("1) 没能从你的回复里读出 JSON 代码块（可能被截断，或混了太多解释文字）")
	else:
		for i in errs.size():
			lines.append("%d) %s" % [i + 1, errs[i]])
	lines.append("")
	lines.append("【你上次给的内容（原文）】")
	var clipped := ai_text.strip_edges()
	if clipped.length() > 6000:
		clipped = clipped.substr(0, 6000) + "\n…（后文省略）"
	lines.append(clipped if clipped != "" else "（上次的内容为空）")
	lines.append("")
	lines.append("【必须满足的硬约束（平台校验器只认这些）】")
	lines.append("- \"spec_version\": 1；\"id\" 以 spec_ 开头且不与已有规则重名；\"title\" 是中文")
	lines.append("- clue.expr 只允许 const / ref / sum / wsum 四种节点；不能有乘法、小数、最大最小、隐藏状态")
	lines.append("- refs 是具体方向数组时必须配 \"geometry\":\"rect_only\"；refs 写 \"topo\" 时必须配 \"geometry\":\"adj_generic\"")
	lines.append("- 数字不要写成负数")
	lines.append("")
	lines.append("【输出格式】只输出一个 json 代码块（三个反引号包起来），里面是完整 JSON，不要解释。")
	return "\n".join(lines)


# ==================== 7. 现成配方（零 AI 兜底，也是自检这条链路的样本） ====================

## 返回 [{id,title,blurb,spec,note}]，spec 已深拷贝（调用方随便改）。
## note = 适用盘面提醒（小白最需要的那句）。
static func recipes() -> Array:
	var out: Array = []
	out.append(_mk_recipe("spec_r8", "周围 8 格（＝普通扫雷）",
		"数字 = 周围一圈 8 个格子里的雷数。",
		"方盘专用。", _spec_offsets("周围 8 格", ClueEngine.ring_dirs()),
		_sum_expr(8), 8))
	out.append(_mk_recipe("spec_orth4", "上下左右 4 格",
		"斜角不算；角落的格子只有 2 个邻居。",
		"方盘专用。", _spec_offsets("上下左右", [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]),
		_sum_expr(4), 4))
	out.append(_mk_recipe("spec_diag4", "只算斜角 4 格",
		"只看四个斜角，上下左右不算。",
		"方盘专用。", _spec_offsets("斜角", [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]),
		_sum_expr(4), 4))
	out.append(_mk_recipe("spec_knight8", "骑士步（马走日）",
		"数字 = 马步能跳到的 8 个格子里的雷数。",
		"方盘专用。", _spec_offsets("骑士步", _knight_dirs()),
		_sum_expr(8), 8))
	out.append(_mk_recipe("spec_r8_plus1", "周围 8 格 + 1",
		"和普通扫雷一样，但每个数字都加 1（所以不会出现 0）。",
		"方盘专用。", _spec_offsets("周围 8 格", ClueEngine.ring_dirs()),
		{"t": "wsum", "ws": [1, 1, 1, 1, 1, 1, 1, 1, 1],
			"xs": [{"t": "ref", "i": 0}, {"t": "ref", "i": 1}, {"t": "ref", "i": 2}, {"t": "ref", "i": 3},
				{"t": "ref", "i": 4}, {"t": "ref", "i": 5}, {"t": "ref", "i": 6}, {"t": "ref", "i": 7},
				{"t": "const", "v": 1}]}, 9))
	out.append(_mk_recipe("spec_orth4_plus1", "上下左右 4 格 + 1",
		"只算上下左右 4 格（斜角不算），数字再 +1。",
		"方盘专用；就是「去掉斜角」的加一版。",
		_spec_offsets("上下左右", [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]),
		{"t": "wsum", "ws": [1, 1, 1, 1, 1],
			"xs": [{"t": "ref", "i": 0}, {"t": "ref", "i": 1}, {"t": "ref", "i": 2}, {"t": "ref", "i": 3},
				{"t": "const", "v": 1}]}, 5))
	out.append(_mk_recipe("spec_anyneighbors", "所有相邻格（环绕/六边形盘用）",
		"数字 = 棋盘上所有相邻格里的雷数（相邻关系由棋盘决定）。",
		"只对环绕盘、六边形盘等有邻接表的棋盘有意义；普通方盘请用上面第 1 条。",
		"topo", _sum_expr(8), 8, "adj_generic"))
	return out


## 给用户点选的"想法填空"示例（降低空白页恐惧；点一下填进输入框，可再改）。
static func idea_examples() -> Array[String]:
	return [
		"数字 = 周围 8 格里的雷数 + 1",
		"数字 = 只算上下左右 4 格里的雷数，斜角不算",
		"数字 = 斜角 4 格里的雷数算双倍，上下左右算一倍",
		"数字 = 所有相邻格里的雷数（我想在环绕盘/六边形盘上用）",
	]


static func _mk_recipe(id: String, title: String, blurb: String, note: String,
		refs: Variant, expr: Dictionary, max_v: int, geo := "rect_only") -> Dictionary:
	var spec := {
		"spec_version": 1,
		"id": id,
		"title": title,
		"geometry": geo,
		"clue": {"refs": refs, "expr": expr, "max": max_v},
	}
	return {"id": id, "title": title, "blurb": blurb, "note": note, "spec": spec}


static func _spec_offsets(_label: String, dirs: Array) -> Array:
	var out: Array = []
	for d in dirs:
		var v: Vector2i = d
		out.append({"dx": v.x, "dy": v.y})
	return out


static func _sum_expr(n: int) -> Dictionary:
	var xs: Array = []
	for i in n:
		xs.append({"t": "ref", "i": i})
	return {"t": "sum", "xs": xs}


static func _knight_dirs() -> Array[Vector2i]:
	return [
		Vector2i(1, -2), Vector2i(2, -1), Vector2i(2, 1), Vector2i(1, 2),
		Vector2i(-1, 2), Vector2i(-2, 1), Vector2i(-2, -1), Vector2i(-1, -2),
	]


# ==================== 8. 注册表只读查询 ====================

## `id` 位置上是**本插件注册的规格规则**（⇒ 可以用新版本替换）吗？
## 为什么要它：用户让 AI 改了一版、id 却没变时，"id 已被注册"会让小白卡死。
## 但绝不能对内置/官方规则做替换——那样等于悄悄覆盖别人的规则，所以只认 SpecRulePlugin。
static func is_replaceable_spec(id: String) -> bool:
	if not id.begins_with(SpecSchema.ID_PREFIX):
		return false
	var r := RuleRegistry.default().resolve(StringName(id))
	return r != null and r is SpecRulePlugin


# ==================== 9. 编辑期校验（豁免"自己刚注册的那条"） ====================

## 注册表里那个 id 上，是不是**与本 spec 同源**的规格规则？
## 判"同源"而不是只判"是个规格规则"：用户手改成另一条同 id 的规格时，注册表里是旧版本，
## 必须照实报"已被注册"（否则会静默用到旧规则，比误报更糟）。
static func is_registered_self(spec: Dictionary) -> bool:
	var rid := str(spec.get("id", ""))
	if rid == "" or not rid.begins_with(SpecSchema.ID_PREFIX):
		return false
	var r := RuleRegistry.default().resolve(StringName(rid))
	if r == null or not (r is SpecRulePlugin):
		return false
	return _canon((r as SpecRulePlugin).spec_source()) == _canon(spec)


## 规范化后再比：注册走的是"文本 → 解析"，而配方直接给的是 GDScript 字典
##（`1` 与 `1.0` 必须看成同一个值），否则同一条规格会被误判成"不同源"。
static func _canon(d: Dictionary) -> String:
	var round: Variant = parse_json_safe(JSON.stringify(d))
	return JSON.stringify(round) if round is Dictionary else JSON.stringify(d)


## 编辑期用的规格检查：把"自己刚注册的这条规格"引起的 id 冲突剔掉，其余原样保留。
## 返回与 `SpecSchema.validate` 同形状（ok / errors / warnings / warning_codes）。
## 谁用：`EditorDoc.validate()`（状态栏、本盘问题、验证、生成分享包都吃它）与 `explain_spec()`。
static func validate_spec_for_editing(spec: Dictionary) -> Dictionary:
	var v := SpecSchema.validate(spec)
	if not is_registered_self(spec):
		return v
	var kept := PackedStringArray()
	for e in (v["errors"] as PackedStringArray):
		if str(e).find("已被注册") != -1:
			continue
		kept.append(str(e))
	var out: Dictionary = v.duplicate(true)
	out["errors"] = kept
	out["ok"] = kept.is_empty()
	return out


static func _to_texts(x: Variant) -> Array[String]:
	var out: Array[String] = []
	if x is Array or x is PackedStringArray:
		for it in x:
			out.append(str(it))
	return out
