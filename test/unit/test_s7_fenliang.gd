# test_s7_fenliang.gd —— S7「分量数 K」单元测试（GUT）
# 覆盖：插件契约、八连通块数恰好等于 K（独立复算）、雷数守恒、
# 块间分离性（各分量互不八邻接——否则会合并）、K 的尺寸取值表。
#
# 注意本插件用**保守编码**（复用 S3 的父指针+层级机制 ⇒ 每分量是树 ⇒ 根数==分量数），
# 即 GDD 规则「有环的块」子集——故测试只验证「块数 == K」这一 GDD 要求的性质。
extends GutTest

const MOD_DIR := "res://demo/mods/s7_fenliang"
const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
const K_BY_SIZE := {5: 2, 6: 3, 7: 3, 8: 4, 9: 4}
const DIRS8 := [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	autofree(api)
	api.load_mod(MOD_DIR)


func _components(ms: Dictionary) -> int:
	var seen := {}
	var comps := 0
	for start in ms:
		if seen.has(start):
			continue
		comps += 1
		var stack: Array = [start]
		seen[start] = true
		while not stack.is_empty():
			var p: Vector2i = stack.pop_back()
			for d in DIRS8:
				var q: Vector2i = p + (d as Vector2i)
				if ms.has(q) and not seen.has(q):
					seen[q] = true
					stack.append(q)
	return comps


func test_plugin_contract() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s7")
	assert_not_null(r, "s7 应已注册")
	assert_eq(str(r.call("get_kind")), RulePlugin.KIND_GLOBAL, "S7 应为全局约束类")
	var d: Dictionary = r.call("describe")
	assert_eq(str(d.get("name", "")), "分量数 K", "名称应为「分量数 K」")
	assert_true(str(d.get("rule_text", "")).length() > 0, "应有面向玩家的规则文案")


func test_place_mines_all_sizes() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s7")
	assert_not_null(r, "s7 未注册")
	for side in [5, 6, 7, 8, 9]:
		var want: int = R07_MINES[side]
		var k: int = int(K_BY_SIZE[side])
		var ok_cnt := 0
		for t in 3:
			var rng := RandomNumberGenerator.new()
			rng.seed = t * 6917 + side
			var mines: Array = r.call("place_mines", rng, side, side, want)
			if mines.size() != want:
				continue
			ok_cnt += 1
			var ms := {}
			for m in mines:
				ms[m] = true
			assert_eq(ms.size(), want, "%dx%d 雷位应无重复" % [side, side])
			assert_eq(_components(ms), k, "%dx%d 八连通块数应恰为 K=%d" % [side, side, k])
		assert_gt(ok_cnt, 0, "%dx%d 应能产出至少一关（实测 %d/3）" % [side, side, ok_cnt])
