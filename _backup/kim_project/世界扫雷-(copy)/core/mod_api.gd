# mod_api.gd —— ModAPI 统一门面（autoload，文档 23 号 §四 / §14 / 21 号 R28~R32）
# 自举式扩展平台的核心入口：
#   - 聚合全局共享的自举原语（服务注册表 / 事件总线 / 插件管理器 / Def 引擎）
#   - 扩展点自注册（§14.2：Mod 可定义新扩展点，R33 平台不得垄断）
#   - Mod 生命周期管理（§六：load / enable / disable / unload + 崩溃隔离）
#   - 能力令牌执行（R32：未声明 = 无权限）
class_name ModAPI
extends Node


## 生命周期钩子名（Mod 的 GDScript 入口可选择性实现）。
const HOOK_LOAD := "on_load"
const HOOK_ENABLE := "on_enable"
const HOOK_DISABLE := "on_disable"
const HOOK_UNLOAD := "on_unload"
const HOOK_LEVEL_START := "on_level_start"
const HOOK_LEVEL_END := "on_level_end"

## Mod 状态。
const STATE_LOADED := "loaded"
const STATE_ENABLED := "enabled"
const STATE_DISABLED := "disabled"
const STATE_CRASHED := "crashed"

## 崩溃隔离阈值：连续失败 N 次 → 标记 crashed，不再自动启用。
const CRASH_LIMIT := 3


# ==== 全局共享的自举原语（Mod 与引擎共用同一批实例） ====
var services := ServiceRegistry.new()      # §14.3 Mod 间互操作
var events := EventBus.new()               # §5 / §14.9 事件总线
var plugins := PluginManager.new()         # §三 扩展点注册表
var defs := DefEngine.new()                # §14.7 Def 注册表（内置 8 线索 + 7 约束）

# mod_id(String) -> { manifest, capabilities, instance, state, crash_count, dir_path }
var _mods: Dictionary = {}

# 敏感能力运行时授权（§14.14，R32：未授权 = 无权限）
var grants := CapabilityGrant.new()


func _ready() -> void:
	pass


# ===================== §14.2 扩展点自注册 =====================

## 定义一个（可能全新的）扩展点。内置点与 Mod 自举点共用（R33）。
func define_extension(point: StringName, contract: Array, _opts: Dictionary = {}) -> bool:
	plugins.declare_point(point, contract)
	return true


## 往某扩展点注册实现（契约校验失败返回 false）。
func register_extension(point: StringName, impl: Object, priority: int = 100) -> bool:
	return plugins.register(point, impl, priority)


## 遍历某扩展点的全部实现（按 priority 降序）。
func each_extension(point: StringName, cb: Callable) -> void:
	if not cb.is_valid():
		return
	for impl in plugins.all(point):
		cb.call(impl)


## 列出全部已声明/已注册扩展点。
func list_extensions() -> Array[StringName]:
	return plugins.list_points()


## 取某扩展点的最高优先级实现（无则 null）。
func first_extension(point: StringName) -> Object:
	return plugins.first(point)


# ===================== Mod 生命周期（§六） =====================

## 加载一个 Mod 目录。返回 { ok, mod_id, rejected, reason }。
## dir_path：含 manifest.json 的 Mod 目录（绝对路径或 res://）。
func load_mod(dir_path: String) -> Dictionary:
	var manifest_path := dir_path.path_join("manifest.json")
	if not FileAccess.file_exists(manifest_path):
		return {"ok": false, "reason": "缺少 manifest.json: %s" % manifest_path}
	var f := FileAccess.open(manifest_path, FileAccess.READ)
	var manifest_text := f.get_as_text()
	f.close()

	var parsed := ManifestParser.new().parse(manifest_text)
	if not parsed.get("ok", false):
		return {"ok": false, "reason": "manifest 解析失败: %s" % parsed.get("reason", "")}
	var manifest: Dictionary = parsed["manifest"]
	var mod_id: String = manifest["id"]
	if _mods.has(mod_id):
		return {"ok": false, "reason": "Mod 已加载: %s" % mod_id}

	# 能力令牌（R32）
	var cap_result := Capability.resolve(manifest.get("capabilities", []))
	var granted: Array[StringName] = cap_result["granted"]

	# 加载入口
	var instance: Object = null
	var entry: Dictionary = manifest["entry"]
	var runtime: String = entry["runtime"]
	match runtime:
		ManifestParser.RUNTIME_GDScript:
			var script_path := dir_path.path_join(str(entry["path"])).simplify_path()
			# 防路径逃逸：解析后必须仍位于 Mod 目录内
			if not script_path.begins_with(dir_path.simplify_path()):
				return {"ok": false, "reason": "入口路径逃逸 Mod 目录: %s" % entry["path"]}
			var script: Variant = load(script_path)
			if script == null:
				return {"ok": false, "reason": "入口脚本加载失败: %s" % script_path}
			instance = script.new()
			if instance == null:
				return {"ok": false, "reason": "入口脚本实例化失败"}
		ManifestParser.RUNTIME_DEF:
			instance = null  # 纯 Def 规则包，无代码入口
		_:
			return {"ok": false, "reason": "暂不支持 runtime: %s" % runtime}

	_mods[mod_id] = {
		"manifest": manifest,
		"capabilities": granted,
		"instance": instance,
		"state": STATE_LOADED,
		"crash_count": 0,
		"dir_path": dir_path,
	}

	# 调用 on_load（崩溃隔离）；失败回滚，避免残留半加载状态
	if not _call_hook(mod_id, HOOK_LOAD):
		_mods.erase(mod_id)
		return {"ok": false, "reason": "on_load 崩溃"}

	events.emit(EventBus.MOD_LOADED, {"id": mod_id})
	return {"ok": true, "mod_id": mod_id, "rejected": cap_result["rejected"]}


