# 诊断：o5x 门禁 FAIL 盘的真实状态（踩雷 / 卡住 / 正常）
# 用法：godot --headless --path . -s res://tools/_probe_o5x_fail.gd -- <level.json> [<level2.json> ...]
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var mods_dir := DirAccess.open("res://demo/mods")
	if mods_dir != null:
		for sub in mods_dir.get_directories():
			var entry := "res://demo/mods/%s/entry.gd" % sub
			if ResourceLoader.exists(entry):
				var sc: Variant = load(entry)
				if sc != null:
					sc.new().call("on_load")
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = ["res://_staged_levels/harvest_0915b/batch_o5x/x_o5x/9x9/intro_13.json"]
	for p in args:
		_probe(str(p))
	CliShutdown.request_exit(0)


func _probe(path: String) -> void:
	print("===== %s =====" % path)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		print("  打开失败")
		return
	var level: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var mine_set := {}
	for m in level.get("mines", []):
		mine_set[Vector2i(int(m["c"]), int(m["r"]))] = true
	var revealed_cnt := (level.get("revealed", []) as Array).size()
	print("  盘面: mines=%d revealed=%d" % [mine_set.size(), revealed_cnt])
	var log: Dictionary = ProofLog.build(level)
	print("  ProofLog: solved=%s rounds=%s reason=[%s]" % [log.get("solved"), log.get("rounds"), log.get("reason")])
	# 复现门禁流程逐轮跑，定位踩雷/卡住
	var b := Board.new()
	b.load_level(level)
	var solver := HintSolver.new()
	var rounds := 0
	var total := 0
	var last_step := {}
	while rounds < 500 and b.state == Board.GameState.PLAYING:
		var steps: Array = solver.hint(b)
		if steps.is_empty():
			print("  卡住 @round %d（无结论）" % rounds)
			break
		var applied := 0
		for st in steps:
			var step := st as ReasoningStep
			var cell: Cell = b.grid.get_cell(step.pos)
			if cell == null or cell.state != Cell.State.HIDDEN:
				continue
			last_step = {"pos": step.pos, "state": step.state}
			if step.state == "safe":
				b.reveal(step.pos)
			elif step.state == "mine":
				b.mark_proven_mine(step.pos)
				b.toggle_flag(step.pos)
			applied += 1
			total += 1
			if b.state != Board.GameState.PLAYING:
				break
		rounds += 1
		if applied == 0:
			print("  本轮无应用 @round %d" % rounds)
			break
	print("  最终: state=%s rounds=%d 应用步=%d" % [b.state, rounds, total])
	if b.state == Board.GameState.LOST and not last_step.is_empty():
		var pos: Vector2i = last_step["pos"]
		print("  最后一手: pos=(%d,%d) 声称=%s" % [pos.x, pos.y, last_step["state"]])
		print("  真雷判定(c,r)=(%s) / (r,c)=(%s)" % [
			mine_set.has(Vector2i(pos.x, pos.y)), mine_set.has(Vector2i(pos.y, pos.x))])
