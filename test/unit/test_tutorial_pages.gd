# test_tutorial_pages.gd —— 教程页内容守卫（2026-09-23）
#
# 背景：教程入口改为「上下文相关」后（选关页弹窗 / 对局 HUD 点开的是**当前变体**的教程），
# 每个官方席位都必须有内容，否则入口点了只能看到「暂无教程内容」。补齐 16 席时还发现
# 历史教程页的盘面数字是「示意性」的（与规则实算不符——玩家照着数格子会被教错）。
#
# 本文件把三条独立验证链钉成守卫：
#   ① 官方席位（VariantCatalog 三轴名单，唯一事实源）都有教程页；
#   ② 每页盘面的数字格 == 规则实现（RuleRegistry）正向计算的值；
#   ③ 每页盘面**满足它自己讲的那条约束**——②对观测算子够用（线索即规则，数字对了盘面
#      就对），但结构/守恒轴是**约束型**：数字走经典计数、与约束无关，盘面完全可能
#      「数字全对但约束不成立」（历史 z2/rl 页正是：行雷数 [1,0,2,1,1] 不满足「相邻行差 1」，
#      玩家学到的规则是错的）。③为可判定的约束各写一条独立检查。
#
# 口径说明：
#   · 约束轴席位（s*/z*/dt/pf/mx/rl/qd/4c/ep 等 KIND_GLOBAL）没有自身的线索算法，
#     数字是经典 8 邻计数 → 用 classic 规则核算；
#   · `combo` 组合页正文自述「4N + 镜像」→ 数字按 4N 口径核算；
#   · 规则未加载（legacy Mod 未启用）的页面跳过（不误判）。
extends GutTest

## 全局约束型席位：数字走经典 8 邻计数。
const GLOBAL_SEATS: Array = ["s1", "s2", "s3", "s4", "s5", "s6", "s7",
	"z1", "z2", "z3", "z4", "z5", "dt", "pf", "mx", "rl", "qd", "4c", "ep"]
## 特例：组合页正文自述「4N + 镜像」→ 数字按 4N（正交计数）口径。
const CLUE_OVERRIDE: Dictionary = {"combo": "4n"}


## 官方席位全覆盖：名单直接取 VariantCatalog 的三轴常量（唯一事实源）——
## 以后变体池调整时，新席位若没配教程页，这里立刻红。
func test_official_seats_all_have_pages() -> void:
	for id in VariantCatalog.CLUE_ORDER + VariantCatalog.GLOBAL_ORDER:
		var pages := Tutorial.pages_for(str(id))
		assert_gt(pages.size(), 0,
			"官方席位 %s 应有教程页（否则入口点了只看到「暂无教程内容」）" % str(id))


## 每页盘面自洽：数字格显示的值必须等于规则实现在该雷布局下算出的线索值。
func test_every_page_board_matches_rule() -> void:
	var ids := Tutorial.list_ids()
	assert_gt(ids.size(), 0, "levels/tutorial 下应有教程页")
	for page_id in ids:
		_check_numbers(page_id)


## 每页盘面满足自身约束（见文件头 ③）。
func test_page_boards_satisfy_own_constraint() -> void:
	var checked := 0
	for page_id in Tutorial.list_ids():
		var combo := _combo_of(page_id)
		if _constraint_of(combo) == "":
			continue  # 观测算子（②已覆盖）/ s7（K 是关卡参数，无通用判据）
		var page := Tutorial.load_page(page_id)
		var mines := _mines_of(page)
		var board := Vector2i(int(page["cols"]), (page["rows"] as Array).size())
		_check_constraint(combo, page_id, mines, board)
		checked += 1
	assert_gt(checked, 0, "至少应有若干约束型页面被检查（防分派表写错导致空跑）")


# ============ ② 数字核对 ============

func _check_numbers(page_id: String) -> void:
	var clue_rule := _clue_rule_of(page_id)
	var rule: Object = RuleRegistry.default().resolve(StringName(clue_rule))
	if rule == null:
		return  # 规则未加载（legacy Mod / 新算子）——跳过，不误判
	var page := Tutorial.load_page(page_id)
	assert_eq(str(page.get("error", "")), "", "%s 应能解析" % page_id)
	if str(page.get("error", "")) != "":
		return
	var rows: Array = page["rows"]
	var board := Vector2i(int(page["cols"]), rows.size())
	var mines := _mines_of(page)
	for r in rows.size():
		for c in (rows[r] as Array).size():
			var cell: Dictionary = (rows[r] as Array)[c]
			var v := str(cell.get("value", ""))
			if v == "" or v == "q" or v == "F" or v == "D" or v == "∞":
				continue
			if Tutorial.is_wrong(cell.get("annotations", [])):
				continue  # 错误标记演示格（红叉），不是线索值
			if not v.is_valid_int():
				continue
			var expect: Variant = rule.call("compute_clue", mines, Vector2i(c, r), board)
			if not (expect is int):
				continue
			assert_eq(int(v), int(expect),
				"%s 格(%d,%d) 盘面数字与规则实算不符（clue=%s）" % [page_id, c, r, clue_rule])


