# gen_single_topup.gd —— P2 B/D 类补齐：单变体关卡统一补到 10 关（plan1.8 §3.2）
#
# 运行： godot --headless --path <proj> -s res://tools/gen_single_topup.gd [-- <code> ...]
# 产出： res://levels/<code>_NN.json（从现有最大编号 +1 续编，直至 10 关/变体）
#
# 目标：B 类「单变体基础」要求 8 线索型 × 10 关、D 类「布局篇」要求 7 布局 × 10 关。
# 慢速变体（clock/hv/fr/loopruns）已由 gen_single_mass.gd 补至 10 关；本脚本补齐其余变体。
extends SceneTree

const TARGETS := ["mx", "rl", "pf", "qd", "dt", "ep", "4c", "4n", "sc", "distsum"]
const TARGET_COUNT := 10
const SIZE := Vector2i(5, 5)
const MINES_CYCLE := [4, 5, 6, 7]
const SEED_BUDGET := 60

var _gen := PuzzleGenerator.new()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var targets: Array = args if args.size() > 0 else TARGETS
	var total := 0
	for code in targets:
		var existing := _existing_indices(code)
		var produced := 0
		var next_idx := 1
		if not existing.is_empty():
			next_idx = existing.max() + 1
		while existing.size() < TARGET_COUNT:
			var mines: int = MINES_CYCLE[existing.size() % MINES_CYCLE.size()]
			var got := false
			for t in SEED_BUDGET:
				var level := _gen.generate_constructive(code, SIZE, mines, t + 1)
				if level.is_empty():
					continue
				var f := FileAccess.open("res://levels/%s_%02d.json" % [code, next_idx], FileAccess.WRITE)
				if f != null:
					f.store_string(JSON.stringify(level, "  "))
					f.close()
					got = true
					break
			if got:
				existing.append(next_idx)
				next_idx += 1
				produced += 1
				total += 1
			else:
				print("  [%s] idx %d 失败 (M=%d)" % [code, next_idx, mines])
				break
		print("[%s] 补 %d 关 → 共 %d 关" % [code, produced, existing.size()])
	print("[gen] 总计补 %d 关" % total)
	quit(0)


func _existing_indices(code: String) -> Array:
	var dir := DirAccess.open("res://levels")
	var out: Array = []
	if dir == null:
		return out
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.begins_with(code + "_") and fname.ends_with(".json"):
			var stem := fname.substr(0, fname.length() - 5)
			var idx_str := stem.substr(code.length() + 1)
			if idx_str.is_valid_int():
				out.append(idx_str.to_int())
		fname = dir.get_next()
	dir.list_dir_end()
	return out
