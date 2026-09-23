extends SceneTree

## 交叉验证（2026-09-16）：导出「k 不公开盘」与「前置遮蔽盘」供独立门禁 verify_batch 复核。
## 目的：用与实现方（probe）不同的工具/口径（verify_batch → HintSolver/ProofLog）交叉印证。
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod("res://demo/mods/o4_bianjing")
	api.load_mod("res://demo/mods/o5_sanjiao")
	var out_dir := "res://_staged_levels/xcheck"
	DirAccess.make_dir_recursive_absolute(out_dir)
	var r4: Object = RuleRegistry.default().resolve(&"o4")
	r4.call("set_k_public", false)
	for i in 2:
		var lv: Dictionary = PuzzleGenerator.new().generate_with_rules(
			"o4", [], Vector2i(6, 6), 14, 200 + i, 0, 50, null, 400_000)
		if lv.is_empty():
			print("o4 不公开 seed=%d 生成失败" % (200 + i))
			continue
		lv["name"] = "xchk_o4_hidden_%d" % i
		_save(out_dir + "/xchk_o4_hidden_%d.json" % i, lv)
		print("o4 不公开 seed=%d 落盘（k_public=%s）" % [200 + i, str(lv.get("k_public", null))])
	r4.call("set_k_public", true)
	for i in 2:
		var lv2: Dictionary = PuzzleGenerator.new().generate_with_rules(
			"o5", [], Vector2i(6, 6), 14, 100 + i, 6, 50, null, 200_000, 0.0, 1, 0, true)
		if lv2.is_empty():
			print("o5 前置遮蔽 seed=%d 生成失败" % (100 + i))
			continue
		lv2["name"] = "xchk_o5_maskpre_%d" % i
		_save(out_dir + "/xchk_o5_maskpre_%d.json" % i, lv2)
		print("o5 前置遮蔽 seed=%d 落盘（线索 %d 条）" % [100 + i, (lv2.get("revealed", []) as Array).size()])
	CliShutdown.request_exit(0)


func _save(path: String, lv: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	# 不可写（res:// 只读 / 目录不存在）时 open 返回 null —— 原先直接 store_string 会崩
	# （架构审计 P1）。改为报错并跳过这一份，不中断整轮交叉验证。
	if f == null:
		push_error("[xcheck] 写不了: %s" % path)
		return
	f.store_string(JSON.stringify(lv))
	f.close()


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
