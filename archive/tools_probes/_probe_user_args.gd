# _probe_user_args.gd —— 打印 user args（排查 PowerShell → Godot 的参数传递）
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	print("[args] 数量=%d" % args.size())
	for i in args.size():
		print("  [%d] <%s>" % [i, str(args[i])])
	CliShutdown.request_exit(0)
