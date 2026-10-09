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


## 解析折痕声明 → 折痕数组。两种形态**都认**（读侧不许二选一）：
##   · 单折 {axis, at}                  —— 官方 fold_01..06 落盘用的就是它（历史格式，别改）；
##   · 多折 {folds: [{axis, at}, ...]}  —— 折纸族：一张盘按顺序折多次。
## 返回的是**未校验**的原始折痕（轴名可能非法 / at 可能是 JSON 读回来的浮点）；
## 校验与归一化走 normalize_folds。
static func fold_list(decl: Dictionary) -> Array:
	var out: Array = []
	var fs_v: Variant = decl.get("folds", null)
	if fs_v is Array:
		for f_v: Variant in (fs_v as Array):
			if not (f_v is Dictionary):
				continue
			var fd: Dictionary = f_v
			out.append({"axis": str(fd.get("axis", "")), "at": int(fd.get("at", 0))})
		return out
	if decl.has("axis") or decl.has("at"):
		out.append({"axis": str(decl.get("axis", "")), "at": int(decl.get("at", 0))})
	return out


## 折痕序列的显示文本（编辑器提示 / 报错文案共用，免得两处各拼一遍）。
static func describe(folds: Array) -> String:
	var parts: Array[String] = []
	for f_v: Variant in folds:
		if not (f_v is Dictionary):
			continue
		var fd: Dictionary = f_v
		parts.append("%s@%d" % [str(fd.get("axis", "?")), int(fd.get("at", 0))])
	return " → ".join(parts)


