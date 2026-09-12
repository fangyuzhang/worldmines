extends GutTest

## probe40 玩法层三项测试（生成主线之外的运行时行为）：
## ① 加载后 0 值格连锁完整性（「孤立空白格」类 bug 的反面不变量——自动扩散变体的
##    0 值格安全邻格必须全部已翻开）+ 玩家首点 HIDDEN 安全格行为；
## ② HintSolver 对变体关卡给提示（不崩溃、开局必有必然结论）；
## ③ 存档 → 恢复 round-trip（对用户生成关卡，不只 res://levels）。

const PROBE_DIR := "user://probe40"

var _saved_state: int
var _saved_board: Board
var _saved_path: String


func before_each() -> void:
	_saved_state = GameSession.state
	_saved_board = GameSession.board
	_saved_path = GameSession.level_path
	SaveCoordinator.clear()
	GameSession.level_path = ""


func after_each() -> void:
	SaveCoordinator.clear()
	GameSession.state = _saved_state
	GameSession.board = _saved_board
	GameSession.level_path = _saved_path


func _list_json(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if dir.current_is_dir():
			out.append_array(_list_json(dir_path.path_join(n)))
		elif n.ends_with(".json") and not n.begins_with("all_report"):
			out.append(dir_path.path_join(n))
		n = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return data if data is Dictionary else {}


## 按线索规则分组抽样：每组最多 2 关，保证变体覆盖且总量可控。
func _sample_levels() -> Array:
	var files := _list_json(PROBE_DIR)
	if files.is_empty():
		return []
	var by_rule := {}
	for p in files:
		var level := _load_json(p)
		if level.is_empty():
			continue
		var rid := str(level.get("clue_rule", "?"))
		if not by_rule.has(rid):
			by_rule[rid] = []
		if (by_rule[rid] as Array).size() < 2:
			by_rule[rid].append(p)
	var out: Array = []
	for rid in by_rule:
		out.append_array(by_rule[rid])
	return out


## ① 加载后 0 值格连锁完整性 + 首点行为
func test_probe40_zero_flood_and_first_click() -> void:
	var levels := _sample_levels()
	if levels.is_empty():
		pending("probe40 目录不存在或为空")
		return
	var fails: Array[String] = []
	var checked := 0
	var first_clicks := 0
	for path in levels:
		var b: Board = LevelLoader.load_level(path)
		if b == null:
			fails.append("%s (加载失败)" % path.get_file())
			continue
		# 不变量：每个 0 值已翻开格的「安全邻格」（变体自举扩散集）必须全部已翻开。
		# 遗留 HIDDEN = 玩家看到 0 却能点到未知格 = 「孤立空白格」类 bug。
		for p in b.grid.all_positions():
			var c: Cell = b.grid.get_cell(p)
			if c == null or c.state != Cell.State.REVEALED or not c.is_zero_clue():
				continue
			for nb in b._flood_neighbors(p):
				var nc: Cell = b.grid.get_cell(nb)
				if nc == null or nc.is_mine:
					continue
				if nc.state != Cell.State.REVEALED:
					fails.append("%s: 0 值格 %s 的安全邻格 %s 未翻开" % [
						path.get_file(), p, nb])
					break
		# 首点：reveal 一个 HIDDEN 非雷格 → 必 REVEALED 且值与重算一致
		var rule: Object = RuleRegistry.default().resolve(
			StringName(str(_load_json(path).get("clue_rule", "classic"))))
		var mine_set := {}
		var level: Dictionary = _load_json(path)
		for m in level["mines"]:
			mine_set[Vector2i(int(m["c"]), int(m["r"]))] = true
		var size := Vector2i(int(level["size"]["cols"]), int(level["size"]["rows"]))
		for p in b.grid.all_positions():
			var c: Cell = b.grid.get_cell(p)
			if c == null or c.state != Cell.State.HIDDEN or mine_set.has(p):
				continue
			var expected: Variant = rule.compute_clue(mine_set, p, size)
			b.reveal(p)
			var after: Cell = b.grid.get_cell(p)
			if after.state != Cell.State.REVEALED:
				fails.append("%s: 首点 %s 未翻开" % [path.get_file(), p])
			elif not _veq(after.value, expected):
				fails.append("%s: 首点 %s 值 %s ≠ 期望 %s" % [path.get_file(), p, after.value, expected])
			first_clicks += 1
			break
		checked += 1
	assert_eq(fails.size(), 0, "连锁/首点失败（前 6）: " + "; ".join(fails.slice(0, 6)))
	print("连锁+首点: %d 关、首点 %d 次全过" % [checked, first_clicks])


func _veq(a: Variant, b: Variant) -> bool:
	if a is Array and b is Array:
		if (a as Array).size() != (b as Array).size():
			return false
		for i in (a as Array).size():
			if not _veq(a[i], b[i]):
				return false
		return true
	return a == b


## ② HintSolver 对变体关卡给提示
func test_probe40_hint_solver() -> void:
	var levels := _sample_levels()
	if levels.is_empty():
		pending("probe40 目录不存在或为空")
		return
	var fails: Array[String] = []
	var checked := 0
	for path in levels:
		var b: Board = LevelLoader.load_level(path)
		if b == null:
			continue
		var hs := HintSolver.new()
		var steps: Array = hs.hint(b)
		if steps.is_empty():
			fails.append("%s (开局无提示——序贯可解关应有必然结论)" % path.get_file())
			continue
		for s in steps:
			if not b.grid.in_board(s.pos):
				fails.append("%s (提示格 %s 越界)" % [path.get_file(), s.pos])
				break
		checked += 1
	assert_eq(fails.size(), 0, "HintSolver 失败（前 6）: " + "; ".join(fails.slice(0, 6)))
	print("HintSolver: %d 关全过" % checked)


## ③ 存档 → 恢复 round-trip（用户生成关卡）
func test_probe40_save_restore() -> void:
	var levels := _sample_levels()
	if levels.is_empty():
		pending("probe40 目录不存在或为空")
		return
	var fails: Array[String] = []
	var checked := 0
	for path in levels.slice(0, 8):
		var level: Dictionary = _load_json(path)
		var b: Board = LevelLoader.load_level(path)
		if b == null:
			continue
		var mine_set := {}
		for m in level["mines"]:
			mine_set[Vector2i(int(m["c"]), int(m["r"]))] = true
		# 玩家走 2 步（HIDDEN 安全格）
		var clicked: Array = []
		for p in b.grid.all_positions():
			var c: Cell = b.grid.get_cell(p)
			if c != null and c.state == Cell.State.HIDDEN and not mine_set.has(p):
				b.reveal(p)
				clicked.append(p)
			if clicked.size() >= 2:
				break
		SaveCoordinator.save(b, 42.0, path)
		GameSession.level_path = path
		assert_true(GameSession.restore_from_save(), "%s 恢复应成功" % path.get_file())
		var rb: Board = GameSession.board
		if rb == null:
			fails.append("%s (恢复后 board 为空)" % path.get_file())
			continue
		# 雷位一致 + 玩家点过的格必须仍是翻开态
		var fresh_mines := {}
		for m in rb.get_mine_positions():
			fresh_mines[m] = true
		if fresh_mines != mine_set:
			fails.append("%s (恢复后雷位不符)" % path.get_file())
			continue
		for p in clicked:
			var c: Cell = rb.grid.get_cell(p)
			if c == null or c.state != Cell.State.REVEALED:
				fails.append("%s (恢复后玩家步 %s 丢失)" % [path.get_file(), p])
				break
		checked += 1
	assert_eq(fails.size(), 0, "存档恢复失败（前 6）: " + "; ".join(fails.slice(0, 6)))
	print("存档恢复: %d 关全过" % checked)
