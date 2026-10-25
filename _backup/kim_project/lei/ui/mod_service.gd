# mod_service.gd —— mod 服务（autoload）：扫描/加载/卸载 mod 规则包（第二篇 mod 系统）
# autoload 名：ModService
# 全局共享一个 DefEngine：内置 Def + 已加载 mod 的 Def。
# mod 目录约定：user://mods/<mod_name>/defs/*.json（每个 JSON 一个线索/约束 Def）。
extends Node

signal mods_changed

const MODS_DIR := "user://mods"

var engine := DefEngine.new()
var loaded_mods: Array[String] = []


func _ready() -> void:
	pass


## 扫描 mods 目录，返回 mod 目录名列表（含 defs 子目录者）。
func scan_mods() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(MODS_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir() and not name.begins_with("."):
			if DirAccess.dir_exists_absolute(MODS_DIR.path_join(name).path_join("defs")):
				out.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


## 加载 mod（目录名）。返回 { ok, reason }。
func load_mod(mod_name: String) -> Dictionary:
	if loaded_mods.has(mod_name):
		return {"ok": true, "reason": "已加载"}
	var loader := ModLoader.new()
	loader.engine = engine
	var r := loader.load_mod_dir(MODS_DIR.path_join(mod_name))
	if r.get("ok", false):
		loaded_mods.append(mod_name)
		mods_changed.emit()
	return r


## 卸载 mod。返回 { ok, reason }。
func unload_mod(mod_name: String) -> Dictionary:
	if not loaded_mods.has(mod_name):
		return {"ok": false, "reason": "未加载"}
	loaded_mods.erase(mod_name)
	_rebuild_engine()
	mods_changed.emit()
	return {"ok": true, "reason": ""}


## 重新构建 engine（内置 + 已加载 mod）。
func _rebuild_engine() -> void:
	engine = DefEngine.new()
	for m in loaded_mods:
		var loader := ModLoader.new()
		loader.engine = engine
		loader.load_mod_dir(MODS_DIR.path_join(m))
