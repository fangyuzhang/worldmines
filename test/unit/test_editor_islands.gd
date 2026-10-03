# test_editor_islands.gd —— 按岛分别判定可解性（W4）自证
#
# 钉住的不变量：
#   1) **单岛盘**：`verify_islands()` 与旧 `verify()` 结论逐一一致（回归不许红）；
#   2) **双岛盘**：障碍列把盘切成两个连通分量，每岛各自给结论 + 各自的格集合与雷数；
#   3) **合成**：一岛可解 + 一岛需猜 ⇒ 整体 needs_guess，理由点明「第 N 号岛需要盲猜 K 次」；
#      全岛可解 ⇒ 整体 no_guess。
extends GutTest


func _doc(p_rows: int, p_cols: int, mine_list: Array) -> EditorDoc:
	var d := EditorDoc.new(p_rows, p_cols)
	for m in mine_list:
		d.mines.append(m)
	return d


## 5x5 盘 + 障碍列 x=2（全行）⇒ 切成左（x0..1）/右（x3..4）两个 10 格岛。
func _split_doc() -> EditorDoc:
	var d := EditorDoc.new(5, 5)
	for y in range(5):
		d.obstacles.append(Vector2i(2, y))
	return d


## 左岛：1 雷 (0,0) + 翻开其余 9 格（唯一自由格=雷 ⇒ 必然可推完）。
## 右岛：2 雷（(3,1)、(4,3)）**只**翻开 (4,2)（值 2、0<2<度-1 ⇒ 单条线索钉不住任何格 ⇒ 需猜）。
func _one_solvable_one_guessy() -> EditorDoc:
	var d := _split_doc()
	d.mines.append(Vector2i(0, 0))
	d.mines.append(Vector2i(3, 1))
	d.mines.append(Vector2i(4, 3))
	for y in range(5):
		for x in [0, 1]:
			var p := Vector2i(x, y)
			if not d.mines.has(p):
				d.revealed[p] = null
	d.revealed[Vector2i(4, 2)] = null
	return d


func _by_id(islands: Array) -> Dictionary:
	var out := {}
	for it in islands:
		out[int((it as Dictionary)["id"])] = it
	return out


# ==================== 1. 单岛与旧口径一致 ====================

func test_single_island_matches_legacy_verify() -> void:
	var d := _doc(3, 3, [Vector2i(2, 2)])
	d.revealed[Vector2i(0, 0)] = null
	var v := EditorVerify.verify(d)
	var r := EditorVerify.verify_islands(d)
	assert_eq(str(r["state"]), str(v["state"]), "单岛盘必须与 verify() 同结论：%s vs %s" % [str(r["state"]), str(v["state"])])
	var islands: Array = (r["stats"] as Dictionary)["islands"]
	assert_eq(islands.size(), 1, "单岛盘应恰好 1 个岛")
	assert_eq((islands[0]["cells"] as Array).size(), 9, "3x3 的岛应含 9 格")
	assert_eq(str(islands[0]["state"]), str(r["state"]), "岛结论应与整体结论一致")


func test_single_island_needs_guess_matches_legacy_verify() -> void:
	var mine_list := [
		Vector2i(3, 3), Vector2i(5, 5),
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1),
		Vector2i(0, 2), Vector2i(2, 2),
	]
	var d := _doc(9, 9, mine_list)
	d.revealed[Vector2i(4, 4)] = null
	var v := EditorVerify.verify(d)
	var r := EditorVerify.verify_islands(d)
	assert_eq(str(r["state"]), str(v["state"]), "需猜的单岛盘也要与 verify() 同结论")
	assert_eq(str(r["state"]), EditorVerify.STATE_NEEDS_GUESS)


# ==================== 2. 双岛各自结论 + 格集合 ====================

func test_two_islands_report_their_own_conclusions_and_cells() -> void:
	var d := _one_solvable_one_guessy()
	var r := EditorVerify.verify_islands(d)
	var islands: Array = (r["stats"] as Dictionary)["islands"]
	assert_eq(islands.size(), 2, "障碍列应把盘切成两个岛：%s" % str(islands))

	# 格集合：两岛不重不漏，恰好覆盖 20 个非障碍格
	var seen := {}
	for it in islands:
		var cells: Array = (it as Dictionary)["cells"]
		for p in cells:
			assert_false(seen.has(p), "岛之间不得共享格：%s" % str(p))
			seen[p] = true
		assert_eq(int(it["cell_count"]), cells.size(), "cell_count 应与格集合同长")
	assert_eq(seen.size(), 20, "两岛应恰好覆盖 20 个非障碍格")

	var by_id := _by_id(islands)
	assert_eq(str(by_id[1]["state"]), EditorVerify.STATE_NO_GUESS, "左岛应判为无需猜测：%s" % str(by_id[1]))
	assert_eq(str(by_id[2]["state"]), EditorVerify.STATE_NEEDS_GUESS, "右岛应判为需要猜测：%s" % str(by_id[2]))
	assert_eq(int(by_id[1]["mines"]), 1, "左岛雷数应为 1")
	assert_eq(int(by_id[2]["mines"]), 2, "右岛雷数应为 2")
	assert_true(int(by_id[2]["guesses"]) >= 1, "需猜的岛至少要数出 1 次盲猜：%s" % str(by_id[2]))
	assert_true(int(by_id[2]["left"]) >= 1, "需猜的岛应还有推不出的格")


# ==================== 3. 整体 = 各岛合成 ====================

func test_overall_needs_guess_when_one_island_needs_guess() -> void:
	var d := _one_solvable_one_guessy()
	var r := EditorVerify.verify_islands(d)
	assert_eq(str(r["state"]), EditorVerify.STATE_NEEDS_GUESS, "一岛可解一岛需猜 ⇒ 整体需猜：%s" % str(r["reason"]))
	assert_true(str(r["reason"]).find("盲猜") != -1, "整体理由应点明岛级盲猜：%s" % str(r["reason"]))
	assert_true(str(r["reason"]).find("2 号岛") != -1, "整体理由应点名是哪个岛需猜：%s" % str(r["reason"]))
	assert_eq(int((r["stats"] as Dictionary).get("island_count", -1)), 2, "stats 应带 island_count")


func test_overall_no_guess_when_all_islands_solvable() -> void:
	var d := _split_doc()
	d.mines.append(Vector2i(0, 0))
	d.mines.append(Vector2i(3, 0))
	for y in range(5):
		for x in [0, 1, 3, 4]:
			var p := Vector2i(x, y)
			if not d.mines.has(p):
				d.revealed[p] = null
	var r := EditorVerify.verify_islands(d)
	assert_eq(str(r["state"]), EditorVerify.STATE_NO_GUESS, "全岛可解 ⇒ 整体无需猜测：%s" % str(r["reason"]))
	var islands: Array = (r["stats"] as Dictionary)["islands"]
	assert_eq(islands.size(), 2)
	for it in islands:
		assert_eq(str(it["state"]), EditorVerify.STATE_NO_GUESS, "每个岛都应可解：%s" % str(it))
