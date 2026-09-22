# probe_shape_variants.gd —— 兼容性探针（离线分析，不写关卡）：
#   「全局约束（S/Z 轴）× 异形拓扑」到底能不能生成出序贯无猜的盘？
#
# 为什么需要它：异形拓扑下线索规则被**有意强制 classic**（puzzle_generator.gd:306-314，
# 方向型线索在邻接表上语义矛盾），但**全局约束没有被禁**、且 RuleOracle.build_spec 已把
# topology 交给 RuleBuilder（rule_oracle.gd:114/123/136）。于是「S/Z × 异形」的可行性
# 完全取决于**每个规则自己的实现**是否走 RuleBuilder.neighbors（拓扑安全）还是硬编码
# 方向 dirs（异形上无意义）。本探针用真实生成器逐个试，把结论变成实测数据。
#
# 运行： godot --headless --path . -s res://tools/probe_shape_variants.gd
# 输出： 每个 (拓扑, 规则) 一行：OK / FAIL / TIMEOUT + 耗时；末尾汇总矩阵。
# 判据： 生成器返回非空 = 该规则在异形上可用（**内建 R01 序贯无猜验证**已通过，
#        见 puzzle_generator 的生成管线——非空本身就意味着可解）。
extends SceneTree

const EXIT_FRAMES := 3
const ATTEMPTS := 20
const TIMEOUT_MS := 10000
const SEED := 20260921

var _frames := 0
var _done := false
var _exit_code := 0


func _process(_delta: float) -> bool:
	if _done:
		_frames += 1
		if _frames >= EXIT_FRAMES:
			quit(_exit_code)
		return false
	_done = true
	_run()
	return false


func _run() -> void:
	# 运行期 load：-s 脚本在 autoload 之前编译，编译期依赖会连带失败（见 gen_shape_levels.gd 注释）
	var shape_gen: GDScript = load("res://core/shape_generator.gd")
	var ag_script: GDScript = load("res://core/adjacency_grid.gd")
	var gen_script: GDScript = load("res://core/puzzle_generator.gd")
	var catalog: GDScript = load("res://ui/variant_catalog.gd")
	if shape_gen == null or ag_script == null or gen_script == null:
		print("!! 核心脚本加载失败")
		_exit_code = 1
		return

	var globals: Array = catalog.global_ids()
	print("=== 探针：全局约束 × 异形拓扑（%d 个规则）===" % globals.size())
	print("att=%d timeout=%dms seed=%d" % [ATTEMPTS, TIMEOUT_MS, SEED])

	# 两种代表拓扑：蜂窝盘（六边形邻域 6 邻）与挖洞方格（Moore 8 邻 → 删洞）
	var topos: Array = [
		{"name": "蜂窝5", "pack": {"kind": "hex", "params": {"size": 5}}},
		{"name": "挖洞6x6", "pack": {"kind": "holed_grid", "params": {
			"rows": 6, "cols": 6, "holes": [{"x": 2, "y": 2}, {"x": 3, "y": 2}, {"x": 2, "y": 3}, {"x": 3, "y": 3}]}}},
	]

	var matrix: Dictionary = {}
	for t in topos:
		var tname := str(t["name"])
		var pack: Dictionary = t["pack"]
		var topo_dict: Dictionary = {}
		if str(pack["kind"]) == "hex":
			topo_dict = shape_gen.call("build_hex", int((pack["params"] as Dictionary)["size"]))
		else:
			var p: Dictionary = pack["params"]
			topo_dict = shape_gen.call("build_holed_grid", int(p["rows"]), int(p["cols"]), p["holes"])
		var ag = ag_script.new()
		ag.setup_from_topo(topo_dict)
		var n: int = ag.cell_count()
		var mines: int = maxi(1, int(float(n) * 0.3))
		print("\n---- %s：%d 格 · %d 雷 · bbox %s ----" % [tname, n, mines, str(ag.size())])
		matrix[tname] = {}
		for g in globals:
			var t0 := Time.get_ticks_msec()
			var gen: Object = gen_script.new()
			var lv: Dictionary = gen.generate_with_rules(
					"classic", [str(g)], ag.size(), mines, SEED, 0, ATTEMPTS, ag, TIMEOUT_MS)
			var ms := Time.get_ticks_msec() - t0
			var ok := not lv.is_empty()
			matrix[tname][str(g)] = ok
			var extra := ""
			if ok:
				var prof: Dictionary = lv.get("difficulty_profile", {})
				extra = "mines=%d cx=%s rounds=%s" % [
						int(lv.get("total_mines", 0)), str(prof.get("max_complexity", "?")),
						str(prof.get("rounds", "?"))]
			print("  %-4s %-5s %6dms  %s" % [str(g), "OK" if ok else "FAIL", ms, extra])

	print("\n=== 汇总矩阵 ===")
	var gs: Array = globals
	print("%-8s %s" % ["规则", "  ".join(topos.map(func(t): return str(t["name"])))])
	for g in gs:
		var cells: Array = []
		for t in topos:
			cells.append("✓" if bool(matrix[str(t["name"])].get(str(g), false)) else "✗")
		print("%-8s %s" % [str(g), "     ".join(cells)])
	_exit_code = 0
