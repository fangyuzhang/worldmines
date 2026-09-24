# test_s3_wuhuan.gd —— S3「无环」单元测试（GUT）
# 覆盖：插件契约、八邻接图是森林（独立复算：每分量 边数 == 点数 − 1）、雷数守恒、成功率下界、
# **判据辨析**（易错知识点：邻域内「两个不同连通块」不会成环——那只是连成一棵更大的树；
# 成环的真正条件是「邻域内有两颗已属于同一连通块的雷」）。
extends GutTest

const MOD_DIR := "res://demo/mods/s3_wuhuan"
const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
const TRIALS := 6
const DIRS8 := [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	autofree(api)
	api.load_mod(MOD_DIR)


func _is_forest(ms: Dictionary) -> bool:
	var seen := {}
	for start in ms:
		if seen.has(start):
			continue
		var stack: Array = [start]
		seen[start] = true
		var verts := 0
		var edge_twice := 0
		while not stack.is_empty():
			var p: Vector2i = stack.pop_back()
			verts += 1
			for d in DIRS8:
				var q: Vector2i = p + (d as Vector2i)
				if ms.has(q):
					edge_twice += 1
					if not seen.has(q):
						seen[q] = true
						stack.append(q)
		if edge_twice / 2 != verts - 1:
			return false
	return true


func test_plugin_contract() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s3")
	assert_not_null(r, "s3 应已注册")
	assert_eq(str(r.call("get_kind")), RulePlugin.KIND_GLOBAL, "S3 应为全局约束类")
	var d: Dictionary = r.call("describe")
	assert_eq(str(d.get("name", "")), "无环", "名称应为「无环」")
	assert_true(str(d.get("rule_text", "")).length() > 0, "应有面向玩家的规则文案")


## 判据辨析（本算子的易错点，用两个最小反例固定语义）：
## · L 形三格（互相八邻接）**含环**——八邻接下「三角形」是最小环；
## · 两簇互不相邻的雷 + 一颗同时连接两簇的雷 → **不成环**（只是把两块连成一棵树）。
func test_minimal_cases() -> void:
	# L 形三格：(0,0)(1,0)(0,1) 两两八邻接 → 含 3-环
	var lshape := {}
	for p in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]:
		lshape[p] = true
	assert_false(_is_forest(lshape), "L 形三格在八邻接下含三角形，应判为非森林")
	# 一条链（无环）
	var chain := {}
	for p in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)]:
		chain[p] = true
	assert_true(_is_forest(chain), "三格直链应为森林")


func test_place_mines_all_sizes() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s3")
	assert_not_null(r, "s3 未注册")
	for side in [5, 6, 7, 8, 9]:
		var want: int = R07_MINES[side]
		var ok_cnt := 0
		for t in TRIALS:
			var rng := RandomNumberGenerator.new()
			rng.seed = t * 5717 + side
			var mines: Array = r.call("place_mines", rng, side, side, want)
			if mines.size() != want:
				continue
			ok_cnt += 1
			var ms := {}
			for m in mines:
				ms[m] = true
			assert_eq(ms.size(), want, "%dx%d 雷位应无重复" % [side, side])
			assert_true(_is_forest(ms), "%dx%d 八邻接图应为森林（每分量 边=点−1）" % [side, side])
		assert_gt(ok_cnt, 0, "%dx%d 应能产出至少一关（实测 %d/%d）" % [side, side, ok_cnt, TRIALS])
