extends SceneTree

## 临时扫描脚本：找出所有关卡里「翻开但无数字显示」的格子（value=0 或非预期类型）。
func _init() -> void:
	var paths: Array = []
	var dir := DirAccess.open("res://levels")
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".json"):
			paths.append("res://levels/" + f)
		f = dir.get_next()
	dir.list_dir_end()

	var variant_names := ["CLASSIC", "N4", "CLOCK", "HV", "FR", "LOOP_RUNS", "DIST_SUM", "SAME_COLOR"]
	var blank_by_variant := {}
	var total := 0
	for path in paths:
		var board: Board = LevelLoader.load_level(path)
		if board == null:
			continue
		var size := board.grid.size()
		for r in size.y:
			for c in size.x:
				var cell := board.grid.get_cell(Vector2i(c, r))
				if cell.state != Cell.State.REVEALED or cell.is_mine:
					continue
				var v: Variant = cell.value
				var is_blank := false
				if v is int and v == 0:
					is_blank = true
				elif not (v is int or v is Array or v is String):
					is_blank = true
				if is_blank:
					var vn: String = variant_names[board.clue_variant] if board.clue_variant < variant_names.size() else str(board.clue_variant)
					if not blank_by_variant.has(vn):
						blank_by_variant[vn] = []
					blank_by_variant[vn].append(path.get_file() + "(" + str(c) + "," + str(r) + ")")
					total += 1
	for vn in blank_by_variant:
		print(vn, " (", blank_by_variant[vn].size(), "): ", str(blank_by_variant[vn]))
	print("总空白格数: ", total)
	quit()
