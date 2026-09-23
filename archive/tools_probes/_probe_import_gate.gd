# _probe_import_gate.gd —— 取证：服务器实际目录名能否过导入闸门
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")
const ImportTool := preload("res://tools/import_batch_to_lib.gd")


func _initialize() -> void:
	# 服务器实际产物目录名（链用「额外组合」路径产出的）
	var real := ["x_classic_s1", "x_classic_s3", "x_o10", "x_o2", "x_o5x",
		"x_classic_z1", "x_classic_z4", "x_classic+s1"]
	# 新版工具内置路径产出的（本地 fill 脚本）
	var builtin := ["classic", "o1", "s1", "z1", "s1_o1", "s1_s2", "z1+s1+o1", "dt"]
	# 旧批次前缀（导入工具声称会剥离 c_/g_）
	var legacy := ["c_o1", "g_s1"]
	print("=== 服务器实际目录名（当前 15 批的产物布局）===")
	for n in real:
		print("  %-16s → 闸门: %s" % [n, "接受" if ImportTool._is_official_mode(n) else "❌ 拒绝"])
	print("=== 新版内置路径 ===")
	for n in builtin:
		print("  %-16s → 闸门: %s" % [n, "接受" if ImportTool._is_official_mode(n) else "拒绝"])
	print("=== 旧前缀（声称已兼容）===")
	for n in legacy:
		print("  %-16s → 闸门: %s" % [n, "接受" if ImportTool._is_official_mode(n) else "拒绝"])
	CliShutdown.request_exit(0)
