# skin_service.gd —— Mod 皮肤服务（autoload）：扫描/加载/激活/删除/导入皮肤包
# 皮肤系统核心：内置深/亮主题永远可用且不可删除；Mod 皮肤包覆盖配色与数字色。
# 皮肤目录：user://skins/<skin_id>/skin.json + preview.png（可选贴图）。
# 皮肤加载失败静默回退内置，不崩溃、不弹窗（红线）。
# 所有取色经 ThemeManager 中枢；皮肤覆盖走 ThemeManager.apply_skin。
extends Node

signal skins_changed
## 皮肤激活/回退后发一次：伙伴猫等需要**重载资源**（如 pet/ 贴图覆盖）的消费方订阅。
signal skin_activated

const SKINS_DIR := "user://skins"

var skins: Array = []            # [{id, name, author, version, builtin, base, path, preview, json_path}]
var active_skin_id: String = ""

## 内置主题（永远可用、不可删除、恒在列表最前）。
##
## 【2026-09-29】从 2 项（深/亮）扩到 7 项：新增 CozyStyle 五主题。
## `base` 字段就是 ThemeManager 的主题 id —— 下面 activate() 按它切主题，
## **不要再回到 if/else 硬编码**（旧版写的是 `"dark" if id != "__builtin_light" else "light"`，
## 这个三元式在加入第 3 个内置项之后会静默地把五套新主题全当成深色）。
const BUILTIN := [
	{"id": "__builtin_cozy_salt", "name": "海盐（CozyStyle）", "author": "内置", "version": "1.0.0", "builtin": true, "base": "cozy_salt"},
	{"id": "__builtin_cozy_terracotta", "name": "陶土（CozyStyle）", "author": "内置", "version": "1.0.0", "builtin": true, "base": "cozy_terracotta"},
	{"id": "__builtin_cozy_sage", "name": "鼠尾草（CozyStyle）", "author": "内置", "version": "1.0.0", "builtin": true, "base": "cozy_sage"},
	{"id": "__builtin_cozy_dusk", "name": "暮紫（CozyStyle）", "author": "内置", "version": "1.0.0", "builtin": true, "base": "cozy_dusk"},
	{"id": "__builtin_cozy_haze", "name": "雾霭（CozyStyle）", "author": "内置", "version": "1.0.0", "builtin": true, "base": "cozy_haze"},
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
	# 【2026-09-30 开放性】存档 theme_mode 可能是上次会话注册的自定义主题 id——
	# 注册在扫描时已重放，这里重评一次设置（want==mode 时 ThemeManager 早退，无副作用）。
	if SettingsManager != null:
		SettingsManager.settings_changed.emit()


## 重新扫描皮肤目录，重建 skins 列表（内置两项恒在首位）。
func refresh() -> void:
	var out: Array = BUILTIN.duplicate(true)
	var dir := DirAccess.open(SKINS_DIR)
	if dir != null:
		dir.list_dir_begin()
		var entry := dir.get_next()
		while entry != "":
			if dir.current_is_dir() and not entry.begins_with("."):
				var meta := _read_meta(SKINS_DIR.path_join(entry))
				if not meta.is_empty():
					out.append(meta)
			entry = dir.get_next()
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
	# 【2026-09-30 开放性】skin.json 可带 "theme": {"id","label"} 把本包 palette 注册为
	# **全新主题 id**（不只覆盖某底版）。注册幂等：重复扫描时 ThemeManager 拒绝重名，
	# 这里按失败回退到声明 base 处理。注册表运行期有效，每次启动由本扫描重放。
	var base := str(data.get("base", "dark"))
	var th: Variant = data.get("theme", {})
	if th is Dictionary and not (th as Dictionary).is_empty():
		var tid := _register_theme_from_json(th as Dictionary, data.get("palette", {}))
		if tid != "":
			base = tid
	return {
		"id": skin_dir.get_file(),
		"name": str(data.get("name", skin_dir.get_file())),
		"author": str(data.get("author", "未知")),
		"version": str(data.get("version", "1.0.0")),
		"builtin": false,
		"base": base,
		"path": skin_dir,
		"preview": skin_dir.path_join("preview.png"),
		"json_path": json_path,
	}


## skin.json 的 theme 字段 → ThemeManager.register_theme。成功返回 id，失败返回 ""。
func _register_theme_from_json(th: Dictionary, pal: Variant) -> String:
	var id := str(th.get("id", "")).strip_edges()
	if id == "":
		return ""
	var colors := {}
	if pal is Dictionary:
		for k in pal:
			var v: Variant = pal[k]
			if v is String and k != "numbers":
				colors[str(k)] = v      # register_theme 自做 hex→Color
	var nums: Array = []
	var nv: Variant = pal.get("numbers", []) if pal is Dictionary else []
	if nv is Array:
		for s in nv:
			if s is String:
				nums.append(s)
	var r := ThemeManager.register_theme(id, colors, nums, str(th.get("label", id)))
	return id if bool(r.get("ok", false)) else ""


## 激活皮肤。内置 → 清皮肤 + 切主题；mod 皮肤 → 读色板交给 ThemeManager。
## 返回 { ok, reason }。
func activate(skin_id: String) -> Dictionary:
	if skin_id == "" or skin_id.begins_with("__builtin"):
		# 【2026-09-29】底版一律从条目的 base 字段取，不再用 if/else 猜 —— 旧写法
		#（"dark" if skin_id != "__builtin_light" else "light"）在加入 CozyStyle 五主题后
		# 会把它们全部当成深色（皮肤浏览器里点「海盐」却什么都没变，且不报错）。
		var base := "dark"
		var entry0 := _find(skin_id)
		if not entry0.is_empty():
			base = str(entry0.get("base", "dark"))
		ThemeManager.clear_skin(base)
		if SettingsManager != null:
			SettingsManager.set_theme_mode(base)
			SettingsManager.set_active_skin(skin_id)
		active_skin_id = skin_id
		skin_activated.emit()
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
	skin_activated.emit()
	return {"ok": true}


## 当前激活皮肤目录下的伙伴猫贴图覆盖（skin/pet/<文件名>，文件名与内置
## pet_tail/pet_body/pet_head/pet_lid_l/pet_lid_r/pet_muzzle 相同）。无皮肤或无该文件
## 返回 null（消费方回退内置贴图 / 图元模式）。运行时直读文件，绕开 .import 依赖。
func pet_tex(file: String) -> Texture2D:
	if active_skin_id == "" or active_skin_id.begins_with("__builtin"):
		return null
	var entry := _find(active_skin_id)
	if entry.is_empty():
		return null
	var p := str(entry["path"]).path_join("pet").path_join(file)
	if not FileAccess.file_exists(p):
		return null
	var img := Image.load_from_file(ProjectSettings.globalize_path(p))
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


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
	# 【09-28 审计修复 A9】解压限额：zip-slip 在下面已防，但原先**无条目数/解压总量上限** ⇒
	# 高压缩比 zip（zip bomb）可把 user:// 写爆。超限即中止并回滚已写文件。
	var max_files := 50
	var max_bytes := 5 * 1024 * 1024
	if files.size() > max_files:
		zr.close()
		return {"ok": false, "reason": "zip 条目过多（%d > %d）" % [files.size(), max_files]}
	var total_bytes := 0
	var written: Array = []
	DirAccess.make_dir_recursive_absolute(dest)
	for p in files:
		var rel := p
		if root != "." and root != "" and rel.begins_with(root + "/"):
			rel = rel.substr(root.length() + 1)
		# zip-slip 防护（v3.1）：拒绝「..」路径段与绝对路径条目，防止恶意 zip 写出 skins 目录之外
		var slip: bool = rel.begins_with("/") or rel.contains("\\")
		for seg in rel.split("/"):
			if seg == "..":
				slip = true
		if slip:
			push_warning("皮肤 zip 含可疑路径，已跳过: " + p)
			continue
		var bytes := zr.read_file(p)
		if bytes == null:
			continue
		if total_bytes + bytes.size() > max_bytes:
			zr.close()
			for w in written:
				DirAccess.remove_absolute(str(w))
			# 【09-28 审计修复 A8】int/int 显式化（max_bytes 为 5MB 整数，除数为 1MB）
			var max_mb := max_bytes / 1048576.0
			push_warning("皮肤 zip 解压超过 %d MB 上限，已中止并回滚（zip bomb 防护）" % max_mb)
			return {"ok": false, "reason": "zip 解压超限（>%d MB）" % max_mb}
		total_bytes += bytes.size()
		var target := dest.path_join(rel)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var wf := FileAccess.open(target, FileAccess.WRITE)
		if wf != null:
			wf.store_buffer(bytes)
			wf.close()
			written.append(target)
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
	var entry := dir.get_next()
	while entry != "":
		var full := path.path_join(entry)
		if dir.current_is_dir():
			_remove_dir_recursive(full)
		else:
			DirAccess.remove_absolute(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return DirAccess.remove_absolute(path)
