class_name RuleLegend
extends RefCounted

## 自创变体的「图文图例」生成器（P6 / P6b，2026-10-02）。
##
## 用户原话（P6b，参考了另一款扫雷的教程截图）：教程要有**文字解释变体规则**，还要有
## **棋盘演示示例——什么样的满足、什么样的不满足，不满足的标记出来**（黄旗=雷，红叉旗=违规的雷）。
##
## 【为什么做成"教程 txt"而不是新造一套图】仓库既有教程系统（`core/tutorial.gd` +
## `ui/tutorial_overlay.gd`）已经能渲染"棋盘示意图 + 注解（{@!} 强调 / {@clue} 数字 / {@x} 红叉）+ 正文"，
## 游戏里点书本图标就看当前变体的教程。所以图例按同一格式生成若干页 txt，随工坊包携带
##（`WorkshopPack.build` 的 `tutorial_dirs`），装到玩家机器上落进 `user://mods/<id>/tutorial/`。
##
## 【两种演示，各自的权威来源】
##   · 数字怎么读（线索型）：棋盘数字由 `Board` 走**与游戏显示同一条**路径算出——另算一遍必然漂移。
##   · 满足 / 不满足（布局型）：合法布局由该规则的 `place_mines` 产出（插件契约：产出必合法），
##     违规布局由 **`RuleOracle.check`（生成器同款裁判）判定为 false** 才上页面；
##     红叉标的是"被挪动的那颗雷"——基准布局合法 ⇒ 违规必然由这次挪动引入 ⇒ 标记有依据，不是猜的。
##     造不出违规例子时**如实说造不出**（宁缺勿错：标错的图例比没有图例更糟）。

const DEMO_SIDE := 5
## 线索演示用固定雷位（5×5、对角三雷）——固定才能写进测试当契约。
## 【2026-10-02 用户反馈："教程格子数字只有 0" —— 待办】
## 根因：雷摆在 (0,0)/(2,2)/(4,4) 彼此隔得很远 ⇒ 示例盘上绝大多数格子周围没有雷，一片 0。
## 试过改成"挤成一簇 + 一个远点"（盘上会出现 0/1/2/3），但**既有断言会红**（示例盘的雷数/内容被写进了
## 单测与 test/ui 用例）⇒ 与"一页多盘"同一类问题：**先定新契约，再改断言**。已回退，避免留红灯。
const DEMO_MINES: Array = [Vector2i(0, 0), Vector2i(2, 2), Vector2i(4, 4)]
## 【2026-10-02 用户口径 B2：一页多盘】**一页里放多张盘**（雷散 / 雷挤 / 贴边），
## 盘与盘之间用 `--` 单独一行分隔（见 `core/tutorial.gd parse` 的 `boards`）。
## 关键：`rows`/`cols` 仍是**第一张盘** ⇒ 「盘面行数 = DEMO_SIDE」「页数 = 1」等既有契约**全部不动**。
const DEMO_CASES: Array = [
	[Vector2i(0, 0), Vector2i(2, 2), Vector2i(4, 4)],          # ① 雷很散 ⇒ 数字多为 0（对照）
	[Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2)],          # ② 雷挤在一起 ⇒ 出 1、2、3
	[Vector2i(0, 0), Vector2i(0, 1), Vector2i(4, 0)],          # ③ 贴边贴角 ⇒ 看边界怎么算
]
const BOARD_SEP := "\n--\n"
## 布局演示的雷数候选：全局规则对数量有约束（如四连块要 4 的倍数）⇒ 依次试到能摆出来为止。
const DEMO_COUNTS: Array = [8, 6, 4, 5, 3, 2]
const DEMO_SEED := 20261002
const MUTATE_TRIES := 60