## 启用 Mod（调用 on_enable）。返回 { ok, reason }。
func enable_mod(mod_id: String) -> Dictionary:
	var mod := _get_mod(mod_id)
	if mod.is_empty():
		return {"ok": false, "reason": "Mod 未加载: %s" % mod_id}
	if mod["state"] == STATE_CRASHED:
		return {"ok": false, "reason": "Mod 已崩溃禁用: %s" % mod_id}
	if mod["state"] == STATE_ENABLED:
		return {"ok": true, "reason": "已启用"}
	if not _call_hook(mod_id, HOOK_ENABLE):
		return {"ok": false, "reason": "on_enable 崩溃"}
	mod["state"] = STATE_ENABLED  # 钩子成功后再切状态
	return {"ok": true, "reason": ""}


## 禁用 Mod（调用 on_disable）。返回 { ok, reason }。
func disable_mod(mod_id: String) -> Dictionary:
	var mod := _get_mod(mod_id)
	if mod.is_empty():
		return {"ok": false, "reason": "Mod 未加载: %s" % mod_id}
	if mod["state"] == STATE_DISABLED:
		return {"ok": true, "reason": "已禁用"}
	if not _call_hook(mod_id, HOOK_DISABLE):
		return {"ok": false, "reason": "on_disable 崩溃"}
	mod["state"] = STATE_DISABLED  # 钩子成功后再切状态
	return {"ok": true, "reason": ""}


## 卸载 Mod（on_disable + on_unload + 清理记录）。返回 { ok, reason }。
func unload_mod(mod_id: String) -> Dictionary:
	if not _mods.has(mod_id):
		return {"ok": false, "reason": "Mod 未加载: %s" % mod_id}
	var mod: Dictionary = _mods[mod_id]
	if mod["state"] == STATE_ENABLED:
		_call_hook(mod_id, HOOK_DISABLE)
	_call_hook(mod_id, HOOK_UNLOAD)
	_mods.erase(mod_id)
	events.emit(EventBus.MOD_LOADED, {"id": mod_id, "unloaded": true})
	return {"ok": true, "reason": ""}


## 是否有某能力（R32：未声明 = 无权限；敏感能力还需运行时授权，§14.14）。
func has_capability(mod_id: String, token: StringName) -> bool:
	var mod := _get_mod(mod_id)
	if mod.is_empty():
		return false
	if not Capability.has(mod["capabilities"], token):
		return false
	# 敏感能力（ui.inject/net.workshop/debug.cmd）还需用户授权
	if CapabilityGrant.is_sensitive(token) and not grants.is_granted(token):
		return false
	return true


## 已加载 Mod 的 id 列表。
func list_mods() -> Array[String]:
	var out: Array[String] = []
	for id in _mods:
		out.append(id)
	out.sort()
	return out


## Mod 元数据（无则空字典）。返回深副本，防止调用方篡改内部状态（能力令牌越权）。
func mod_info(mod_id: String) -> Dictionary:
	var mod := _get_mod(mod_id)
	if mod.is_empty():
		return {}
	return mod.duplicate(true)


## 清空全部 Mod（测试/重载用）。
func reset() -> void:
	_mods.clear()
	services.clear()
	events.clear()
	plugins.clear()
	defs = DefEngine.new()


# ===================== 内部 =====================

func _get_mod(mod_id: String) -> Dictionary:
	if not _mods.has(mod_id):
		return {}
	return _mods[mod_id]


## 崩溃隔离：调用实例的钩子。返回是否成功（未实现钩子 = 成功）。
## GDScript 无 try/catch；运行时错误由引擎 push_error 隔离，主程序继续。
## 此处额外做实例有效性检查 + 崩溃计数（连续 CRASH_LIMIT 次 → crashed）。
func _call_hook(mod_id: String, hook: String) -> bool:
	var mod := _get_mod(mod_id)
	if mod.is_empty():
		return false
	var instance: Object = mod["instance"]
	if instance == null or not is_instance_valid(instance):
		return true  # 无代码入口（Def 规则包）或已释放，不算失败
	if not instance.has_method(hook):
		return true  # 未实现该钩子，正常
	instance.call(hook)
	if is_instance_valid(instance):
		mod["crash_count"] = 0
		return true
	# 脚本在钩子中失效（self free 等）→ 崩溃计数
	mod["crash_count"] = int(mod["crash_count"]) + 1
	if int(mod["crash_count"]) >= CRASH_LIMIT:
		mod["state"] = STATE_CRASHED
	return false
