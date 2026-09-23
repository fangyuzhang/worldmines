extends SceneTree
# _probe_load_ms.gd —— 测量「点击关卡 → 进入对局」各阶段耗时，定位进入关卡时的卡顿来源。
#
# 用法：godot --headless --path . -s tools/_probe_load_ms.gd -- [mode] [size] [tier] [idx] [n]
#   默认 classic 9 hard 0 5（库里最重的集，9×9 噩梦档）
#
# 测的四段（对应真实进入关卡的链路）：
#   1. LevelLibrary.get_level()   取关卡（首次含集文件 JSON parse；之后走内存缓存）
#   2. LevelLibrary.materialize()  物化落盘（**注释写明每次都重写**——头号嫌疑）
#   3. LevelLoader.load_level()    对局链路加载（读文件 + 校验 + 建 Board）
#   4. Board.load_level()          纯内存建盘（线索计算 + 初始翻开）
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _ms(t0: int) -> float:
	return float(Time.get_ticks_usec() - t0) / 1000.0


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var mode := str(a[0]) if a.size() > 0 else "classic"
	var side := int(a[1]) if a.size() > 1 else 9
	var tier := str(a[2]) if a.size() > 2 else "hard"
	var idx := int(a[3]) if a.size() > 3 else 0
	var n := int(a[4]) if a.size() > 4 else 5

	print("=== 加载链路计时（%s / %d×%d / %s / idx=%d，各 %d 次）===" % [mode, side, side, tier, idx, n])

	# 0. 集文件大小（物化要写的量级参考）
	var set_path := "res://levels_lib/%s/%d/%s.json" % [mode, side, tier]
	if FileAccess.file_exists(set_path):
		var f := FileAccess.open(set_path, FileAccess.READ)
		if f != null:
			print("  集文件: %s（%d 字节）" % [set_path.get_file(), f.get_length()])
			f.close()
	else:
		print("  集文件不存在: %s —— 换一组参数再测" % set_path)

	# 1. get_level：首次（含 parse）与缓存命中分开测
	var t0 := Time.get_ticks_usec()
	var lv := LevelLibrary.get_level(mode, side, tier, idx)
	var first := _ms(t0)
	if lv.is_empty():
		print("  get_level 返回空（该 index 不存在？）—— 中止")
		CliShutdown.request_exit(0)
		return
	var t1 := Time.get_ticks_usec()
	for i in n:
		LevelLibrary.get_level(mode, side, tier, idx)
	var cached := _ms(t1) / float(n)
	print("  1. get_level  首次 %7.2f ms | 缓存命中平均 %7.3f ms" % [first, cached])

	# 2. materialize：每次都写盘（嫌疑最大）
	var t2 := Time.get_ticks_usec()
	var path := ""
	for i in n:
		path = LevelLibrary.materialize(mode, side, tier, idx)
	var mat := _ms(t2) / float(n)
	print("  2. materialize 平均 %7.2f ms（写盘 %s）" % [mat, path])

	# 3. Board.load_level：纯内存（线索计算 + 初始翻开）—— 放在 LevelLoader 之前，
	#    因为后者在无头环境可能因缺 UI 依赖而阻塞（实测卡 >100s），先把内存侧数据拿到。
	var t4 := Time.get_ticks_usec()
	for i in n:
		var b := Board.new()
		b.load_level(lv)
	var bload := _ms(t4) / float(n)
	print("  3. Board.load_level 平均 %7.2f ms（纯内存）" % bload)

	# 4. LevelLoader.load_level：读文件 + 校验 + 建 Board（对局链路真实入口）
	#    ⚠️ 无头环境下可能阻塞（缺 autoload/场景），若此行不出现即为该因，不代表真机表现。
	var t3 := Time.get_ticks_usec()
	var ok := 0
	for i in n:
		var b := LevelLoader.load_level(path)
		if b != null:
			ok += 1
	var lload := _ms(t3) / float(n)
	print("  4. LevelLoader.load_level 平均 %7.2f ms（成功 %d/%d）" % [lload, ok, n])

	print("  合计（每次进入关卡）：约 %.2f ms = 取关卡(缓存) + 物化 + 加载 + 建盘" % [cached + mat + lload])
	print("  若不重写物化（假设跳过写盘）：约 %.2f ms" % [cached + lload])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