## 生成一族图例页。返回 {ok, pages:[{id,title,text,layout,kind}], reason}。
## 页序：0 = 线索型"数字怎么读"（有规格时才有）；随后每条全局规则两页：满足（kind="ok"）/ 不满足（kind="bad"）。
## `global_ids` 来自 `EditorDoc.global_rule_ids`（变体带了哪些布局约束）。
## 兼容入口（P6b 签名，规格变体）：等价于 `build_pages_for_ids(rule_id, 线索id, global_ids, spec)`。
static func build_pages(rule_id: String, spec: Dictionary, global_ids: Array) -> Dictionary:
	var clue_id := rule_id if not spec.is_empty() else ""
	return build_pages_for_ids(rule_id, clue_id, global_ids, spec)


## 通用入口（P6f）：**内置规则与玩家自创规格都能用** —— 游戏内全部教程都走这里生成。
## `page_key` = 页 id 前缀（用变体 id）；`clue_id` 为空 ⇒ 不生成「数字怎么读」页。
## 规则文案：有规格用 `SpecHelper.explain_spec`（逐字段解释更细）；内置规则用 `describe().rule_text`
## （官方一句话，与选关页/图鉴同源）。
static func build_pages_for_ids(page_key: String, clue_id: String, global_ids: Array,
		spec: Dictionary = {}) -> Dictionary:
	var pages: Array = []
	if page_key == "":
		return {"ok": false, "pages": [], "reason": "没有规则 id"}
	if clue_id != "":
		var clue := _clue_page(clue_id, spec)
		if bool(clue["ok"]):
			pages.append({"id": page_id(page_key, 0), "title": "数字怎么读",
				"text": str(clue["text"]), "layout": DEMO_MINES.duplicate(), "kind": "clue"})
		else:
			return {"ok": false, "pages": [], "reason": str(clue["reason"])}
	# 布局演示：最多带前 2 条全局规则（页数膨胀没有收益，包也小一点）
	var shown := 0
	var seq := pages.size()
	for gid in global_ids:
		if shown >= 2:
			break
		var g := RuleRegistry.default().resolve(StringName(str(gid)))
		# 只演示**布局型**规则：线索型（含 classic）没有"违规布局"可言；
		# 且基类也有 place_mines 方法 ⇒ 不能用 has_method 判断，必须看 kind。
		if g == null or str(g.call("get_kind")) != RulePlugin.KIND_GLOBAL \
				or not g.has_method("place_mines"):
			continue
		var demo := _layout_demo(g, str(gid), page_key, seq)
		if not (demo["pages"] as Array).is_empty():
			pages.append_array(demo["pages"])
			seq += (demo["pages"] as Array).size()
			shown += 1
		elif str(demo["reason"]) != "":
			# 说明页也要守教程格式（盘面在前 + `?`）——给它一格占位盘，正文放说明
			pages.append({"id": page_id(page_key, seq), "title": str(gid),
				"text": "q\n? " + str(demo["reason"]),
				"layout": [], "kind": "note"})
			seq += 1
			shown += 1
	# 超过 2 条布局规则时不静默省略：**说出来**还有哪几条没做示例（省页数是为了包小，不是为了隐瞒）
	var rest: Array[String] = []
	var seen_global := 0
	for gid in global_ids:
		var gg := RuleRegistry.default().resolve(StringName(str(gid)))
		if gg == null or str(gg.call("get_kind")) != RulePlugin.KIND_GLOBAL:
			continue
		seen_global += 1
		if seen_global > 2:
			rest.append(str(gid))
	if not rest.is_empty():
		pages.append({"id": page_id(page_key, pages.size()), "title": "其余布局规则", "kind": "note",
			"layout": [],
			"text": "q\n? 这个变体还有 %d 条布局规则没有做示例演示：%s\n（示例最多演示 2 条，免得教程页太多；这些规则在游戏里照常生效。）" % [
				rest.size(), "、".join(rest)]})
	if pages.is_empty():
		return {"ok": false, "pages": [], "reason": "这条变体既没有规格线索、也没有可演示的布局规则"}
	return {"ok": true, "pages": pages, "reason": ""}


## 图例页 id（与 `core/tutorial.gd` 的命名契约一致：`tutorial_<规则组合>_<序号>`）。
static func page_id(rule_id: String, seq: int) -> String:
	return "tutorial_%s_%d" % [rule_id, seq]