# ============ ③ 约束核对 ============

## 该 combo 是否属于「约束必须单独核对」的席位（返回空串 = 不需要）。
func _constraint_of(combo: String) -> String:
	if ["z1", "mx"].has(combo):
		return "mirror"
	if ["z2", "rl"].has(combo):
		return "adjacent_row"
	if ["z3", "qd"].has(combo):
		return "quadrant"
	if combo == "z4":
		return "row_col_same"
	if combo == "z5":
		return "arith_rows"
	if ["s1", "pf"].has(combo):
		return "no_2x2_over"
	if combo == "s2":
		return "centroid"
	if combo == "s3":
		return "acyclic"
	if combo == "s4":
		return "onion"
	if combo == "s5":
		return "row_col_convex"
	if combo == "s6":
		return "even_degree"
	return ""  # 观测算子 / s7（K 为关卡参数）/ 4c、ep（分区守恒需知道分区口径）


func _check_constraint(combo: String, page_id: String, mines: Dictionary, board: Vector2i) -> void:
	match _constraint_of(combo):
		"mirror":
			for y in board.y:
				for x in int(board.x / 2):
					assert_eq(mines.has(Vector2i(x, y)), mines.has(Vector2i(board.x - 1 - x, y)),
						"%s（镜像）第 %d 行第 %d 列与镜像列应同时为雷/同时为空" % [page_id, y, x])
		"adjacent_row":
			var rc := _row_counts(mines, board)
			for r in rc.size() - 1:
				assert_eq(absi(int(rc[r + 1]) - int(rc[r])), 1,
					"%s（相邻行锁）第 %d/%d 行雷数应差 1，实为 %d/%d" % [
							page_id, r, r + 1, int(rc[r]), int(rc[r + 1])])
		"quadrant":
			var sums := [0, 0, 0, 0]
			for y in board.y:
				for x in board.x:
					if not mines.has(Vector2i(x, y)):
						continue
					var qi := ConstraintEngine.quadrant_of(y, x, board.y, board.x)
					if qi >= 0:
						sums[qi] = int(sums[qi]) + 1
			assert_eq(sums[0], sums[1], "%s（四象）四象限雷数应相等，实为 %s" % [page_id, str(sums)])
			assert_eq(sums[1], sums[2], "%s（四象）四象限雷数应相等，实为 %s" % [page_id, str(sums)])
			assert_eq(sums[2], sums[3], "%s（四象）四象限雷数应相等，实为 %s" % [page_id, str(sums)])
		"row_col_same":
			var rc2 := _row_counts(mines, board)
			var cc := _col_counts(mines, board)
			for i in mini(rc2.size(), cc.size()):
				assert_eq(int(rc2[i]), int(cc[i]),
					"%s（行列同序）第 %d 行雷数应等于第 %d 列雷数，实为 %d/%d" % [
							page_id, i, i, int(rc2[i]), int(cc[i])])
		"arith_rows":
			var rc3 := _row_counts(mines, board)
			if rc3.size() >= 3:
				var d := int(rc3[1]) - int(rc3[0])
				for i in range(2, rc3.size()):
					assert_eq(int(rc3[i]) - int(rc3[i - 1]), d,
						"%s（等差行）行雷数应成等差（公差 %d），实为 %s" % [page_id, d, str(rc3)])
		"no_2x2_over":
			for y in board.y - 1:
				for x in board.x - 1:
					var n := 0
					for dy in 2:
						for dx in 2:
							if mines.has(Vector2i(x + dx, y + dy)):
								n += 1
					assert_lte(n, 2, "%s（局部禁形）2×2 窗口(%d,%d)有 %d 雷，应 ≤2" % [
							page_id, x, y, n])
		"centroid":
			if mines.is_empty():
				return
			var sx := 0
			var sy := 0
			for p in mines:
				sx += int((p as Vector2i).x)
				sy += int((p as Vector2i).y)
			var n := float(mines.size())
			# 中央格区：奇数边长 = 正中 1 格；偶数边长 = 正中 2×2（与 S2 实现同式）
			var lo_x := float(int((board.x - 1) / 2))
			var hi_x := float(int(board.x / 2))
			var lo_y := float(int((board.y - 1) / 2))
			var hi_y := float(int(board.y / 2))
			assert_between(float(sx) / n, lo_x - 1e-9, hi_x + 1e-9,
				"%s（重心）雷的横向均值应落在中央格区" % page_id)
			assert_between(float(sy) / n, lo_y - 1e-9, hi_y + 1e-9,
				"%s（重心）雷的纵向均值应落在中央格区" % page_id)
		"acyclic":
			# 8 连通森林判据：相邻对数 == 点数 − 分量数（等式成立 ⟺ 无环）
			var edges := 0
			for p in mines:
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dy == 0:
							continue
						var q: Vector2i = (p as Vector2i) + Vector2i(dx, dy)
						if mines.has(q) and (q.x > (p as Vector2i).x or
								(q.x == (p as Vector2i).x and q.y > (p as Vector2i).y)):
							edges += 1
			assert_eq(edges, mines.size() - _component_count(mines),
				"%s（无环）雷应连成链/树：相邻对 %d、点数 %d、分量数 %d" % [
						page_id, edges, mines.size(), _component_count(mines)])
		"onion":
			# 层 = 到最近边的距离；「越靠里越密」= 层密度随层号单调不减
			var sizes := {}
			var hit := {}
			for y in board.y:
				for x in board.x:
					var l := mini(mini(x, y), mini(board.x - 1 - x, board.y - 1 - y))
					sizes[l] = int(sizes.get(l, 0)) + 1
					if mines.has(Vector2i(x, y)):
						hit[l] = int(hit.get(l, 0)) + 1
			for l in sizes.size() - 1:
				var inner := float(hit.get(l + 1, 0)) / float(sizes[l + 1])
				var outer := float(hit.get(l, 0)) / float(sizes[l])
				assert_gte(inner + 1e-9, outer,
					"%s（洋葱）里层(层%d)密度 %.3f 应 ≥ 外层(层%d) %.3f" % [
							page_id, l + 1, inner, l, outer])
		"row_col_convex":
			for y in board.y:
				var xs: Array = []
				for x in board.x:
					if mines.has(Vector2i(x, y)):
						xs.append(x)
				for i in range(1, xs.size()):
					assert_eq(int(xs[i]), int(xs[i - 1]) + 1,
						"%s（行列凸）第 %d 行的雷应连续，实为 %s" % [page_id, y, str(xs)])
			for x in board.x:
				var ys: Array = []
				for y in board.y:
					if mines.has(Vector2i(x, y)):
						ys.append(y)
				for i in range(1, ys.size()):
					assert_eq(int(ys[i]), int(ys[i - 1]) + 1,
						"%s（行列凸）第 %d 列的雷应连续，实为 %s" % [page_id, x, str(ys)])
		"even_degree":
			for p in mines:
				var deg := 0
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dy == 0:
							continue
						if mines.has((p as Vector2i) + Vector2i(dx, dy)):
							deg += 1
				assert_eq(deg % 2, 0, "%s（度偶数）雷 %s 的邻雷数为 %d，应为偶数" % [
						page_id, str(p), deg])


