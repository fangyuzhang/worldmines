# skin_service.gd —— Mod 皮肤服务（autoload）：扫描/加载/激活/删除/导入皮肤包
# 皮肤系统核心：内置深/亮主题永远可用且不可删除；Mod 皮肤包覆盖配色与数字色。
# 皮肤目录：user://skins/<skin_id>/skin.json + preview.png（可选贴图）。
# 皮肤加载失败静默回退内置，不崩溃、不弹窗（红线）。
# 所有取色经 ThemeManager 中枢；皮肤覆盖走 ThemeManager.apply_skin。
extends Node

signal skins_changed

const SKINS_DIR := "user://skins"

var skins: Array = []            # [{id, name, author, version, builtin, base, path, preview, json_path}]
var active_skin_id: String = ""

const BUILTIN := [
	{"id": "__builtin_dark", "name": "深色（内置）", "author": "内置", "version": "1.0.0", "builtin": true, "base": "dark"},
	{"id": "__builtin_light", "name": "亮色（内置）", "author": "内置", "version": "1.0.0", "builtin": true, "base": "light"},
]


func _ready() -> void:
	if SettingsManager != null:
		active_skin_id = SettingsManager.active_skin
	refresh()
	# 恢复上次激活的皮肤（若仍存在，否则保持内置深色）
	if active_skin_id != "":
		activate(active_skin_id)


## 重新扫描皮肤目录，重建 skins 列表（内置两项恒在首位）。
func refresh() -> void:
	var out: Array = BUILTIN.duplicate(true)
	var dir := DirAccess.open(SKINS_DIR)
	if dir != null:
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			if dir.current_is_dir() and not name.begins_with("."):
				var meta := _read_meta(SKINS_DIR.path_join(name))
				if not meta.is_empty():
					out.append(meta)
			name = dir.get_next()
		dir.list_dir_end()
	skins = out
	skins_changed.emit()


## 读 skin.json 元数据，返回皮肤条目 dict（失败返回空 dict，静默）。
func _read_meta(skin_dir: String) -> Dictionary:
	var json_path := skin_dir.path_join("skin.json")
	if not FileAccess.file_exists(json_path):
		return {}
	var f := FileAccess.open(json_path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(txt)
	if not (data is Dictionary):
		return {}
	return {
		"id": skin_dir.get_file(),
		"name": str(data.get("name", skin_dir.get_file())),
		"author": str(data.get("author", "未知")),
		"version": str(data.get("version", "1.0.0")),
		"builtin": false,
		"base": str(data.get("base", "dark")),
		"path": skin_dir,
		"preview": skin_dir.path_join("preview.png"),
		"json_path": json_path,
	}


## 激活皮肤。内置 → 清皮肤 + 切主题；mod 皮肤 → 读色板交给 ThemeManager。
## 返回 { ok, reason }。
func activate(skin_id: String) -> Dictionary:
	if skin_id == "" or skin_id.begins_with("__builtin"):
		var base := "dark" if skin_id != "__builtin_light" else "light"
		ThemeManager.clear_skin(base)
		if SettingsManager != null:
			SettingsManager.set_theme_mode(base)
			SettingsManager.set_active_skin(skin_id)
		active_skin_id = skin_id
		return {"ok": true}
	var entry := _find(skin_id)
	if entry.is_empty():
		return {"ok": false, "reason": "皮肤不存在"}
	var r := _load_palette(entry)
	if not r.get("ok", false):
		# 加载失败：静默回退内置深色（红线 11）
		activate("__builtin_dark")
		return {"ok": false, "reason": r.get("reason", "皮肤加载失败")}
	ThemeManager.apply_skin(skin_id, r["colors"], r["numbers"], entry["base"])
	if SettingsManager != null:
		SettingsManager.set_theme_mode(entry["base"])
		SettingsManager.set_active_skin(skin_id)
	active_skin_id = skin_id
	return {"ok": true}


## 解析 skin.json 的 palette → { colors: {key: Color}, numbers: [Color] }。
func _load_palette(entry: Dictionary) -> Dictionary:
	var f := FileAccess.open(entry["json_path"], FileAccess.READ)
	if f == null:
		return {"ok": false, "reason": "无法读取 skin.json"}
	var txt := f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(txt)
	if not (data is Dictionary):
		return {"ok": false, "reason": "skin.json 解析失败"}
	var pal: Variant = data.get("palette", {})
	if not (pal is Dictionary):
		return {"ok": false, "reason": "palette 字段缺失"}
	var colors := {}
	for k in pal:
		if k == "numbers":
			continue
		var v: Variant = pal[k]
		if v is String:
			colors[k] = Color.from_string(v, Color.WHITE)
	var numbers: Array = []
	var nums: Variant = pal.get("numbers", [])
	if nums is Array:
		for s in nums:
			if s is String:
				numbers.append(Color.from_string(s, Color.WHITE))
	if colors.is_empty() and numbers.size() < 8:
		return {"ok": false, "reason": "皮肤无有效配色"}
	return {"ok": true, "colors": colors, "numbers": numbers}


## 删除皮肤（内置不可删）。
func remove(skin_id: String) -> Dictionary:
	if skin_id.begins_with("__builtin"):
		return {"ok": false, "reason": "内置主题不可删除"}
	var entry := _find(skin_id)
	if entry.is_empty():
		return {"ok": false, "reason": "皮肤不存在"}
	if active_skin_id == skin_id:
		activate("__builtin_dark")  # 删除激活皮肤 → 先回退内置
	var err := _remove_dir_recursive(entry["path"])
	if err != OK:
		return {"ok": false, "reason": "删除失败"}
	refresh()
	return {"ok": true}


## 导入 .zip 皮肤包：解压到 user://skins/，要求内含 skin.json。
## 返回 { ok, reason }。
func import_zip(zip_path: String) -> Dictionary:
	if not FileAccess.file_exists(zip_path):
		return {"ok": false, "reason": "zip 文件不存在"}
	var zr := ZIPReader.new()
	if zr.open(zip_path) != OK:
		return {"ok": false, "reason": "无法打开 zip"}
	var files := zr.get_files()
	var skin_json := ""
	for p in files:
		if p.get_file() == "skin.json":
			skin_json = p
			break
	if skin_json == "":
		zr.close()
		return {"ok": false, "reason": "zip 内无 skin.json"}
	# 皮肤目录名：skin.json 所在目录，根目录则用 zip 文件名
	var root := skin_json.get_base_dir()
	var skin_id := root if (root != "." and root != "") else zip_path.get_file().get_basename()
	var dest := SKINS_DIR.path_join(skin_id)
	DirAccess.make_dir_recursive_absolute(dest)
	for p in files:
		var rel := p
		if root != "." and root != "" and rel.begins_with(root + "/"):
			rel = rel.substr(root.length() + 1)
		var bytes := zr.read_file(p)
		if bytes == null:
			continue
		var target := dest.path_join(rel)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var wf := FileAccess.open(target, FileAccess.WRITE)
		if wf != null:
			wf.store_buffer(bytes)
			wf.close()
	zr.close()
	refresh()
	return {"ok": true}


func _find(skin_id: String) -> Dictionary:
	for s in skins:
		if s["id"] == skin_id:
			return s
	return {}


func _remove_dir_recursive(path: String) -> int:
	var dir := DirAccess.open(path)
	if dir == null:
		return ERR_FILE_NOT_FOUND
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := path.path_join(name)
		if dir.current_is_dir():
			_remove_dir_recursive(full)
		else:
			DirAccess.remove_absolute(full)
		name = dir.get_next()
	dir.list_dir_end()
	return DirAccess.remove_absolute(path)
