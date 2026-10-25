# gen_mixed_mass.gd —— P2 C 类量产：7 布局 × 6 线索 × 15 关（plan1.8 §3.2）
#
# 运行（全部）： godot --headless --path <proj> -s res://tools/gen_mixed_mass.gd
# 运行（分批）： godot --headless --path <proj> -s res://tools/gen_mixed_mass.gd -- mx rl
# 产出： res://levels/<layout>_<clue>_NN.json
extends SceneTree

const LAYOUTS := ["mx", "rl", "pf", "qd", "dt", "ep", "4c"]
const CLUES := ["4n", "sc", "distsum", "clock", "hv", "loopruns"]
const PER_COMBO := 15
const SEED_BUDGET := 60
const SIZE := Vector2i(5, 5)
const MINES := 5

var _gen := PuzzleGenerator.new()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var layouts: Array = args if args.size() > 0 else LAYOUTS
	_cleanup_legacy()
	var total := 0
	for layout in layouts:
		for clue in CLUES:
			var produced := 0
			for t in SEED_BUDGET:
				if produced >= PER_COMBO:
					break
				var level := _gen.generate_mixed(layout, clue, SIZE, MINES, t + 1)
				if level.is_empty():
					continue
				produced += 1
				total += 1
				var f := FileAccess.open("res://levels/%s_%s_%02d.json" % [layout, clue, produced], FileAccess.WRITE)
				if f != null:
					f.store_string(JSON.stringify(level, "  "))
					f.close()
			print("  [%s+%s] %d 关" % [layout, clue, produced])
	print("[gen] 总计 %d 关" % total)
	quit(0 if total > 0 else 1)


## 清理旧版无序号混合关卡（<layout>_<clue>.json），统一为量产命名 <layout>_<clue>_NN.json。
func _cleanup_legacy() -> void:
	var dir := DirAccess.open("res://levels")
	if dir == null:
		return
	var removed := 0
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			var stem := fname.substr(0, fname.length() - 5)
			var parts := stem.split("_")
			if parts.size() == 2 and LAYOUTS.has(parts[0]) and CLUES.has(parts[1]):
				dir.remove(fname)
				removed += 1
		fname = dir.get_next()
	dir.list_dir_end()
	print("[gen] 清理旧版混合关卡 %d 个" % removed)
