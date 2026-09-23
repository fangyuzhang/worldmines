extends SceneTree

## 通用盘面重复统计：递归找所有含 *.json 的目录作为「单元」，统计 总关/不同盘。
## 用法：-s _mod_check.gd -- [dir]（默认 user://batch_all）
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _fp(level: Dictionary) -> String:
	var ms: Array = []
	for m in level.get("mines", []):
		ms.append("%d,%d" % [int(m["c"]), int(m["r"])])
	ms.sort()
	return "|".join(ms)


func _walk(path: String, report: Array) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	var files: Array[String] = []
	for f in d.get_files():
		if str(f).ends_with(".json") and not str(f).begins_with("all_report"):
			files.append(path.path_join(str(f)))
	for sub in d.get_directories():
		_walk(path.path_join(sub), report)
	if files.size() < 2:
		return
	var fps := {}
	for f in files:
		var fh := FileAccess.open(f, FileAccess.READ)
		var level: Dictionary = JSON.parse_string(fh.get_as_text())
		fh.close()
		fps[_fp(level)] = true
	report.append({"unit": path, "total": files.size(), "uniq": fps.size()})


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var base: String = str(args[0]) if args.size() >= 1 and str(args[0]) != "" else "user://batch_all"
	if DirAccess.open(base) == null:
		print("目录不存在: " + base)
		CliShutdown.request_exit(1)
		return
	var report: Array = []
	_walk(base, report)
	var total := 0
	var uniq_total := 0
	var dup_units := 0
	for r in report:
		total += int(r["total"])
		uniq_total += int(r["uniq"])
		if int(r["uniq"]) < int(r["total"]):
			dup_units += 1
			print("  DUP: %s %d关→%d盘" % [r["unit"], r["total"], r["uniq"]])
	print("单元 %d | 总关 %d | 不同盘合计 %d | 有重复盘的单元 %d" % [report.size(), total, uniq_total, dup_units])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