## 生成并写到 `dir/`（供 `WorkshopPack.build` 的 `tutorial_dirs` 携带）。
## 返回 {ok, path(第一页), dir, count, reason}。
static func write_pages(rule_id: String, spec: Dictionary, global_ids: Array, dir: String) -> Dictionary:
	var built := build_pages(rule_id, spec, global_ids)
	if not bool(built["ok"]):
		return {"ok": false, "path": "", "dir": "", "count": 0, "reason": str(built["reason"])}
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var first := ""
	for p in (built["pages"] as Array):
		var d: Dictionary = p
		var path := "%s/%s.txt" % [dir, str(d["id"])]
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return {"ok": false, "path": first, "dir": dir, "count": 0,
				"reason": "图例写不进去：%s" % path}
		f.store_string(str(d["text"]))
		f.close()
		if first == "":
			first = path
	return {"ok": true, "path": first, "dir": dir,
		"count": (built["pages"] as Array).size(), "reason": ""}


## 兼容入口（P6 的旧签名）：只写"数字怎么读"那一页。
static func write_page(rule_id: String, spec: Dictionary, dir: String) -> Dictionary:
	return write_pages(rule_id, spec, [], dir)


## 「数字怎么读」页（P6f 起内置规则也能用）：数字仍由 `Board` 走与游戏同一条求值路径算出。
## 有规格时文案用 `SpecHelper.explain_spec`（逐字段解释更细）；内置规则用 `describe().rule_text`
## （官方一句话，与选关页/图鉴同源 ⇒ 不会出现两处说法不一致）。
## 单张示例盘的文本（`{@!}F` = 雷、`{@clue}<值>` = 已翻开格）。数字由 `Board._compute_clues()` 现算
## （与游戏同一条路径）⇒ 不会手写出错。
static func _clue_case_board(clue_id: String, case_mines: Array) -> String:
	var lv := {
		"rule_level": true,
		"clue_rule": clue_id,
		"global_rules": [],
		"size": {"rows": DEMO_SIDE, "cols": DEMO_SIDE},
		"total_mines": case_mines.size(),
		"mines": _mine_dicts(case_mines),
		"revealed": [],
	}
	var b := Board.new()
	b.load_level(lv)
	b._compute_clues()
	var rows_out: Array[String] = []
	for r in DEMO_SIDE:
		var cells: Array[String] = []
		for c in DEMO_SIDE:
			var cell: Cell = b.grid.get_cell(Vector2i(c, r))
			if cell == null:
				cells.append("q")
			elif cell.is_mine:
				cells.append("{@!}F")
			else:
				cells.append("{@clue}%s" % _value_text(cell.value))
		rows_out.append("\t".join(cells))
	return "\n".join(rows_out)


static func _clue_page(clue_id: String, spec: Dictionary) -> Dictionary:
	if clue_id == "":
		return {"ok": false, "text": "", "id": "", "reason": "没有线索规则 id"}
	_ensure_registered(clue_id, spec)
	var rule: Object = RuleRegistry.default().resolve(StringName(clue_id))
	if rule == null:
		return {"ok": false, "text": "", "id": "", "reason": "找不到规则 %s（未注册）" % clue_id}
	var sentence := ""
	if not spec.is_empty():
		sentence = SpecHelper.explain_spec(spec)
	else:
		var d: Dictionary = rule.call("describe")
		sentence = "%s：%s" % [str(d.get("name", clue_id)), str(d.get("rule_text", ""))]
	# 【2026-10-02 用户口径 B2】一页给**三张盘**（雷散 / 雷挤 / 贴边），数字逐盘现算。
	var blocks: Array[String] = []
	for ci in DEMO_CASES.size():
		blocks.append(_clue_case_board(clue_id, DEMO_CASES[ci]))
	var rows_out: Array[String] = [BOARD_SEP.join(blocks)]
	var body := "%s\n\n【怎么看这张图】F = 雷（当作你已经标出来了）；\n" % sentence
	body += "数字 = 已经翻开的格，按这条规则算出来的值 —— 它就是你在游戏里会看到的数字。\n"
	body += "小练习：先别数雷，只看某个数字，按上面的算法亲手核对一遍；能对上，规则就懂了。\n"
	body += "\n【三张盘一起看】① 雷很散（数字多是 0）② 雷挤在一起（数字变 1、2、3）③ 贴边贴角（看边界怎么算）。\n"
	body += "变的是「周围有几颗雷」，算法一个字都没改。"
	return {"ok": true, "text": "\n".join(rows_out) + "\n? " + body, "id": page_id(clue_id, 0), "reason": ""}


