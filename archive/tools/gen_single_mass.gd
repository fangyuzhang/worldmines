# gen_single_mass.gd —— P2 B 类扩容：单变体补关（plan1.8 §3.2）
#
# 运行： godot --headless --path <proj> -s res://tools/gen_single_mass.gd
# 产出： res://levels/<code>_NN.json（从 START_IDX 起，补齐 10 关/变体）
#
# 目标：B 类「单变体基础」要求 10 关/线索型。clock/hv/fr/loopruns 因非计数型线索
# 剪枝慢，仅出 5×5（配置 1-3 = M4/5/6），此处用不同雷数/种子补齐 _04.._10。
extends SceneTree

# 目标变体（当前仅 3 关者）
const TARGETS := ["clock", "hv", "fr", "loopruns"]
const START_IDX := 4
const END_IDX := 10
const SIZE := Vector2i(5, 5)
# 与 START_IDX..END_IDX 一一对应的雷数轮转
const MINES_CYCLE := [6, 7, 4, 5, 6, 7, 5]
const SEED_BUDGET := 60

var _gen := PuzzleGenerator.new()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var targets: Array = args if args.size() > 0 else TARGETS
	var total := 0
	for code in targets:
		var produced := 0
		for idx in range(START_IDX, END_IDX + 1):
			var mines: int = MINES_CYCLE[(idx - START_IDX) % MINES_CYCLE.size()]
			var got := false
			for t in SEED_BUDGET:
				var level := _gen.generate_constructive(code, SIZE, mines, t + 1)
				if level.is_empty():
					continue
				var f := FileAccess.open("res://levels/%s_%02d.json" % [code, idx], FileAccess.WRITE)
				if f != null:
					f.store_string(JSON.stringify(level, "  "))
					f.close()
					got = true
					break
			if got:
				produced += 1
				total += 1
			else:
				print("  [%s] %02d 失败 (M=%d)" % [code, idx, mines])
		print("[%s] 补 %d 关" % [code, produced])
	print("[gen] 总计补 %d 关" % total)
	quit(0 if total > 0 else 1)
