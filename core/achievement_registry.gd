# achievement_registry.gd —— 成就机制（注册 / 判定 / 存盘）（文档 23 号 §14.11 / §3.3 ⑲）
#
# 分工：
#   · 本文件 = **机制**：注册成就、查重、按上下文判解锁、解锁集落盘；
#   · core/achievement_catalog.gd = **内容**：内置 78 条成就的纯数据与判定 DSL。
#   · ui/achievement_service.gd = **接线**：把 ProgressStore / 教学进度 / 创作中心拼成上下文。
#
# Mod 也可以直接 register()：注册接口与内置目录走同一条路（Mod 成就与内置成就一视同仁）。
class_name AchievementRegistry
extends RefCounted


const Catalog := preload("res://core/achievement_catalog.gd")
const PATH := "user://achievements.json"

# id(String) -> { definition: Dictionary, trigger: Callable }
var _defs: Dictionary = {}
# id(String) -> bool（已解锁）
var _unlocked: Dictionary = {}

## 进程内共享实例（内置目录 + 已载入的解锁集）。场景切换不该丢成就状态，
## 也不该每帧重读磁盘 —— 所以用静态单例，落盘只发生在 check_and_save。
static var _shared = null


## 共享实例：首次调用时装配内置目录并读回解锁集。
static func shared():
	if _shared == null:
		_shared = AchievementRegistry.new()
		_shared.load_catalog(Catalog.all())
		_shared.load_state(PATH)
	return _shared


## 测试用：丢弃共享实例（下一个 shared() 会重新装配）。
static func reset_shared() -> void:
	_shared = null


## 注册成就。definition 含 {name, description}（可带 group / desc / hidden）；trigger 接收上下文返回 bool。
func register(id: String, definition: Dictionary, trigger: Callable) -> bool:
	if id == "" or not trigger.is_valid() or _defs.has(id):
		return false
	_defs[id] = {"definition": definition, "trigger": trigger}
	_unlocked[id] = false
	return true


## 批量装配内置目录。返回成功注册条数（重复 id 跳过，不报错）。
## 目录里每条 `cond` 用 Catalog.evaluate 的纯判定包成 trigger —— 内容与机制因此解耦。
func load_catalog(defs: Array) -> int:
	var n := 0
	for d in defs:
		if not (d is Dictionary):
			continue
		var entry: Dictionary = d
		var cond: Variant = entry.get("cond", null)
		var meta := {
			"name": str(entry.get("name", entry.get("id", ""))),
			"description": str(entry.get("desc", entry.get("description", ""))),
			"group": str(entry.get("group", "")),
		}
		if bool(entry.get("hidden", false)):
			meta["hidden"] = true
		if register(str(entry.get("id", "")), meta, func(ctx): return Catalog.evaluate(cond, ctx)):
			n += 1
	return n


## 检查全部成就，返回本次新解锁的成就 id 列表。
func check(ctx: Variant = null) -> Array[String]:
	var c: Dictionary = ctx if ctx is Dictionary else {}
	var newly: Array[String] = []
	for id in _defs:
		if _unlocked[id]:
			continue
		if bool(_defs[id]["trigger"].call(c)):
			_unlocked[id] = true
			newly.append(id)
	return newly


## 判定 + 落盘（有新增才写盘）。UI 层用这个入口。
func check_and_save(ctx: Variant = null, path: String = PATH) -> Array[String]:
	var newly := check(ctx)
	if not newly.is_empty():
		save_state(path)
	return newly


## 是否已解锁。
func is_unlocked(id: String) -> bool:
	return _unlocked.get(id, false)


## 列出全部成就（含解锁状态）。
func list() -> Array:
	var out: Array = []
	for id in _defs:
		var entry: Dictionary = _defs[id]["definition"].duplicate(true)
		entry["id"] = id
		entry["unlocked"] = _unlocked[id]
		out.append(entry)
	return out


func total_count() -> int:
	return _defs.size()


func unlocked_count() -> int:
	var n := 0
	for id in _unlocked:
		if bool(_unlocked[id]):
			n += 1
	return n


## 已解锁 id 列表（按注册顺序）。
func unlocked_ids() -> Array[String]:
	var out: Array[String] = []
	for id in _defs:
		if bool(_unlocked[id]):
			out.append(str(id))
	return out


## 分组统计 {group_id: {"unlocked": int, "total": int}}；未标 group 的归入 "other"。
func progress_by_group() -> Dictionary:
	var out: Dictionary = {}
	for id in _defs:
		var g := str((_defs[id]["definition"] as Dictionary).get("group", ""))
		if g == "":
			g = "other"
		if not out.has(g):
			out[g] = {"unlocked": 0, "total": 0}
		(out[g] as Dictionary)["total"] = int((out[g] as Dictionary)["total"]) + 1
		if bool(_unlocked[id]):
			(out[g] as Dictionary)["unlocked"] = int((out[g] as Dictionary)["unlocked"]) + 1
	return out


## 解锁集落盘：{"version": 1, "unlocked": [id, ...]}。失败返回 false（不抛错）。
func save_state(path: String = PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("成就写入失败：" + path)
		return false
	f.store_string(JSON.stringify({"version": 1, "unlocked": unlocked_ids()}, "  "))
	f.close()
	return true


## 读回解锁集。文件缺失 / 损坏 / 含未知 id 都不报错（未知 id 直接忽略）。
## 返回本次恢复的解锁条数。
func load_state(path: String = PATH) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var text := f.get_as_text()
	f.close()
	# 用 JSON.parse（返回错误码）而不是 JSON.parse_string：后者遇到坏档会**打印引擎报错**，
	# 在 GUT 里算「Unexpected Errors」判红，也很吵（契约是坏档静默跳过，见函数注释）。
	var j := JSON.new()
	if j.parse(text) != OK or not (j.data is Dictionary):
		return 0
	var ids = (j.data as Dictionary).get("unlocked", [])
	if not (ids is Array):
		return 0
	var n := 0
	for raw in (ids as Array):
		var id := str(raw)
		if _unlocked.has(id) and not bool(_unlocked[id]):
			_unlocked[id] = true
			n += 1
	return n


## 清空全部（机制级：定义与解锁状态一起清）。
func clear() -> void:
	_defs.clear()
	_unlocked.clear()