## 折一次之后剩下的纸：只剩**近侧**（该轴索引 < at）那一半。
## 这是多折的关键不变量 —— 后一折只能折到前一折之内，折不到已经翻走的部分。
static func footprint_after(positions: Array[Vector2i], axis: String, at: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for p in positions:
		if index_of(p, axis) < at:
			out.append(p)
	return out


## 校验一串折痕（顺序折叠）。比单折多两条规则：
##   · 每一折都按**当前**纸面校验（at 落在当下这张纸内，不是原始盘面内）；
##   · **同一条轴上的 at 必须严格递减**：折过一次后纸只剩近侧那么宽，后一折若不更靠内，
##     就一格都折不到 —— 那是作者的 bug，直接拒（而不是默默产出一张"少折一次"的盘）。
## 返回 {ok, folds, errors}；folds 是规范化后的折痕（at 已转 int，JSON 读回的浮点也归一）。
static func normalize_folds(folds: Array, positions: Array[Vector2i]) -> Dictionary:
	var errors: Array[String] = []
	var out: Array = []
	var last_at: Dictionary = {}
	var cur: Array[Vector2i] = positions.duplicate()
	for i in folds.size():
		var f: Dictionary = folds[i] if folds[i] is Dictionary else {}
		# 【判据顺序】先判「同轴必须严格递减」，再判「落在当前纸面内」：
		# 后者对前者是蕴含关系（折过之后 extent ≤ 上一折的 at），谁先判决定用户看到哪句报错。
		# 同一条折痕写两遍时，「at=4 落在盘外（该轴只有 4 格宽）」虽然也没错，但点不出真正原因 ——
		# 先判递减，报错才是作者能直接改的那一句。
		var raw_axis := str(f.get("axis", ""))
		var raw_at := int(f.get("at", 0))
		if last_at.has(raw_axis) and raw_at >= int(last_at[raw_axis]):
			errors.append("第 %d 折：折痕 at=%d 没有比同轴上一折（at=%d）更靠内 —— 折过一次后纸只剩近侧那么宽，后一折必须严格递减" % [i + 1, raw_at, int(last_at[raw_axis])])
			continue
		var norm := normalize(f, cur)
		if not bool(norm["ok"]):
			for e_v: Variant in (norm["errors"] as Array):
				errors.append("第 %d 折：%s" % [i + 1, str(e_v)])
			continue
		var nf: Dictionary = norm["fold"]
		var axis := str(nf["axis"])
		var at := int(nf["at"])
		last_at[axis] = at
		out.append(nf)
		cur = footprint_after(cur, axis, at)
	return {"ok": errors.is_empty(), "folds": out, "errors": errors}


## 顺序折叠的审计。**逐折复用单折 audit()** —— 同一套 overhang / uncovered / floating 分类，
## 绝不在这里另写一套口径（本仓最恨"两处判据漂移"）：每一折算出这一折的配对，
## 把远侧那一摞整体叠到近侧那一摞上面，再折下一折。
##
## 返回 {ok, errors, folds, pairs, stacks, layers_max, overhang, uncovered, floating, unpaired, dropped}：
##   · pairs      —— 全部叠合对（含第 1 折就叠上的）；a 恒为**底层**、b 恒为**覆层**；
##   · stacks     —— 只列 ≥2 层的摞（层序：底层在前、覆层在后）；渲染与测试都读它；
##   · layers_max —— 最厚那一摞有几层（生成器按它挑难度，玩家按它估读盘难度）；
##   · unpaired   —— 折完仍然单着的格数（含被折出纸外的）；
##   · dropped    —— 折过头落到纸外的格（镜像索引 < 0）。它们已不在折好的纸上 ⇒
##                   后续折不再参与，也不再重复计入后面几折的分类。
## 单折输入 ⇒ 与 audit() 逐字段一致（有对拍用例钉住，见 test_fold_model.gd）。
static func audit_folds(folds: Array, positions: Array[Vector2i]) -> Dictionary:
	var norm := normalize_folds(folds, positions)
	var out := {"ok": false, "errors": norm["errors"], "folds": norm["folds"],
			"pairs": [], "stacks": [], "layers_max": 1, "overhang": [], "uncovered": [],
			"floating": [], "unpaired": positions.size(), "dropped": []}
	if not bool(norm["ok"]):
		return out
	# 摞：key → {pos, layers}。初始每格各成一摞，折一次把两摞并成一摞。
	var stacks: Dictionary = {}
	for p in positions:
		stacks[key_of(p)] = {"pos": p, "layers": [p]}
	var overhang: Array = []
	var uncovered: Array = []
	var floating: Array = []
	var dropped: Array = []
	for f_v: Variant in (norm["folds"] as Array):
		var f: Dictionary = f_v
		var axis := str(f["axis"])
		var at := int(f["at"])
		var cur: Array[Vector2i] = []
		for k_v: Variant in stacks:
			cur.append(stacks[k_v]["pos"])
		var rep := audit(f, cur)
		for o_v: Variant in (rep["overhang"] as Array):
			overhang.append(o_v)
		for u_v: Variant in (rep["uncovered"] as Array):
			uncovered.append(u_v)
		for fl_v: Variant in (rep["floating"] as Array):
			floating.append(fl_v)
		# 远侧那摞整体叠到近侧那摞上面（层序：底层在前 ⇒ 用 append）。
		for pr_v: Variant in (rep["pairs"] as Array):
			var pr: Dictionary = pr_v
			var ka := key_of(pr["a"])
			var kb := key_of(pr["b"])
			if not (stacks.has(ka) and stacks.has(kb)):
				continue
			var la: Array = stacks[ka]["layers"]
			for ly_v: Variant in (stacks[kb]["layers"] as Array):
				la.append(ly_v)
			stacks.erase(kb)
		# 折完之后纸只剩近侧：没配上的远侧格已被折出纸外 —— 退出后续折。
		for k2_v: Variant in stacks.keys():
			var pos2: Vector2i = stacks[k2_v]["pos"]
			if index_of(pos2, axis) >= at:
				dropped.append(pos2)
				stacks.erase(k2_v)
	var pairs: Array = []
	var stacks_out: Array = []
	var layers_max := 1
	var singles := 0
	for k3_v: Variant in stacks:
		var layers: Array = stacks[k3_v]["layers"]
		layers_max = maxi(layers_max, layers.size())
		if layers.size() < 2:
			singles += 1
			continue
		stacks_out.append({"pos": stacks[k3_v]["pos"], "layers": layers.duplicate()})
		for i in layers.size():
			for j in range(i + 1, layers.size()):
				pairs.append({"a": layers[i], "b": layers[j]})
	pairs.sort_custom(_pair_before)
	stacks_out.sort_custom(_stack_before)
	dropped.sort_custom(_pos_before)
	out["ok"] = true
	out["pairs"] = pairs
	out["stacks"] = stacks_out
	out["layers_max"] = layers_max
	out["overhang"] = overhang
	out["uncovered"] = uncovered
	out["floating"] = floating
	out["unpaired"] = singles + dropped.size()
	out["dropped"] = dropped
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


## 配对排序：先按 a（底层）升序；a 相同时按 b（覆层）升序。
## 【为什么带 b 这一层】多折时同一格可以叠好几层 ⇒ 同一个 a 会出多条；单折时 a 唯一，
## 加这一层不影响既有顺序（落盘 diff 不会因此变化）。
static func _pair_before(x: Dictionary, y: Dictionary) -> bool:
	var a: Vector2i = x["a"]
	var b: Vector2i = y["a"]
	if a.y != b.y:
		return a.y < b.y
	if a.x != b.x:
		return a.x < b.x
	var c: Vector2i = x["b"]
	var d: Vector2i = y["b"]
	if c.y != d.y:
		return c.y < d.y
	return c.x < d.x


static func _stack_before(x: Dictionary, y: Dictionary) -> bool:
	return _pos_before(x["pos"], y["pos"])


static func _pos_before(a: Vector2i, b: Vector2i) -> bool:
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x
