class_name FoldModel
extends RefCounted

## 折叠盘（静态折叠）模型 —— 「纸沿一条折痕翻折过去」的纯数学层。
##
## 【本模型只做两件事】
##   ① 把 fold 声明（axis + at）翻译成「哪些格叠在一起」的**成对关系**（供写进邻接表）；
##   ② 提供折痕 / 镜像的几何查询（供渲染画折痕、重影与悬停连线）。
##
## 【为什么不改坐标、只加边】本仓的单一事实源是邻接表，格坐标只是标签：翻折本身是
##   **等距变换**（每一侧的邻居关系原样保留），真正新增的只有一条物理事实 ——
##   「翻过去的那一格，正压在这一格上面」。两层贴合 ⇒ 互为邻居 ⇒ 这就是本玩法唯一的
##   拓扑改动。（与虫洞同构：都是「显式声明 + 加边」，见 core/topology_model.gd 的 attach_portals。）
##
## 【轴 / 折痕 / 镜像的定义】
##   · axis = "x"：左右折（折痕是竖直线），索引取 pos.x，同一条线上的格 = 同一个 pos.y；
##   · axis = "y"：上下折（折痕是水平线），索引取 pos.y，同一条线上 = 同一个 pos.x；
##   · 折痕落在 at-1 与 at 之间：近侧 = 索引 [0, at-1]（不动的那半），远侧 = [at, ∞)（翻过去的那半）；
##   · 远侧索引 i 翻到 mirror_index(at, i) = 2*at-1-i：
##       - mirror ≥ 0 且那格存在 ⇒ 与它成对（**a = 底层（近侧），b = 覆层（远侧）**）；
##       - mirror < 0 ⇒ **翘出盘外**（折角伸出近侧边缘之外），没有对家；
##       - mirror ≥ 该轴总格数 ⇒ **没盖到**（远侧那半比近侧短，够不着），只有近侧的格会这样；
##       - mirror 在范围内、但那格不在盘上（挖掉的洞 / 形状盘上根本没有）⇒ **悬空**。
## 后三种都只是提示（见 audit() 的 overhang / uncovered / floating），**都不是错误**：
## 挖洞盘天然会有悬空格，折一截短的自然会有没盖到的格。
##
## 【为什么 a / b 有序】渲染要用：b 是「盖在上面」的那一层（远侧翻过来的），a 是「被盖住」
##   的底层。pairs_of 恒按这个顺序产出；pair_map 刻意返回**双向**表（绘制与命中都要按任一
##   方向查对家）。

const AXIS_X := "x"
const AXIS_Y := "y"
const AXES: Array[String] = [AXIS_X, AXIS_Y]


## 该轴上的索引（决定"离折痕几格"的那一个分量）。
static func index_of(p: Vector2i, axis: String) -> int:
	return p.x if axis == AXIS_X else p.y


## 该轴上的"线"编号（折痕平行方向的那一个分量）：同一线上的格才可能互相配对。
static func line_of(p: Vector2i, axis: String) -> int:
	return p.y if axis == AXIS_X else p.x


## 镜像位置：索引 i 翻过折痕 at 之后落在哪。
## at 是折痕**右侧/下侧**第一格的索引 ⇒ i = at 与 i = at-1 互为镜像（相邻两格对折后会重合）。
static func mirror_index(at: int, i: int) -> int:
	return 2 * at - 1 - i


## 校验并规范化一份 fold 声明。返回 {ok, fold: {axis, at}, errors, extent}。
## extent = 该轴上的最大索引 + 1（由 positions 推出；空 positions ⇒ 0）。
## 只做结构校验（轴名 / at 范围），**不**判"翻过去有没有对家"——那是 audit() 的事，
## 因为它依赖于"盘上到底有没有那些格"（洞 / 形状盘），是**内容**而非**声明**的问题。
static func normalize(fold: Dictionary, positions: Array[Vector2i]) -> Dictionary:
	var errors: Array[String] = []
	var axis := str(fold.get("axis", ""))
	if not AXES.has(axis):
		errors.append("fold.axis 必须是 %s 或 %s（收到 %s）" % [AXIS_X, AXIS_Y, axis])
	var at := int(fold.get("at", 0))
	if at < 1:
		errors.append("fold.at 必须 ≥ 1（收到 %d）：折痕要落在两列/两行之间" % at)
	var extent := 0
	for p in positions:
		extent = maxi(extent, index_of(p, axis if AXES.has(axis) else AXIS_X) + 1)
	if not errors.is_empty():
		return {"ok": false, "fold": {}, "errors": errors, "extent": extent}
	if at >= extent:
		errors.append("fold.at = %d 落在盘外（该轴只有 %d 格宽）：近侧必须至少留 1 格" % [at, extent])
		return {"ok": false, "fold": {}, "errors": errors, "extent": extent}
	return {"ok": true, "fold": {"axis": axis, "at": at}, "errors": [], "extent": extent}


