extends SceneTree

# editor_doc_check.gd —— 「编辑器产出的关卡 / 本地 workshop 包」的自助自检 CLI（只读）
#
# 为什么要它：编辑器是**图形界面**，而作者（以及 AI）常常需要在没有窗口的环境里回答同一个问题——
# "这份关卡文件到底能不能玩、规则对不对、是不是无需猜测就能解"。本工具把编辑器的两条内核实
#（`EditorDoc.validate` + `EditorVerify.verify`）搬到命令行，输出可被脚本抓取的结论行。
#
# 用法：
#   godot --headless --path . -s res://tools/editor_doc_check.gd -- \
#       --level=<关卡json路径>            # 直接查一份关卡（支持 user:// 与绝对路径）
#       [--pack=<zip路径>]                # 或查一个 workshop 包（取包内 levels/ 下的第一份）
#       [--budget=MS]                     # 验证器总预算（默认 4000；0 = 跳过验证，只做结构校验）
#
# 输出：
#   ① 结构/规则校验 —— EditorDoc.validate 的 errors（带格坐标）与 warnings 逐条打印；
#   ② 四态验证      —— EditorVerify.verify：无需猜测可解 / 可能需要猜测 / 存在逻辑矛盾 / 未知
#                      （未知=文档不合法 / 无后端 / 触达预算，**绝不用猜代替结论**）；
#   ③ 结论行        —— __EDITOR_VERDICT__ OK|WARN|FAIL <一句话>
#
# 只读：本工具不注册规则、不写任何文件（规则以内存实例参与验证）。
# 退出走 CliShutdown（直接 quit() 在 Godot 4.7.2 mono 下约 7/8 概率挂住，见 tools/cli_shutdown.gd）。
# 注意：不要用 class_name 引用 CliShutdown —— headless 下新全局类不在 .godot 缓存里会解析失败。

const CliShutdown := preload("res://tools/cli_shutdown.gd")

var _args := {}
var _verdict := "FAIL"
var _reason := "未执行"


func _initialize() -> void:
	_args = _parse(OS.get_cmdline_user_args())
	var level := _load_level()
	if level.is_empty():
		_finish("读不出关卡数据（用 --level= 或 --pack= 指定）")
		return
	var doc := EditorDoc.new()
	var lr := doc.load_from(level)
	if not bool(lr["ok"]):
		_finish("关卡无法被编辑器模型载入：%s" % str(lr["reason"]))
		return
	print("棋盘 %dx%d，雷 %d 颗，可用格 %d，密度 %.1f%%" % [
		doc.cols, doc.rows, doc.mine_count(), doc.cell_count(), doc.density() * 100.0])
	print("规则：%s%s" % [doc.rule_id_effective(),
		"（外部拓扑：六边形/三角等，邻域控件不适用）" if not doc.foreign_topology.is_empty() else ""])

	var rep := doc.validate()
	print("—— 校验 ——")
	for e in rep["errors"]:
		var it: Dictionary = e
		var pos: Vector2i = it["pos"]
		print("  [错误] %s%s" % [str(it["text"]),
			"" if pos.x < 0 else "（格 %d,%d）" % [pos.x, pos.y]])
	for w in rep["warnings"]:
		var it2: Dictionary = w
		var pos2: Vector2i = it2["pos"]
		print("  [提醒] %s%s" % [str(it2["text"]),
			"" if pos2.x < 0 else "（格 %d,%d）" % [pos2.x, pos2.y]])
	if not bool(rep["ok"]):
		_finish("关卡未通过校验（%d 条错误）" % (rep["errors"] as Array).size())
		return

	var budget := int(_args.get("budget", "4000"))
	if budget <= 0:
		_finish("结构校验通过（按要求跳过逻辑验证）", "WARN")
		return

	var v := EditorVerify.verify(doc, {"total_budget_ms": budget})
	print("—— 逻辑验证 ——")
	print("  %s" % str(v["label"]))
	print("  %s" % str(v["reason"]))
	var st: Dictionary = v["stats"]
	if not st.is_empty():
		print("  轮数 %d ｜ 起始翻开 %d ｜ 推出安全格 %d ｜ 推出雷 %d ｜ 解数 %d ｜ 后端 %s ｜ 耗时 %d ms" % [
			int(st.get("rounds", 0)), int(st.get("revealed_start", 0)), int(st.get("forced_safe", 0)),
			int(st.get("forced_mine", 0)), int(st.get("solutions", -1)), str(st.get("backend", "-")),
			int(st.get("elapsed_ms", 0))])
	for it3 in v["issues"]:
		print("  [阻止结论] %s" % str((it3 as Dictionary)["text"]))

	match str(v["state"]):
		EditorVerify.STATE_CONTRADICTION:
			_finish("存在逻辑矛盾：%s" % str(v["reason"]))
		EditorVerify.STATE_NO_GUESS:
			_finish("无需猜测可解：%s" % str(v["reason"]), "OK")
		EditorVerify.STATE_NEEDS_GUESS:
			_finish("可能需要猜测：%s" % str(v["reason"]), "WARN")
		_:
			_finish("未能得出结论（未知）：%s" % str(v["reason"]), "WARN")


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)


# ==================== 入参 / 读文件 ====================

func _parse(argv: PackedStringArray) -> Dictionary:
	var out := {}
	for a in argv:
		var s := str(a)
		if s.begins_with("--"):
			var body := s.substr(2)
			var eq := body.find("=")
			if eq == -1:
				out[body] = "1"
			else:
				out[body.substr(0, eq)] = body.substr(eq + 1)
	return out


## 关卡来源二选一：直接给 json，或给一个 workshop 包（取包内 levels/ 下第一份）。
func _load_level() -> Dictionary:
	var direct := str(_args.get("level", ""))
	if direct != "":
		return _read_json(direct)
	var pack := str(_args.get("pack", ""))
	if pack == "":
		return {}
	var zr := ZIPReader.new()
	if zr.open(pack) != OK:
		# 打开失败必须说清楚：最常见的两个原因是路径用了反斜杠、
		# 或这条出错路径本身不是 Godot 能识别的 zip
		print("打开 zip 失败：%s（Godot 路径请用正斜杠 /）" % pack)
		return {}
	# 条目名归一化：Windows 工具（PowerShell Compress-Archive 等）可能写出反斜杠分隔符，
	# 也可能把整包套在一层目录里 ⇒ 找"任意深度的 levels/*.json"，再把原名传给 read_file。
	var target := ""
	var found := ""
	for f in zr.get_files():
		var name := str(f)
		var norm := name.replace("\\", "/")
		if norm.ends_with(".json") and ("levels/" in norm or norm.begins_with("levels")):
			target = name
			found = norm
			break
	if target == "":
		print("包内没有 levels/*.json（包结构应为 manifest.json + levels/<name>.json）")
		zr.close()
		return {}
	var bytes := zr.read_file(target)
	zr.close()
	print("（从包内 %s 读取关卡）" % found)
	return _parse_json_text(bytes.get_string_from_utf8())


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		print("打开失败：%s" % path)
		return {}
	var text := f.get_as_text()
	f.close()
	return _parse_json_text(text)


func _parse_json_text(text: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK:
		print("JSON 解析失败：%s" % json.get_error_message())
		return {}
	var data: Variant = json.data
	if not (data is Dictionary):
		return {}
	return data


func _finish(reason: String, verdict := "FAIL") -> void:
	_verdict = verdict
	_reason = reason
	print("__EDITOR_VERDICT__ %s %s" % [_verdict, _reason])
	CliShutdown.request_exit(0 if _verdict == "OK" else 1)
