# gen_clue_mass.gd —— P3 E 类线索混合量产（plan1.8 §3.2）
#
# 运行（全部）： godot --headless --path <proj> -s res://tools/gen_clue_mass.gd
# 运行（分批）： godot --headless --path <proj> -s res://tools/gen_clue_mass.gd -- 4n sc classic clock
# 产出： res://levels/<clue_a>_<clue_b>_NN.json
#
# 两个线索型叠加：同一格同时给出两个线索值（如 "4n+sc" = 四邻计数 + 同色计数）。
# 增量补齐：按现有最大编号续编，直至每组 8 关（可重复运行，不覆盖已有）。
# 7 个线索型两两 = 21 组 × 8 关 = 168 关。
# 排除 FR：首雷为向右射线且含 "inf" 哨兵，与另一线索叠加后唯一解命中率极低（实测 60 种子仅出 1 关）。
extends SceneTree

const CLUES := ["classic", "4n", "sc", "distsum", "clock", "hv", "loopruns"]
const PER_PAIR := 8
const SIZE := Vector2i(5, 5)
const MINES := 5
const SEED_BUDGET := 80

var _gen := PuzzleGenerator.new()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var pairs: Array = []
	if args.size() >= 2:
		var i := 0
		while i + 1 < args.size():
			pairs.append([str(args[i]), str(args[i + 1])])
			i += 2
	else:
		for i in CLUES.size():
			for j in range(i + 1, CLUES.size()):
				pairs.append([CLUES[i], CLUES[j]])

	var total := 0
	for pair in pairs:
		var a: String = pair[0]
		var b: String = pair[1]
		var existing := _existing_indices(a, b)
		var produced := existing.size()
		var next_idx := 1
		if not existing.is_empty():
			next_idx = existing.max() + 1
		while produced < PER_PAIR:
			var got := false
			for t in SEED_BUDGET:
				var level := _gen.generate_mixed_clue(a, b, SIZE, MINES, t + 1 + existing.size())
				if level.is_empty():
					continue
				var f := FileAccess.open("res://levels/%s_%s_%02d.json" % [a, b, next_idx], FileAccess.WRITE)
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
				print("  [%s+%s] idx %d 失败" % [a, b, next_idx])
				break
		print("  [%s+%s] %d 关" % [a, b, produced])
	print("[gen] 总计补 %d 关" % total)
	quit(0)


func _existing_indices(a: String, b: String) -> Array:
	var dir := DirAccess.open("res://levels")
	var out: Array = []
	if dir == null:
		return out
	var prefix := "%s_%s_" % [a, b]
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.begins_with(prefix) and fname.ends_with(".json"):
			var stem := fname.substr(0, fname.length() - 5)
			var idx_str := stem.substr(prefix.length())
			if idx_str.is_valid_int():
				out.append(idx_str.to_int())
		fname = dir.get_next()
	dir.list_dir_end()
	return out