## 审计：配对结果 + 两类「翻过去没对家」的格。
## 返回 {ok, errors, pairs, overhang, uncovered, floating, unpaired, near, far}：
##   · pairs     —— [{a, b}] 成对（见文件头）；a 恒在近侧、b 恒在远侧；
##   · overhang  —— 翘出盘外的格（镜像索引 < 0）；
##   · uncovered —— 没被盖到的近侧格（镜像索引 ≥ 该轴总格数：远侧那半不够长）；
##   · floating  —— 镜像在范围内、但对面那格不在盘上的格（洞；**两侧都可能出现**）；
##   · unpaired  —— 三类合计（= 盘上"翻过去没有对家"的格数）；
##   · near/far  —— 近侧 / 远侧各有多少格（含没配上的）。
## 【为什么两侧都要查】只查远侧会漏掉"洞开在远侧"的情况：那时留在近侧的那一格
## 才是真正没对家的（本轮实测就踩到：3×6 挖掉 (5,1) ⇒ 若只报远侧，一份都不报）。
## 这三类**都不是错误**：它们是给作者看的提示（编辑器里提示、生成器里自检），
## 错误只留给非法参数（轴名 / at 越界）。
static func audit(fold: Dictionary, positions: Array[Vector2i]) -> Dictionary:
	var errors: Array[String] = []
	var pairs: Array = []
	var overhang: Array = []
	var uncovered: Array = []
	var floating: Array = []
	var out := {"ok": false, "errors": errors, "pairs": pairs, "overhang": overhang,
			"uncovered": uncovered, "floating": floating, "unpaired": 0, "near": 0, "far": 0}
	var norm := normalize(fold, positions)
	if not bool(norm["ok"]):
		out["errors"] = norm["errors"]
		return out
	var f: Dictionary = norm["fold"]
	var axis := str(f["axis"])
	var at := int(f["at"])
	var extent := int(norm["extent"])
	# 先按 (线, 索引) 建索引：只有同一条线上的格才互相配对（翻折沿折痕做镜像，不跨行）
	var by_line: Dictionary = {}
	for p in positions:
		var row: Dictionary = by_line.get(line_of(p, axis), {})
		row[index_of(p, axis)] = p
		by_line[line_of(p, axis)] = row
	for p in positions:
		var idx := index_of(p, axis)
		if idx < at:
			out["near"] = int(out["near"]) + 1
		else:
			out["far"] = int(out["far"]) + 1
		var m := mirror_index(at, idx)
		if m < 0:
			overhang.append(p)          # 远侧翻过头：折角伸到近侧边缘之外
			continue
		if m >= extent:
			uncovered.append(p)         # 远侧那半不够长：这一格没被盖到（近侧格会这样）
			continue
		var row2: Dictionary = by_line.get(line_of(p, axis), {})
		if not row2.has(m):
			floating.append(p)          # 对面那格不在盘上（洞 / 形状盘缺格）
			continue
		# 配对**只从远侧产出**一次：镜像是对合，若两侧都产出会把每一对记两遍。
		# a 恒取近侧（底层）、b 恒取远侧（覆层）—— 渲染要用这个顺序。
		if idx >= at:
			pairs.append({"a": row2[m], "b": p})
	# 稳定顺序：按 (线, 索引) 升序 —— 与 canonicalize 的邻居排序同口径，落盘 diff 才可读
	pairs.sort_custom(_pair_before)
	overhang.sort_custom(_pos_before)
	uncovered.sort_custom(_pos_before)
	floating.sort_custom(_pos_before)
	out["ok"] = true
	out["pairs"] = pairs
	out["overhang"] = overhang
	out["uncovered"] = uncovered
	out["floating"] = floating
	out["unpaired"] = overhang.size() + uncovered.size() + floating.size()
	return out


## 只取配对表（audit 的薄封装；参数非法 ⇒ 空数组，问题由 normalize/attach 报）。
static func pairs_of(fold: Dictionary, positions: Array[Vector2i]) -> Array:
	return audit(fold, positions)["pairs"] as Array


## 对家表：key_of(pos) → 对家 Vector2i，**双向**（每一对登记两条）。
## 渲染与测试都从这里查"这一格压着谁 / 被谁压着"，避免各自再算一遍镜像。
static func pair_map(pairs: Array) -> Dictionary:
	var out: Dictionary = {}
	for pr_v: Variant in pairs:
		if not (pr_v is Dictionary):
			continue
		var pr: Dictionary = pr_v
		var a: Vector2i = pr["a"]
		var b: Vector2i = pr["b"]
		out[key_of(a)] = b
		out[key_of(b)] = a
	return out


## 单点查询：没有对家 ⇒ null（注意返回 Variant：调用方必须显式判空，不许直接当 Vector2i 用）。
static func partner_of(pairs: Array, p: Vector2i) -> Variant:
	var m := pair_map(pairs)
	return m.get(key_of(p), null)


static func key_of(p: Vector2i) -> String:
	return "%d,%d" % [p.x, p.y]


static func _pair_before(x: Dictionary, y: Dictionary) -> bool:
	var a: Vector2i = x["a"]
	var b: Vector2i = y["a"]
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x


static func _pos_before(a: Vector2i, b: Vector2i) -> bool:
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x