# ============ 辅助 ============

func _combo_of(page_id: String) -> String:
	var body: String = page_id.substr("tutorial_".length())
	var cut := body.rfind("_")
	return body.substr(0, cut) if cut > 0 else body


func _clue_rule_of(page_id: String) -> String:
	var combo := _combo_of(page_id)
	return "classic" if GLOBAL_SEATS.has(combo) else str(CLUE_OVERRIDE.get(combo, combo))


func _mines_of(page: Dictionary) -> Dictionary:
	var mines := {}
	var rows: Array = page.get("rows", [])
	for r in rows.size():
		for c in (rows[r] as Array).size():
			if str(((rows[r] as Array)[c] as Dictionary).get("value", "")) == "F":
				mines[Vector2i(c, r)] = true
	return mines


func _row_counts(mines: Dictionary, board: Vector2i) -> Array:
	var out: Array = []
	for y in board.y:
		var n := 0
		for x in board.x:
			if mines.has(Vector2i(x, y)):
				n += 1
		out.append(n)
	return out


func _col_counts(mines: Dictionary, board: Vector2i) -> Array:
	var out: Array = []
	for x in board.x:
		var n := 0
		for y in board.y:
			if mines.has(Vector2i(x, y)):
				n += 1
		out.append(n)
	return out


## 8 连通分量数（BFS）。
func _component_count(mines: Dictionary) -> int:
	var seen := {}
	var comps := 0
	for start in mines:
		if seen.has(start):
			continue
		comps += 1
		var queue: Array = [start]
		seen[start] = true
		while not queue.is_empty():
			var p: Vector2i = queue.pop_back()
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var q: Vector2i = p + Vector2i(dx, dy)
					if mines.has(q) and not seen.has(q):
						seen[q] = true
						queue.append(q)
	return comps
