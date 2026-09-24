# test_s4_yangcong.gd —— S4「洋葱」单元测试（GUT）
# 覆盖：插件契约、**层划分与 GDD §4.5 表逐一对照**（16/8/1｜20/12/4｜24/16/8/1｜28/20/12/4｜32/24/16/8/1）、
# 构造式布雷（雷数守恒 + 层密度由外向内单调不减 + 成功率下界）。
extends GutTest

const MOD_DIR := "res://demo/mods/s4_yangcong"
const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
const TRIALS := 30

## GDD §4.5 原文表：各尺寸环层格数（t=0 为最外层）。
const GDD_LAYER_SIZES := {
	5: [16, 8, 1],
	6: [20, 12, 4],
	7: [24, 16, 8, 1],
	8: [28, 20, 12, 4],
	9: [32, 24, 16, 8, 1],
}


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	autofree(api)
	api.load_mod(MOD_DIR)


func _layers(rows: int, cols: int) -> Array:
	var nc := mini(rows, cols)
	var t_max := (nc - 1) / 2
	var out: Array = []
	for t in t_max + 1:
		out.append([])
	for r in rows:
		for c in cols:
			var d := mini(mini(r, rows - 1 - r), mini(c, cols - 1 - c))
			(out[d] as Array).append(Vector2i(c, r))
	return out


func test_plugin_contract() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s4")
	assert_not_null(r, "s4 应已注册")
	assert_eq(str(r.call("get_kind")), RulePlugin.KIND_GLOBAL, "S4 应为全局约束类")
	var d: Dictionary = r.call("describe")
	assert_eq(str(d.get("name", "")), "洋葱", "名称应为「洋葱」")
	assert_true(str(d.get("rule_text", "")).length() > 0, "应有面向玩家的规则文案")


## 层划分必须与 GDD §4.5 表逐一吻合（这是本算子的定义基础）——直接验证**插件实现**。
func test_layer_partition_matches_gdd() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s4")
	assert_not_null(r, "s4 未注册")
	for side in [5, 6, 7, 8, 9]:
		var layers: Array = r.call("layers_of", side, side)
		var sizes: Array = []
		var total := 0
		for layer in layers:
			sizes.append((layer as Array).size())
			total += (layer as Array).size()
		assert_eq(sizes, GDD_LAYER_SIZES[side], "%dx%d 层格数应与 GDD 表一致" % [side, side])
		assert_eq(total, side * side, "%dx%d 各层格数之和应为全盘格数" % [side, side])
		# 层必须只有唯一一种距边界距离（定义正确性）
		for t in layers.size():
			for p in (layers[t] as Array):
				var d := mini(mini((p as Vector2i).y, side - 1 - (p as Vector2i).y),
					mini((p as Vector2i).x, side - 1 - (p as Vector2i).x))
				assert_eq(d, t, "%dx%d 格 %s 应属第 %d 层" % [side, side, str(p), t])


## 构造式布雷：雷数守恒 + 层密度由外向内单调不减（独立复算）。
func test_place_mines_and_monotonic_density() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s4")
	assert_not_null(r, "s4 未注册")
	for side in [5, 6, 7, 8, 9]:
		var want: int = R07_MINES[side]
		var layers := _layers(side, side)
		var ok_cnt := 0
		for t in TRIALS:
			var rng := RandomNumberGenerator.new()
			rng.seed = t * 4177 + side
			var mines: Array = r.call("place_mines", rng, side, side, want)
			if mines.size() != want:
				continue
			ok_cnt += 1
			var ms := {}
			for m in mines:
				ms[m] = true
			assert_eq(ms.size(), want, "%dx%d 雷位应无重复" % [side, side])
			for ti in layers.size():
				var layer: Array = layers[ti]
				var mine_n := 0
				for p in layer:
					if ms.has(p):
						mine_n += 1
				if ti > 0:
					var prev: Array = layers[ti - 1]
					var prev_m := 0
					for p in prev:
						if ms.has(p):
							prev_m += 1
					# m_{ti-1}/|L_{ti-1}| ≤ m_{ti}/|L_{ti}|
					assert_true(prev_m * layer.size() <= mine_n * prev.size(),
						"%dx%d 层 %d→%d 密度应单调不减（%d/%d → %d/%d）" % [
							side, side, ti - 1, ti, prev_m, prev.size(), mine_n, layer.size()])
		assert_gt(float(ok_cnt) / float(TRIALS), 0.9,
			"%dx%d 构造式布雷成功率应 > 90%%（实测 %d/%d）" % [side, side, ok_cnt, TRIALS])