## 兼容入口（P6b 签名）：规格变体的「数字怎么读」单页。
static func build_for_rule(rule_id: String, spec: Dictionary) -> Dictionary:
	if rule_id == "" or spec.is_empty():
		return {"ok": false, "text": "", "id": "", "reason": "这条规则不是规格规则，生成不了图文图例"}
	return _clue_page(rule_id, spec)


## 图例能不能被仓库的教程解析器读懂（自校：生成了不等于生成对了）。
static func parsed_ok(rule_id: String, spec: Dictionary) -> String:
	var built := build_for_rule(rule_id, spec)
	if not bool(built["ok"]):
		return str(built["reason"])
	var page := Tutorial.parse(str(built["text"]))
	return str(page.get("error", ""))


## ---------- 布局演示（满足 / 不满足） ----------

## 对一条全局规则造"满足 + 不满足"两页。
## 返回 {pages:[...], reason}；造不出违规例子时 pages 只含满足页，reason 说明原因。
## 【2026-10-02 用户口径 B2】"满足的例子"给**多张盘**：同一规则、不同雷数（数字因此不同，用户原话
## "热度的教程格子数字只有 0，多放几个其他情况"）。每张候选盘都必须**过裁决器**（宁缺勿错）——
## 凑不出就少放，绝不放未经裁判的盘。
static func _boards_for_ok(g: Object, judge: Object, base_mines: Array[Vector2i], base_count: int) -> String:
	var blocks: Array[String] = [_board(base_mines, Vector2i(-9, -9))]
	for c in DEMO_COUNTS:
		if blocks.size() >= 3:
			break
		if int(c) == base_count:
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = DEMO_SEED
		var m: Array[Vector2i] = g.call("place_mines", rng, DEMO_SIDE, DEMO_SIDE, int(c))
		if m.size() != int(c):
			continue
		if judge == null or not bool(judge.call("check", m, {}, Vector2i(DEMO_SIDE, DEMO_SIDE))):
			continue
		blocks.append(_board(m, Vector2i(-9, -9)))
	return BOARD_SEP.join(blocks)


