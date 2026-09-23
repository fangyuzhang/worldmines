extends SceneTree
# _probe_ls_switch.gd —— 临时性能探针（下划线开头，不入库）：
# 分帧模拟真实路径「主菜单（延迟一帧预热）→ 停留 → 切选关页」并计时。
# 用法：godot --headless --path . -s tools/_probe_ls_switch.gd
#
# 为什么在 _process 里分帧：-s 脚本编译期早于 autoload 装配，直接引用 autoload
# 标识符会编译失败（gen_variant_shape_levels.gd 同款注释）；且主菜单预热本身是
# 延迟一帧的（process_frame 信号），必须跨帧等到它执行完再测切换成本。

var _stage := 0
var _t_main := 0.0


func _process(_delta: float) -> bool:
	if _stage == 0:
		# 第一帧：加载主菜单（其 _ready 注册延迟一帧预热）
		_stage = 1
		var t0 := Time.get_ticks_usec()
		var mm: Node = load("res://ui/main_menu.tscn").instantiate()
		root.add_child(mm)
		_t_main = (Time.get_ticks_usec() - t0) / 1000.0
		return false
	if _stage == 1:
		# 第二帧：空转——本帧 process_frame 信号触发主菜单的预热回调
		_stage = 2
		return false
	# 第三帧：预热已完成，测「点开始游戏」的真实切换成本
	_stage = 3
	print("[perf] 主菜单实例化+_ready = %.1f ms（预热在其后的帧里跑）" % _t_main)

	var t2 := Time.get_ticks_usec()
	var ls_pack: PackedScene = load("res://ui/level_select.tscn")
	var t2b := Time.get_ticks_usec()
	var ls: Node = ls_pack.instantiate()
	var t2c := Time.get_ticks_usec()
	root.add_child(ls)
	var t3 := Time.get_ticks_usec()
	print("[perf]   └ 细分: load=%.1f instantiate=%.1f add_child(+_ready)=%.1f ms" % [
		(t2b - t2) / 1000.0, (t2c - t2b) / 1000.0, (t3 - t2c) / 1000.0])
	print("[perf] 选关页切换总计 = %.1f ms（对照：优化前 660ms）" % [(t3 - t2) / 1000.0])

	# 首切异形页（延迟填充的兜底路径）+ 再切回
	var t4 := Time.get_ticks_usec()
	ls._show_tab(ls.PAGE_SHAPE)
	var t5 := Time.get_ticks_usec()
	var t6 := Time.get_ticks_usec()
	ls._show_tab(ls.PAGE_SINGLE)
	var t7 := Time.get_ticks_usec()
	print("[perf] 首切异形页 = %.1f ms | 再切回单项页 = %.1f ms" % [
		(t5 - t4) / 1000.0, (t7 - t6) / 1000.0])
	return true
