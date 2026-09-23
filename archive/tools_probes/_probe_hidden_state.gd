# 隐藏态落盘/恢复端到端验证（2026-09-16，对应 HANDOFF 已知坑 #18 的修复）
# 每规则（o5x/o4）：生成 → 字段断言 → round-trip → 三态推理对照（基线 / 旧盘对照 / 修复路径）
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
	_check("o5x", 14)
	_check("o4", 14)
	CliShutdown.request_exit(0)


func _check(clue_id: String, mines: int) -> void:
	var size := Vector2i(6, 6)
	print("===== %s %dx%d =====" % [clue_id, size.x, size.y])
	var gen := PuzzleGenerator.new()
	var level: Dictionary = gen.generate_with_rules(clue_id, [], size, mines, 7, 0, 20, null, 30000)
	if level.is_empty():
		print("  生成失败")
		return
	var hs: Dictionary = level.get("hidden_state", {})
	print("  落盘 hidden_state: has=%s keys=%s" % [level.has("hidden_state"), hs.keys()])
	print("  state 内容片段: %s" % str(hs.get(clue_id, {})).substr(0, 110))
	var rule: Object = RuleRegistry.default().resolve(StringName(clue_id))
	# round-trip：导出 → 清空 → 恢复 → 再导出应一致
	var e1: Dictionary = rule.call("export_hidden_state")
	rule.call("import_hidden_state", {})
	var e_empty: Dictionary = rule.call("export_hidden_state")
	rule.call("import_hidden_state", e1)
	var e2: Dictionary = rule.call("export_hidden_state")
	print("  round-trip: 清空后为空=%s / 恢复后一致=%s" % [e_empty.is_empty(), e1 == e2])
	# 基线：同进程状态正确 → 应可解
	print("  基线（生成态）: solved=%s（预期 true）" % ProofLog.build(level).get("solved"))
	# 旧盘对照：去掉字段 + 清空状态 → 应失败（复现修复前行为）
	var old_level: Dictionary = level.duplicate(true)
	old_level.erase("hidden_state")
	rule.call("import_hidden_state", {})
	print("  旧盘对照（无字段+无状态）: solved=%s（预期 false）" % ProofLog.build(old_level).get("solved"))
	# 修复路径：带字段载盘 → load_level 自动恢复 → 应可解
	print("  修复路径（字段恢复）: solved=%s（预期 true）" % ProofLog.build(level).get("solved"))


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
