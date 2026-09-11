# export_proof.gd —— 批量为关卡导出「证明日志」（ProofLog 落盘）
#
# 用法（务必用 run_batch.ps1 跑，裸调会踩坑 #23「跑完不退出」）：
#   .\tools\run_batch.ps1 -Script res://tools/export_proof.gd -TimeoutSec 600
#   .\tools\run_batch.ps1 -Script res://tools/export_proof.gd `
#       -ScriptArgs @('res://levels/generated_01.json') -TimeoutSec 300
#
# 不传参数时：扫描 res://levels 下的全部 *.json。
# 产物：user://proof/<关卡名>.json，含完整推理链 + solved 标记。
# 用途：关卡质量证据（该关确实序贯可解且给出链） / CI 可复核产物 / 复盘教学素材。
extends SceneTree

# 不要用 class_name 引用（坑 #26：新全局类不在 .godot 缓存里，headless 解析失败）
const ProofLogScript := preload("res://core/proof_log.gd")
const CliShutdown := preload("res://tools/cli_shutdown.gd")

const LEVEL_DIR := "res://levels"

var _files: Array[String] = []


func _initialize() -> void:
	# 只认「看起来像关卡路径」的参数：run_batch.ps1 会带上一组默认的批量参数
	#（classic / - / 5x5 / …），盲目全收会把它们当成关卡路径。
	var args := OS.get_cmdline_user_args()
	for a in args:
		var s := str(a)
		if s.ends_with(".json") and FileAccess.file_exists(s):
			_files.append(s)
	if _files.is_empty():
		_collect_from(LEVEL_DIR)

	print("=== 证明日志导出 ===")
	print("  关卡数: %d" % _files.size())
	var t0 := Time.get_ticks_msec()
	var ok := 0
	var stuck := 0
	var failed := 0
	for path in _files:
		var level := _read_json(path)
		if level.is_empty():
			print("  [跳过] %s（读取/解析失败）" % path)
			failed += 1
			continue
		var log: Dictionary = ProofLogScript.build(level)
		var key: String = ProofLogScript.key_for(path)
		var written: String = ProofLogScript.save_log(key, log)
		var solved: bool = bool(log.get("solved", false))
		if solved:
			ok += 1
		else:
			stuck += 1
		print("  %s %-28s 轮数=%-3d 步数=%-4d %s" % [
			"OK  " if solved else "卡住",
			key, int(log.get("rounds", 0)), (log.get("steps", []) as Array).size(),
			"" if written != "" else "（写盘失败）"])
	print("=== 完成：可解 %d / 卡住 %d / 失败 %d，耗时 %.1f s ===" % [
		ok, stuck, failed, float(Time.get_ticks_msec() - t0) / 1000.0])
	print("  输出目录: user://proof/")
	# 给运行器用的 ASCII 判据（中文串会被 PS 的编码转换搞坏，见坑 #27）
	print("=== PROOF-EXPORT-OK ===")
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)


func _collect_from(dir_path: String) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir() and n.ends_with(".json"):
			_files.append("%s/%s" % [dir_path, n])
		n = d.get_next()
	d.list_dir_end()
	_files.sort()


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		return parsed
	return {}
