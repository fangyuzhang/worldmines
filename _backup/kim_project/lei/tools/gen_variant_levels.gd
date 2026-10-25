# gen_variant_levels.gd —— P1 变体关卡批量生成（plan1.8 §3.2 / plan1.9 §6.1）
#
# 运行： godot --headless --path "E:\Porject\kim project\lei" -s res://tools/gen_variant_levels.gd
# 产出： res://levels/<code>_NN.json
#
# 尺寸覆盖：
#   5×5：全部 14 变体（M=4/5/6，另有遮蔽配置）
#   6×6 / 7×7：仅「快速变体」（全局约束型 + 计数型线索 4n/sc，内化剪枝可快速枚举）
#   慢速变体（clock/hv/distsum/loopruns/fr，非计数型线索无内化剪枝）只出 5×5。
# 逐种子打印避免 headless 长任务无输出。
extends SceneTree

const SEED_BUDGET := 30
const SEED_BASE := 1

# 6×6/7×7 可行的变体（内化剪枝）：全局约束型 + 计数型线索（4n/sc/distsum）
const FAST_67 := ["mx", "rl", "pf", "qd", "dt", "ep", "4c", "4n", "sc", "distsum"]
# 支持遮蔽的变体（实测遮蔽后仍可解；sc 弱线索遮蔽后不可解，不含）
const MASKABLE := ["mx", "rl", "pf", "qd", "dt", "ep", "4c", "4n"]

# 配置：scope = all（全部变体）/ fast（仅 FAST_67）/ maskable（仅 MASKABLE）
const CONFIGS := [
	{"size": Vector2i(5, 5), "mines": 4, "mask": 0, "scope": "all"},
	{"size": Vector2i(5, 5), "mines": 5, "mask": 0, "scope": "all"},
	{"size": Vector2i(5, 5), "mines": 6, "mask": 0, "scope": "all"},
	{"size": Vector2i(5, 5), "mines": 5, "mask": 1, "scope": "maskable"},
	{"size": Vector2i(5, 5), "mines": 5, "mask": 2, "scope": "maskable"},
	{"size": Vector2i(6, 6), "mines": 6, "mask": 0, "scope": "fast"},
	{"size": Vector2i(6, 6), "mines": 7, "mask": 0, "scope": "fast"},
	{"size": Vector2i(7, 7), "mines": 7, "mask": 0, "scope": "fast"},
	{"size": Vector2i(7, 7), "mines": 8, "mask": 0, "scope": "fast"},
]

# 混合变体：7 布局（全局约束）× 6 线索（plan1.8 §3.2 C 类「一布局一线索」42 组合）
# 注：clock/hv/loopruns 混合剪枝慢（query_variant），5×5 下仍可产；fr 语义特殊暂不混合。
const MIXED_LAYOUTS := ["mx", "rl", "pf", "qd", "dt", "ep", "4c"]
const MIXED_CLUES := ["4n", "sc", "distsum", "clock", "hv", "loopruns"]

var _gen := PuzzleGenerator.new()


func _initialize() -> void:
	var report: Array = []
	var total := 0
	for code in VariantRegistry.all_codes():
		if code == "classic":
			continue
		print("[gen] === %s ===" % code)
		var produced := 0
		for ci in CONFIGS.size():
			var cfg: Dictionary = CONFIGS[ci]
			if not _in_scope(code, str(cfg["scope"])):
				continue
			if _gen_one(code, cfg, ci + 1):
				produced += 1
				total += 1
		report.append("%s=%d" % [code, produced])
		print("[gen] %s 完成 %d 关" % [code, produced])

	# 混合变体（一布局一线索，5×5 M=5 各 1 关）
	var mixed_total := 0
	for layout in MIXED_LAYOUTS:
		for clue in MIXED_CLUES:
			var level := _gen.generate_mixed(layout, clue, Vector2i(5, 5), 5, SEED_BASE)
			if level.is_empty():
				print("  [%s+%s] 失败" % [layout, clue])
				continue
			if _write("res://levels/%s_%s.json" % [layout, clue], level):
				mixed_total += 1
				total += 1
				print("  [%s+%s] ok" % [layout, clue])
	print("[gen] 混合变体 %d 关" % mixed_total)

	print("[gen] 总计 %d 关" % total)
	print("[gen] " + ", ".join(report))
	quit(0 if total > 0 else 1)


func _in_scope(code: String, scope: String) -> bool:
	match scope:
		"fast":
			return code in FAST_67
		"maskable":
			return code in MASKABLE
		_:
			return true


func _gen_one(code: String, cfg: Dictionary, idx: int) -> bool:
	var size: Vector2i = cfg["size"]
	var mines: int = cfg["mines"]
	var mask: int = cfg["mask"]
	for t in SEED_BUDGET:
		var level := _gen.generate_constructive(code, size, mines, SEED_BASE + t, mask)
		if level.is_empty():
			continue
		var path := "res://levels/%s_%02d.json" % [code, idx]
		return _write(path, level)
	print("  [%s] 配置 %d 失败（%d 次尝试）" % [code, idx, SEED_BUDGET])
	return false


func _write(path: String, level: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("无法写入 " + path)
		return false
	f.store_string(JSON.stringify(level, "  "))
	f.close()
	return true
