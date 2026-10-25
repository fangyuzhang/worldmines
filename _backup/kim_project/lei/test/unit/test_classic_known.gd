# test_classic_known.gd —— 已知答案校验（文档 §4.4 / §5.1）
# 铁律：期望值由人工预先算死（写在关卡 JSON 的 known_answers），
# 禁止测试代码现场计算期望值，防止与实现共享同一错误。
extends GutTest

const LEVEL_IDS := ["classic_01", "classic_02", "classic_03", "classic_04", "classic_05", "classic_06", "classic_07", "classic_08", "classic_09", "classic_10"]


func _load_level(id: String) -> Dictionary:
	var f := FileAccess.open("res://levels/%s.json" % id, FileAccess.READ)
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return data


## 校验：引擎重算的线索值 == 人工已知答案（逐格、逐关）。
func test_known_answers_match_engine() -> void:
	for id in LEVEL_IDS:
		var data := _load_level(id)
		var board := Board.new()
		board.load_level(data)
		var known: Dictionary = data["known_answers"]
		var mismatches := 0
		for key in known:
			var parts: PackedStringArray = String(key).split(",")
			var r := int(parts[0])
			var c := int(parts[1])
			var cell := board.grid.get_cell(Vector2i(c, r))
			if cell.value != known[key]:
				mismatches += 1
				gut.p("  不符 %s (%d,%d): 引擎=%d 已知=%d" % [id, r, c, cell.value, known[key]])
		assert_eq(mismatches, 0, "%s 已知答案应与引擎重算一致" % id)


## 校验：每关雷数一致、初始翻开格均非雷。
func test_level_structure() -> void:
	for id in LEVEL_IDS:
		var data := _load_level(id)
		var board := Board.new()
		board.load_level(data)
		assert_eq(board.get_mine_positions().size(), board.total_mines, "%s 雷数一致" % id)
		# 初始翻开格（revealed）均非雷
		var revealed_on_mine := 0
		for x in data["revealed"]:
			if board.is_mine(Vector2i(x["c"], x["r"])):
				revealed_on_mine += 1
		assert_eq(revealed_on_mine, 0, "%s 初始翻开格均非雷" % id)
