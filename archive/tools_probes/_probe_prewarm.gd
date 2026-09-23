extends SceneTree
# _probe_prewarm.gd —— 判断「选关页预热 board_view.tscn」是否真有收益。
#
# 背景：为治「首次进关卡的顿挫」在 level_select._ready 末尾加了预热（提前 load 场景）。
# 但预热只能覆盖 **load**（脚本编译 + 资源注册），覆盖不到 **instantiate / _ready**（节点树构建）。
# 若无头下 load 本就微不足道，那预热就是负收益（白白增加选关页负担），应当撤掉。
#
# 用法：godot --headless --path . -s tools/_probe_prewarm.gd
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	print("=== 预热收益测量 ===")

	var t0 := Time.get_ticks_usec()
	var packed: Variant = load("res://ui/board_view.tscn")
	var first_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("  1. 首次 load board_view.tscn: %8.2f ms （%s）" % [first_ms, "OK" if packed != null else "失败"])

	var t1 := Time.get_ticks_usec()
	for i in 5:
		load("res://ui/board_view.tscn")
	var cached_ms := float(Time.get_ticks_usec() - t1) / 1000.0 / 5.0
	print("  2. 再次 load（资源缓存命中）: %8.3f ms" % cached_ms)

	var t2 := Time.get_ticks_usec()
	var gd: Variant = load("res://ui/board_view.gd")
	var gd_ms := float(Time.get_ticks_usec() - t2) / 1000.0
	print("  3. load board_view.gd 脚本:  %8.2f ms （%s）" % [gd_ms, "OK" if gd != null else "失败"])

	if packed is PackedScene:
		var t3 := Time.get_ticks_usec()
		var inst: Node = (packed as PackedScene).instantiate()
		var inst_ms := float(Time.get_ticks_usec() - t3) / 1000.0
		# 不入树 → _ready 不跑，故这里只是「节点创建」的成本（_ready 里的构建不在此列）
		print("  4. instantiate（不含 _ready）: %8.2f ms" % inst_ms)
		if inst != null:
			inst.free()

	print("  结论判定：")
	if first_ms < 30.0:
		print("    load 本身仅 %.1f ms —— 预热收益极低，属负收益（白白增加选关页一次 load）。建议撤掉。" % first_ms)
	else:
		print("    load 首次 %.1f ms —— 预热确能把这部分前移，保留合理。" % first_ms)
	print("    注意：真正的顿挫若来自 instantiate/_ready 的节点构建，预热覆盖不到，需另想他法。")
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
