extends SceneTree

# O5x 验收 FAIL 单关诊断：对照「仅 o5x 注册」vs「全 mods 注册」两个环境。

const LEVEL := "res://_staged_levels/harvest_0915/batch_o5x/x_o5x/8x8/easy_18.json"


func _read_level() -> Dictionary:
	var f := FileAccess.open(LEVEL, FileAccess.READ)
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return d


func _try(label: String) -> void:
	var level := _read_level()
	print("  %s | clue_rule=%s mines=%d revealed=%d" % [label,
		str(level.get("clue_rule", "?")), (level.get("mines", []) as Array).size(),
		(level.get("revealed", []) as Array).size()])
	var log: Dictionary = ProofLog.build(level)
	print("  %s => solved=%s rounds=%s reason=%s" % [label,
		str(log.get("solved")), str(log.get("rounds")), str(log.get("reason"))])


func _initialize() -> void:
	# 场景 A：仅加载 o5x
	var sc: Variant = load("res://demo/mods/o5_xiemai/entry.gd")
	sc.new().call("on_load")
	print("A registered=", RuleRegistry.default().resolve(&"o5x") != null)
	_try("A 仅o5x")
	# 场景 B：加载全部 mods（verify_batch 同款遍历）
	var mods_dir := DirAccess.open("res://demo/mods")
	for sub in mods_dir.get_directories():
		var entry := "res://demo/mods/%s/entry.gd" % sub
		if ResourceLoader.exists(entry):
			var s2: Variant = load(entry)
			if s2 != null:
				s2.new().call("on_load")
	_try("B 全mods")
	quit(0)
