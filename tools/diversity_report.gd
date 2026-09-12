extends SceneTree

## diversity_report.gd —— 题库多样性审计（v2.9.3）
##
## 按（组合×尺寸）分组，组内成对计算盘面 Jaccard 相似度（雷位集 交/并）：
##   · 随机独立盘期望 J ≈ 雷数²/格数 / (2×雷数 - 雷数²/格数)（如 5×5/10雷 ≈ 0.25）；
##   · 显著高于期望 = 同质化（「长得像」的关），> 0.6 记为高相似对。
## 输出各组指标 + 全局汇总 + 高相似对清单（前 20）。
##
## 用法：godot --headless --path . -s res://tools/diversity_report.gd -- [dir]
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var dir := str(args[0]) if args.size() >= 1 and str(args[0]) != "" else "user://batch_all"
	var groups := {}  # 组 key -> Array[Dictionary(level)]
	_collect(dir, dir, groups)
	if groups.is_empty():
		print("未找到关卡：%s" % dir)
		CliShutdown.request_exit(1)
		return
	var global_pairs := 0
	var global_sum := 0.0
	var global_max := 0.0
	var high: Array[String] = []
	var worst_groups: Array[String] = []
	for key in groups:
		var levels: Array = groups[key]
		if levels.size() < 2:
			continue
		var pairs := 0
		var jsum := 0.0
		var jmax := 0.0
		for i in levels.size():
			for j in range(i + 1, levels.size()):
				var jac := _jaccard(levels[i], levels[j])
				pairs += 1
				jsum += jac
				jmax = maxf(jmax, jac)
				if jac > 0.6:
					high.append("%s: %s ↔ %s (J=%.2f)" % [key,
						str(levels[i].get("name", "?")), str(levels[j].get("name", "?")), jac])
		var avg := jsum / float(pairs)
		global_pairs += pairs
		global_sum += jsum
		global_max = maxf(global_max, jmax)
		worst_groups.append("%s 均值%.2f 峰值%.2f" % [key, avg, jmax])
	worst_groups.sort_custom(func(a, b): return a > b)
	print("=== 题库多样性审计: %s ===" % dir)
	print("  组数: %d | 成对比较: %d 对 | 全局平均 J=%.3f | 全局峰值 J=%.3f" % [
		groups.size(), global_pairs, global_sum / float(maxi(1, global_pairs)), global_max])
	print("  高相似对(>0.6): %d" % high.size())
	for h in high.slice(0, 10):
		print("    " + h)
	print("  组内均值 Top10（看是否有整体同质化的组）:")
	for g in worst_groups.slice(0, 10):
		print("    " + g)
	CliShutdown.request_exit(0)


func _collect(root: String, path: String, groups: Dictionary) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var full := path.path_join(n)
		if d.current_is_dir():
			_collect(root, full, groups)
		elif n.ends_with(".json") and not n.begins_with("all_report"):
			var f := FileAccess.open(full, FileAccess.READ)
			var data: Variant = JSON.parse_string(f.get_as_text()) if f != null else null
			if f != null:
				f.close()
			if not (data is Dictionary):
				n = d.get_next()
				continue
			var r: Dictionary = data
			var key := "%s/%sx%s" % [
				full.get_base_dir().get_base_dir().get_file(),
				str(r.get("size", {}).get("cols", "?")), str(r.get("size", {}).get("rows", "?"))]
			if not groups.has(key):
				groups[key] = []
			(groups[key] as Array).append(r)
		n = d.get_next()
	d.list_dir_end()


func _jaccard(a: Dictionary, b: Dictionary) -> float:
	var sa := {}
	for m in a["mines"]:
		sa[Vector2i(int(m["c"]), int(m["r"]))] = true
	var sb := {}
	for m in b["mines"]:
		sb[Vector2i(int(m["c"]), int(m["r"]))] = true
	var inter := 0
	for p in sa:
		if sb.has(p):
			inter += 1
	var union := sa.size() + sb.size() - inter
	if union <= 0:
		return 0.0
	return float(inter) / float(union)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
