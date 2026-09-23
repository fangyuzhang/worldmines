# probe_render_scale.gd —— 大棋盘关卡的渲染规模探针（2026-09-23 审计续）
#
# 目的：高分辨率异形关（17~21 格 bbox、60~296 格）此前只在 headless 用
# LevelLoader 载入验证过，**从未在真实棋盘视图里实例化**。它们的风险不是「载不进来」
# 而是「进来之后」：节点数膨胀、单格被压到 1~2 像素、内容盒算负等。
#
# headless 无 GPU，测不到帧率——但下列信号都能测且足够判断：
#   · 视图构建耗时（instantiate + add_child）
#   · 视图子树节点总数（每格若干个 Control，296 格就是 4 位数）
#   · 单格平均占位（可视区 ÷ bbox 行列）——低于 ~3px 就属于「看得见但点不中」
#
# 用法： godot --headless --path . -s res://tools/probe_render_scale.gd [-- 关卡路径...]
#       无参数时跑内置对照集（最大/中等/旧版/矩形经典各一）。
extends SceneTree

const DEFAULT_PATHS := [
	"res://levels/art_carpet.json",     # 296 格（最大）
	"res://levels/art_target.json",     # 152 格
	"res://levels/ani_mushroom.json",   # 166 格
	"res://levels/ani_octopus.json",    # 60 格（升级前的旧版，对照）
	"res://levels/classic_01.json",     # 矩形经典（基线对照）
]

var _paths: Array = []


func _initialize() -> void:
	_paths = OS.get_cmdline_user_args()
	if _paths.is_empty():
		_paths = DEFAULT_PATHS.duplicate()
	# 注意：_run 是协程（要 await 布局），不能在这里 quit——否则协程还没跑完进程就退了。
	# 与本工程其他 -s 工具一致：跑完不退出，由调用方收尾（probe 是一次性诊断，无副作用）。
	_run()


func _run() -> void:
	var gs: Node = root.get_node_or_null("GameSession")
	if gs == null:
		push_error("取不到 GameSession autoload —— 本探针必须在 autoload 就绪后运行")
		return
	print("[render-scale] 可视区 = %s" % str(root.size))
	for p in _paths:
		if not FileAccess.file_exists(p):
			print("  %-28s 文件不存在，跳过" % p.get_file())
			continue
		if not bool(gs.call("start_level", p)):
			print("  %-28s 载入失败（LevelLoader 拒绝）" % p.get_file())
			continue
		var board: Board = gs.get("board")
		var bbox := Vector2i(0, 0)
		var cells := 0
		if board != null and board.grid != null:
			bbox = board.grid.size()
			cells = board.grid.cell_count()
		var t0 := Time.get_ticks_msec()
		var view: Node = load("res://ui/board_view.tscn").instantiate()
		root.add_child(view)
		var build_ms := Time.get_ticks_msec() - t0
		await process_frame
		await process_frame                          # 让容器完成一轮布局
		# 布局后 size 才是真的；headless 下若 size 仍为 0（无窗口），退回最小尺寸口径。
		var nodes := _count_nodes(view)
		var vsize := (view as Control).size if view is Control else Vector2.ZERO
		if vsize.x <= 0.0 or vsize.y <= 0.0:
			vsize = (view as Control).get_combined_minimum_size()
		var per_w := vsize.x / maxf(float(bbox.x), 1.0)
		var per_h := vsize.y / maxf(float(bbox.y), 1.0)
		var verdict := "OK"
		if per_w < 3.0 or per_h < 3.0:
			verdict = "⚠ 单格 < 3px（看得见但点不中）"
		if nodes > 8000:
			verdict += " ⚠ 节点数偏大"
		print("  %-28s 格=%-4d bbox=%-9s 节点=%-6d 构建=%-5dms 单格=%.1f×%.1fpx  %s" % [
			p.get_file(), cells, str(bbox), nodes, build_ms, per_w, per_h, verdict])
		root.remove_child(view)
		view.queue_free()
		await process_frame


func _count_nodes(n: Node) -> int:
	var total := 1
	for c in n.get_children():
		total += _count_nodes(c)
	return total