static func _layout_demo(g: Object, gid: String, rule_id: String, seq: int) -> Dictionary:
	var d: Dictionary = g.call("describe")
	var sentence := str(d.get("rule_text", d.get("name", gid)))
	# ① 合法布局：插件自己的构造式布雷（契约保证产出合法），数量依次试
	var mines: Array[Vector2i] = []
	var count := 0
	for c in DEMO_COUNTS:
		var rng := RandomNumberGenerator.new()
		rng.seed = DEMO_SEED
		var m: Array[Vector2i] = g.call("place_mines", rng, DEMO_SIDE, DEMO_SIDE, int(c))
		if m.size() == int(c):
			mines = m
			count = int(c)
			break
	if mines.is_empty():
		return {"pages": [], "reason": "%s 在 %d×%d 上摆不出演示雷位" % [sentence, DEMO_SIDE, DEMO_SIDE]}
	var judge := _judge(rule_id, [g], count)
	if judge == null or not bool(judge.call("check", mines, {}, Vector2i(DEMO_SIDE, DEMO_SIDE))):
		# 连插件自己摆的都判不合法 ⇒ 裁判与插件口径不一致，**不上页面**（宁缺勿错）
		return {"pages": [], "reason": "裁判否决了 %s 的合法布局（口径不一致），已跳过演示" % gid}
	var pages: Array = []
	# 教程格式：**盘面在前**，`?` 行之后才是正文（解析器按此切分——第一版把句子放前面，直接解析失败）
	pages.append({"id": page_id(rule_id, seq), "title": gid, "kind": "ok",
		"layout": mines.duplicate(),
		"text": _boards_for_ok(g, judge, mines, count) + "\n? " + sentence
			+ "\n\n【满足的例子】盘上的雷都符合规则（若上面有多张盘，每一张都满足）。\n"
			+ "先自己看一遍：每颗雷的位置都符合上面这句话。"})
	# ② 违规布局：把一颗雷挪个位置，**用裁判确认整盘违规**才收下。
	#    基准布局合法 ⇒ 任何违规必然由这次挪动引入 ⇒ 红叉标"被挪动的雷"是有依据的。
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = DEMO_SEED + 1
	var free: Array[Vector2i] = []
	for y in DEMO_SIDE:
		for x in DEMO_SIDE:
			if not mines.has(Vector2i(x, y)):
				free.append(Vector2i(x, y))
	for t in MUTATE_TRIES:
		if free.is_empty() or mines.is_empty():
			break
		var mi := rng2.randi_range(0, mines.size() - 1)
		var dest := free[rng2.randi_range(0, free.size() - 1)]
		if mines.has(dest):
			continue
		var moved: Vector2i = mines[mi]
		var cand := mines.duplicate()
		cand[mi] = dest
		if bool(judge.call("check", cand, {}, Vector2i(DEMO_SIDE, DEMO_SIDE))):
			continue      # 挪完仍然合法 ⇒ 不是违规例子，换一种挪法
		pages.append({"id": page_id(rule_id, seq + 1), "title": gid, "kind": "bad",
			"layout": cand,
			"text": _board(cand, moved) + "\n? " + sentence
				+ "\n\n【不满足的例子】这一盘**不满足**规则（求解器判定违规）。\n"
				+ "红叉（×）标的是被挪动的那颗雷：它一挪，整盘就不合规了。\n"
				+ "玩的时候要找的就是这种摆法——按规则把它们排除掉。"})
		return {"pages": pages, "reason": ""}
	return {"pages": pages, "reason": "试了 %d 种挪法都仍然合法（这条约束在演示盘上很难违反）" % MUTATE_TRIES}


## 布局 → 教程盘面文本。`marked` 那格的旗画红叉（{@x}），其余雷画 {@!}F，空格画 q。
static func _board(mines: Array[Vector2i], marked: Vector2i) -> String:
	var rows_out: Array[String] = []
	for y in DEMO_SIDE:
		var cells: Array[String] = []
		for x in DEMO_SIDE:
			var p := Vector2i(x, y)
			if p == marked:
				cells.append("{@x}F")
			elif mines.has(p):
				cells.append("{@!}F")
			else:
				cells.append("q")
		rows_out.append("\t".join(cells))
	return "\n" + "\n".join(rows_out)


## 组一个裁判：与生成器同款（`RuleOracle`），规格线索规则已注册就带上（判得更严）。
static func _judge(rule_id: String, globals: Array, count: int) -> Object:
	var clue_rule: Object = null
	if rule_id != "":
		clue_rule = RuleRegistry.default().resolve(StringName(rule_id))
	return RuleOracle.new(clue_rule, globals, Vector2i(DEMO_SIDE, DEMO_SIDE), count, null)


static func _ensure_registered(rule_id: String, spec: Dictionary) -> void:
	if RuleRegistry.default().resolve(StringName(rule_id)) != null:
		return
	# 注册失败不改流程：`Board` 会退回经典口径；注册失败本身在导入规格时已报给用户。
	SpecRulePlugin.register_from_json(JSON.stringify(spec))


static func _mine_dicts(mines: Array) -> Array:
	var out: Array = []
	for m in mines:
		out.append({"r": (m as Vector2i).y, "c": (m as Vector2i).x})
	return out


## 线索值 → 一格文本（多线索/无穷都要能显示，不能崩也不能漏）。
static func _value_text(v: Variant) -> String:
	if v is Array:
		var parts: Array[String] = []
		for x in (v as Array):
			parts.append(str(x))
		return "/".join(parts)
	var s := str(v)
	return "∞" if s == "inf" else s
