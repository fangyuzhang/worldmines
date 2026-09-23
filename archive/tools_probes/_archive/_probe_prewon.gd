extends SceneTree

# 临时探针：加载「revealed = 全部非雷格」的关卡后，引擎状态到底是 WON 还是 PLAYING？
# 目的：区分两种可能——①引擎判 WON（那问题在 UI/会话接线）；②引擎仍 PLAYING（那问题在判胜条件）。
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var path := "res://levels_lib/o1/5/intro.json"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		print("[prewon] 打不开 %s" % path)
		CliShutdown.request_exit(1)
		return
	var doc: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (doc is Dictionary) or not (doc as Dictionary).has("levels"):
		print("[prewon] 结构异常")
		CliShutdown.request_exit(1)
		return
	var lv: Dictionary = (doc as Dictionary)["levels"][0]
	print("[prewon] 关卡: revealed=%d mines=%d total_mines=%s peak=%s" % [
		(lv.get("revealed", []) as Array).size(), (lv.get("mines", []) as Array).size(),
		str(lv.get("total_mines", -1)), str((lv.get("difficulty_profile", {}) as Dictionary).get("max_complexity", -1))])
	var b := Board.new()
	b.load_level(lv)
	var positions: Array = b.grid.all_positions()
	var hidden := 0
	var revealed := 0
	var flagged := 0
	for p in positions:
		var c: Cell = b.grid.get_cell(p)
		if c == null:
			continue
		match c.state:
			Cell.State.HIDDEN, Cell.State.QUESTION:
				hidden += 1
			Cell.State.REVEALED:
				revealed += 1
			Cell.State.FLAGGED:
				flagged += 1
	print("[prewon] 引擎状态: %s（0=PLAYING 1=WON 2=LOST）" % str(b.state))
	print("[prewon] 计数: 总格=%d 已开=%d 隐藏=%d 插旗=%d 总雷=%d" % [
		positions.size(), revealed, hidden, flagged, b.total_mines])
	print("[prewon] 判胜三分量: flagged_mines=%d / unknown_cells=%d / remaining_mines=%d → is_won=%s" % [
		flagged, hidden, b.total_mines - flagged, str(b.win_condition.is_won(b))])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
