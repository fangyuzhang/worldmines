extends GutTest

# test_code_hygiene.gd —— 代码卫生契约（防"改一处忘一处"类回归）。
#
# 缘起（2026-09-18）：`mod_api.gd` 的 `var name` 遮蔽 `Node.name` → 编辑器报
# SHADOWED_VARIABLE_BASE_CLASS。这类问题**测试全绿也照样存在**（GUT 不报 GDScript 警告、
# 我也一直只 grep 错误级日志），只能靠静态扫描兜住。本测试把扫描固化下来：
# 新增的遮蔽会让全量跑红，存量（KNOWN）留白名单逐步清零。
#
# 规则：某脚本的 `extends` 是 Node/Control 系时，**局部 var/const 不得与基类属性同名**。
# 属性表只收「确实存在于该类」的高频名，避免误报（如 `text` 不在 Control 上、`state` 不在 Node 上）。

## 扫描范围（产品代码 + 内置 mod；不含 addons/test/tools）。
const SCAN_DIRS: Array = ["res://core", "res://ui", "res://demo"]
## 会被遮蔽的真属性（左=属性名，右=它出现的基类族——此处只用于文档，判定按 UI_BASES）。
const SHADOWING_PROPS: Array = [
	"name", "owner", "script",                                  # Object / Node
	"size", "scale", "position", "rotation", "visible",         # CanvasItem / Control
	"modulate", "theme", "z_index", "focus_mode", "mouse_filter",
	"tooltip_text", "clip_contents", "self_modulate", "pivot_offset",
	"global_position", "process_mode", "scene_file_path",
]
## 这些基类的属性表与上面重叠（数字类/容器类都从 CanvasItem/Control 继承）。
const UI_BASES: Array = ["Node", "Control", "CanvasItem", "Container", "Window", "Popup",
	"PopupPanel", "ScrollContainer", "MarginContainer", "VBoxContainer", "HBoxContainer",
	"GridContainer", "FlowContainer", "Panel", "PanelContainer", "CenterContainer", "Label"]

## 存量待清理（本测试首跑时列出的既有遮蔽；修掉一处就从这里删一行——
## 白名单只减不增，新增遮蔽一律让测试红）。
const KNOWN: Array = [
	"ui/board_view.gd:size",
	"ui/board_view.gd:scale",
	"ui/codex.gd:name",
	"ui/mod_select.gd:size",
	"ui/mod_select.gd:owner",
]


func test_no_new_shadowed_base_class_vars() -> void:
	var offenders: Array[String] = []
	for dir in SCAN_DIRS:
		_scan_dir(str(dir), offenders)
	# 存量白名单（修掉的自动从这里消失；新增的会出现在 offenders 里且不在白名单 → 测试红）
	var unexpected: Array[String] = []
	for o in offenders:
		if not KNOWN.has(o):
			unexpected.append(o)
	assert_true(unexpected.is_empty(),
			"发现遮蔽基类属性的局部变量（会触发 SHADOWED_VARIABLE_BASE_CLASS）：%s\n" % str(unexpected)
			+ "改法：换变量名（如 size→board_size / name→rule_name / owner→owner_mod）；"
			+ "若确认是误报，请核对基类是否真有该属性。")


func _scan_dir(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var f: String = d.get_next()
	while f != "":
		var p := dir_path.path_join(f)
		if d.current_is_dir():
			if not f.begins_with("."):
				_scan_dir(p, out)
		elif f.ends_with(".gd"):
			_scan_file(p, out)
		f = d.get_next()
	d.list_dir_end()


func _scan_file(path: String, out: Array[String]) -> void:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return
	var base := ""
	for line in text.split("\n"):
		var t := str(line).strip_edges()
		if t.begins_with("extends "):
			base = t.substr(8).strip_edges()
			break
	if base == "" or not UI_BASES.has(base):
		return
	# 局部 var/const 声明中的属性同名（含 `var x := ...` / `var x: T = ...`）
	for line in text.split("\n"):
		var t := str(line).strip_edges()
		if not (t.begins_with("var ") or t.begins_with("const ")):
			continue
		var rest := t.substr(4).strip_edges()
		var name_end := rest.find(" ")
		var colon := rest.find(":")
		var eq := rest.find("=")
		var cut := rest.length()
		for idx in [name_end, colon, eq]:
			if idx > 0 and idx < cut:
				cut = idx
		var vname := rest.substr(0, cut).strip_edges()
		if vname == "" or not SHADOWING_PROPS.has(vname):
			continue
		# 只报「路径去掉 res:// 前缀」的稳定标识（文件+变量名，不记行号——行号易变）
		var rel := path.replace("res://", "")
		var key := "%s:%s" % [rel, vname]
		if not out.has(key):
			out.append(key)
