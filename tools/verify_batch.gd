# verify_batch.gd —— 题库生成后门禁（防「批量跑完才发现不能用 → 复工」）
#
# 对 out_dir 下每个关卡 JSON 做三重检查：
#   1) JSON 可解析；2) 关卡字段完整（Board 可加载）；3) 玩家视角能推出完整证明链（序贯可解）。
# 任一失败 → 打印清单并 exit 1（可接 CI / 脚本判断）。
#
# 用法（命令行，-- 后为目录）：
#   godot --headless --path . -s res://tools/verify_batch.gd -- <out_dir>
# 例：res://levels 或 user://batch_levels
#
# 与 test_level_proof_coverage.gd 同口径（ProofLog.build 的 solved 判定），但面向任意目录、
# 可独立在批量生成后立刻跑，作为「入库前最后一道闸」。
extends SceneTree

# 可靠退出：见 cli_shutdown.gd 顶部注释。
const CliShutdown := preload("res://tools/cli_shutdown.gd")

var _out_dir := "user://batch_levels"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1 and str(args[0]) != "":
		_out_dir = str(args[0])
	var files := _list_level_json(_out_dir)
	if files.is_empty():
		print("未找到关卡 JSON：%s" % _out_dir)
		CliShutdown.request_exit(1)
		return
	var ok := 0
	var failed: Array[String] = []
	for path in files:
		var level := _load_json(path)
		if level.is_empty():
			failed.append("%s (JSON 无法解析)" % path)
			continue
		# 核心门禁：可加载 + 序贯可解（ProofLog.build 从玩家视角逐轮推必然结论直到全定）。
		var log: Dictionary = ProofLog.build(level)
		if bool(log.get("solved", false)):
			ok += 1
		else:
			failed.append("%s (%s)" % [path, str(log.get("reason", "推不到底"))])
	print("=== 题库验证完成 ===")
	print("  目录: %s" % _out_dir)
	print("  可解 %d / 失败 %d" % [ok, failed.size()])
	for x in failed:
		print("  FAIL: " + x)
	if failed.is_empty():
		print("=== BATCH-VERIFY-OK ===")
		CliShutdown.request_exit(0)
	else:
		print("=== BATCH-VERIFY-FAILED ===")
		CliShutdown.request_exit(1)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)


func _list_level_json(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if not dir.current_is_dir() and n.ends_with(".json") \
				and n != "report.json" and n != "merged_report.json":
			out.append(dir_path.path_join(n))
		n = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return data if data is Dictionary else {}
