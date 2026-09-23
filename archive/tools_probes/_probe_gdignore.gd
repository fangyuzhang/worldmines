# _probe_gdignore.gd —— 核实 _staged_levels/.gdignore 是否影响工具读产物
# 门禁/回填工具用 FileAccess 直接读 res://_staged_levels/...（非 ResourceLoader），
# 加 .gdignore 后 editor 不再导入该目录——但 res:// 路径映射与 FileAccess 是否仍可用？本探针实测。
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var p := "res://"
	var dir := DirAccess.open("res://_staged_levels")
	print("[probe] _staged_levels 可列目录: %s" % (dir != null))
	print("[probe] .gdignore 存在: %s" % FileAccess.file_exists("res://_staged_levels/.gdignore"))
	# 找一关真实产物
	if dir != null:
		for sub in dir.get_directories():
			var d2 := DirAccess.open("res://_staged_levels/%s" % sub)
			if d2 == null:
				continue
			for sub2 in d2.get_directories():
				var d3 := DirAccess.open("res://_staged_levels/%s/%s" % [sub, sub2])
				if d3 == null:
					continue
				for sub3 in d3.get_directories():
					var d4 := DirAccess.open("res://_staged_levels/%s/%s/%s" % [sub, sub2, sub3])
					if d4 == null:
						continue
					for f in d4.get_files():
						if str(f).ends_with(".json"):
							var full := "res://_staged_levels/%s/%s/%s/%s" % [sub, sub2, sub3, f]
							var txt := FileAccess.get_file_as_string(full)
							print("[probe] 读到: %s（%d 字节）" % [full, txt.length()])
							var j: Variant = JSON.parse_string(txt)
							print("[probe] JSON 可解析: %s, 有 mines: %s" % [j is Dictionary, (j is Dictionary) and (j as Dictionary).has("mines")])
							CliShutdown.request_exit(0)
							return
	print("[probe] 未找到样例产物")
	CliShutdown.request_exit(1)
