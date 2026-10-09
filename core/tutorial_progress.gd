# tutorial_progress.gd —— 教学阅读进度（静态工具，非 autoload）
#
# 为什么独立于 ProgressStore：ProgressStore 记的是**关卡通关**（levels 字典，键是关卡路径），
# 教学页不是关卡、也不该出现在通关统计/雷达里。混进去会让「通关数」虚高。
#
# 数据落在 user://tutorial_seen.json：{"version": 1, "seen": ["tutorial_o1_0", ...]}
# 只记「这一页读过」（不记停留时长、不记页码 —— 没有消费者，不存）。
extends RefCounted


const PATH := "user://tutorial_seen.json"

static var _cache: Dictionary = {}
static var _loaded: bool = false
## 版本号：任何写操作 +1。供读方（教学树面板等）做缓存失效判断。
static var _rev: int = 0


static func rev() -> int:
	return _rev


static func _data() -> Dictionary:
	if _loaded:
		return _cache
	_loaded = true
	_cache = {"version": 1, "seen": []}
	if FileAccess.file_exists(PATH):
		var f := FileAccess.open(PATH, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			# 用 JSON.parse（返回错误码）而不是 parse_string：坏档要**静默跳过**，不刷引擎报错。
			var j := JSON.new()
			if j.parse(text) == OK and j.data is Dictionary and ((j.data as Dictionary).get("seen") is Array):
				_cache = j.data
	return _cache


static func _flush() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_warning("教学进度写入失败：" + PATH)
		return
	f.store_string(JSON.stringify(_data(), "  "))
	f.close()


## 已读页集合：{page_id: true}。返回内部字典的副本（调用方不得改到缓存）。
static func seen() -> Dictionary:
	var out: Dictionary = {}
	for id in (_data().get("seen", []) as Array):
		out[str(id)] = true
	return out


static func is_seen(page_id: String) -> bool:
	return (_data().get("seen", []) as Array).has(page_id)


## 标记一页已读。返回 true = 本次是**新**标记（false = 之前已读过 / 空 id）。
static func mark_seen(page_id: String) -> bool:
	if page_id == "":
		return false
	var d := _data()
	var arr: Array = d.get("seen", [])
	if arr.has(page_id):
		return false
	arr.append(page_id)
	d["seen"] = arr
	d["version"] = 1
	_rev += 1
	_flush()
	return true


static func count() -> int:
	return (_data().get("seen", []) as Array).size()


## 清空全部（设置页「清除进度」用）。
static func clear_all() -> void:
	_cache = {"version": 1, "seen": []}
	_loaded = true
	_rev += 1
	_flush()


## 测试用：丢弃内存缓存。
static func reset_cache() -> void:
	_cache = {}
	_loaded = false
	_rev += 1
