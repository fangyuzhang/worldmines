# gen_dual_mass.gd —— P2 F 类双布局量产（plan1.8 §3.2）
#
# 运行（全部）： godot --headless --path <proj> -s res://tools/gen_dual_mass.gd
# 运行（单对）： godot --headless --path <proj> -s res://tools/gen_dual_mass.gd -- mx rl
# 产出： res://levels/<a>_<b>_NN.json
#
# 两个全局约束叠加（线索为经典），过滤 forbid 组合（兼容矩阵附 B.1）。
# 排除 DT（骨牌划分在双约束下需额外协调，暂不支持双布局）。
extends SceneTree

const LAYOUTS := ["mx", "rl", "pf", "qd", "ep", "4c"]
const PER_PAIR := 3
const SIZE := Vector2i(5, 5)
const MINES := 5
const SEED_BUDGET := 40

var _gen := PuzzleGenerator.new()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var pairs: Array = []
	if args.size() == 2:
		pairs.append([str(args[0]), str(args[1])])
	else:
		for i in LAYOUTS.size():
			for j in range(i + 1, LAYOUTS.size()):
				pairs.append([LAYOUTS[i], LAYOUTS[j]])

	var total := 0
	var ok_pairs := 0
	for pair in pairs:
		var a: String = pair[0]
		var b: String = pair[1]
		if VariantRegistry.global_pair_compat(a, b) == "forbid":
			print("  [%s+%s] forbid 跳过" % [a, b])
			continue
		ok_pairs += 1
		var produced := 0
		for t in SEED_BUDGET:
			if produced >= PER_PAIR:
				break
			var level := _gen.generate_dual(a, b, SIZE, MINES, t + 1)
			if level.is_empty():
				continue
			var f := FileAccess.open("res://levels/%s_%s_%02d.json" % [a, b, produced + 1], FileAccess.WRITE)
			if f != null:
				f.store_string(JSON.stringify(level, "  "))
				f.close()
				produced += 1
				total += 1
		print("  [%s+%s] %d 关" % [a, b, produced])
	print("[gen] 兼容对 %d，总计 %d 关" % [ok_pairs, total])
	quit(0 if total > 0 else 1)
