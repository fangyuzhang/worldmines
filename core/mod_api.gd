# mod_api.gd —— ModAPI 统一门面（autoload，文档 23 号 §四 / §14 / 21 号 R28~R32）
# 自举式扩展平台的核心入口：
#   - 聚合全局共享的自举原语（服务注册表 / 事件总线 / 插件管理器 / Def 引擎）
#   - 扩展点自注册（§14.2：Mod 可定义新扩展点，R33 平台不得垄断）
#   - Mod 生命周期管理（§六：load / enable / disable / unload + 崩溃隔离）
#   - 能力令牌执行（R32：未声明 = 无权限）
# 注：本脚本作为 autoload（名 ModAPI），不写 class_name——Godot 4 中 class_name 与 autoload
# 同名会冲突（"Class hides an autoload singleton"）。测试需实例化时用 preload 路径。
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

## mod 根目录（与旧 ModService 约定一致）。
const MODS_DIR := "user://mods"

## 内置算子 Mod 的随包目录（22 席 O/S/Z 算子，随游戏发行）。
## 背景（2026-09-17）：MODS_DIR 只扫 user://mods——不做自举的话，玩家机器上**一个变体都不会出现**
## （O/S/Z 全部经 mod 注册，游戏本体内只有内置 8 线索 + 7 约束），选关页表现为「找不到关卡」。
## 启动时把本目录下的 Mod 安装到 user://mods 并加载（幂等：已安装不覆盖，玩家改动优先）。
const BUNDLED_MODS_DIR := "res://demo/mods"
## 不自举的目录：设计档案（o5 三角）/ 未达标变体（o5b 真盘零产）/ 示例 Mod（留给模组页演示）。
const BUNDLED_SKIP: Array = ["o5_sanjiao", "o5b_duijiao", "custom_rule_mod", "hpair_rule_mod"]
## 自举安装成功的 mod id 集合（is_bundled / is_bundled_rule 查询用）。
var _bundled: Dictionary = {}


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
	bootstrap_bundled_mods()


# ===================== 内置算子 Mod 自举 =====================

## 自举内置算子 Mod：res://demo/mods/<name> → user://mods/<name> → load_mod。
## 幂等且**可升级**：以「官方两文件（manifest+entry）内容签名」为准——
##   · 首次安装：整目录拷贝；
##   · 签名变化（随包版本更新）：只覆写官方文件（玩家自加的数据文件不动）；
##   · 签名一致：零拷贝。玩家改过的官方文件会被更新覆盖（官方内容以包内为准）。
## 单个 Mod 失败只记 warning，不阻断启动。返回成功加载的 Mod 数。
func bootstrap_bundled_mods() -> int:
	var dir := DirAccess.open(BUNDLED_MODS_DIR)
	if dir == null:
		return 0
	DirAccess.make_dir_recursive_absolute(MODS_DIR)
	var loaded := 0
	for mod_dir in dir.get_directories():
		if BUNDLED_SKIP.has(mod_dir):
			continue
		var src := "%s/%s" % [BUNDLED_MODS_DIR, mod_dir]
		if not FileAccess.file_exists(src.path_join("manifest.json")):
			continue
		var dst := "%s/%s" % [MODS_DIR, mod_dir]
		var marker := dst.path_join(".bundled_hash")
		var sig := _bundled_signature(src)
		var need_copy := not FileAccess.file_exists(dst.path_join("manifest.json"))
		if not need_copy and (not FileAccess.file_exists(marker)
				or FileAccess.get_file_as_string(marker) != sig):
			need_copy = true   # 无标记（旧版安装）或随包内容已更新
		if need_copy:
			if not _copy_code_mod(src, dst):
				push_warning("内置算子 Mod 安装失败: %s" % mod_dir)
				continue
		var mf := FileAccess.open(marker, FileAccess.WRITE)
		if mf != null:
			mf.store_string(sig)
			mf.close()
		_bundled[mod_dir] = true
		if _mods.has(mod_dir):
			continue
		var r := load_mod(dst)
		if bool(r.get("ok", false)):
			loaded += 1
			_bundled[str(r.get("mod_id", mod_dir))] = true
		else:
			push_warning("内置算子 Mod 加载失败: %s（%s）" % [mod_dir, str(r.get("reason", ""))])
	return loaded


## 官方两文件的内容签名（manifest + entry）；据此判断随包 Mod 是否需要（重）安装。
func _bundled_signature(src: String) -> String:
	var text := ""
	for f in ["manifest.json", "entry.gd"]:
		if FileAccess.file_exists(src.path_join(f)):
			text += FileAccess.get_file_as_string(src.path_join(f)) + "\n----\n"
	return str(text.hash())


## 复制一个代码 Mod 目录（manifest + entry + 其它数据文件；跳过 .uid 编辑器缓存）。
func _copy_code_mod(src: String, dst: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(dst) != OK:
		return false
	var d := DirAccess.open(src)
	if d == null:
		return false
	var files: Array = ["manifest.json", "entry.gd"]
	for f in d.get_files():
		if not str(f).ends_with(".uid") and not files.has(f):
			files.append(f)
	for fname in files:
		var sp := src.path_join(fname)
		if not FileAccess.file_exists(sp):
			if fname == "manifest.json" or fname == "entry.gd":
				return false   # 两个必需文件缺失 = 包不完整
			continue
		var f := FileAccess.open(dst.path_join(fname), FileAccess.WRITE)
		if f == null:
			return false
		f.store_string(FileAccess.get_file_as_string(sp))
		f.close()
	return true


## 该 mod 是否为随包内置（官方算子）。选关页据此把官方算子当「内置变体」展示，而非玩家 Mod。
func is_bundled(mod_id: String) -> bool:
	return _bundled.has(mod_id)


## 该规则是否来自随包内置 Mod（官方算子）。
func is_bundled_rule(rule_id: String) -> bool:
	var owner_id := find_rule_owner(rule_id)
	return owner_id != "" and _bundled.has(owner_id)


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

## 扫描 mods 目录，返回 mod 目录名列表（有 manifest.json 或有 defs/ 子目录者）。
## 兼容两类：带 manifest 的正式 Mod（代码/Def/wasm），与旧 Def 数据包（仅 defs/）。
func scan_mods() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(MODS_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry_name := dir.get_next()
	while entry_name != "":
		if dir.current_is_dir() and not entry_name.begins_with("."):
			var full := MODS_DIR.path_join(entry_name)
			if FileAccess.file_exists(full.path_join("manifest.json")) \
					or DirAccess.dir_exists_absolute(full.path_join("defs")):
				out.append(entry_name)
		entry_name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


## 加载一个 Mod 目录。返回 { ok, mod_id, rejected, reason }。
## dir_path：含 manifest.json 的 Mod 目录；或旧 Def 数据包目录（仅 defs/，自动补内存 manifest）。
func load_mod(dir_path: String) -> Dictionary:
	var manifest_path := dir_path.path_join("manifest.json")
	var manifest_text: String
	if FileAccess.file_exists(manifest_path):
		var f := FileAccess.open(manifest_path, FileAccess.READ)
		if f == null:
			return {"ok": false, "reason": "manifest.json 无法读取: %s" % manifest_path}
		manifest_text = f.get_as_text()
		f.close()
	else:
		# 兼容旧 Def 数据包（无 manifest，仅有 defs/ 子目录）：生成内存 manifest。
		# 历史：ModService 时代 Def 包格式 = user://mods/<name>/defs/*.json，无 manifest。
		# 迁移到 ModAPI 后不能破坏已安装的旧包，故此处自动补一个 runtime=def 的 manifest。
		var defs_dir := dir_path.path_join("defs")
		if not DirAccess.dir_exists_absolute(defs_dir):
			return {"ok": false, "reason": "缺少 manifest.json 且无 defs/ 目录: %s" % dir_path}
		manifest_text = JSON.stringify({
			"id": dir_path.get_file(),
			"version": "1.0.0",
			"entry": {"runtime": "def", "path": "defs"},
		})

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
	var sandbox: WasmSandbox = null  # P0-T7：RUNTIME_WASM 的沙箱实例（三道防线）
	# 本 mod 提供的 Def 规则（[{name, type}]）。运行期=def 的 mod 走 DefEngine 而非
	# RuleRegistry，故它不会出现在变体表里——记下来才能在选关页如实展示「这个 mod 有什么」。
	var own_defs: Array = []
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
			# P0-T3：此前该分支只置 instance=null，从不加载 Def JSON——半成品，
			# 导致 RUNTIME_DEF 的 mod 加载后 defs 引擎里根本没有它的规则。
			# 现用 ModLoader 把 <mod_dir>/defs/*.json 注册进共享 DefEngine。
			var def_loader := ModLoader.new()
			def_loader.engine = defs
			own_defs = def_loader.load_mod_dir(dir_path).get("defs", [])
		ManifestParser.RUNTIME_WASM:
			instance = null
			# P0-T7：wasm 模块经沙箱三道防线（魔数/16MB/实例重置）加载。
			# 与 gdscript 同款防路径逃逸：解析后必须仍位于 Mod 目录内。
			var wasm_path := dir_path.path_join(str(entry["path"])).simplify_path()
			if not wasm_path.begins_with(dir_path.simplify_path()):
				return {"ok": false, "reason": "wasm 路径逃逸 Mod 目录: %s" % entry["path"]}
			var wasm_file := FileAccess.open(wasm_path, FileAccess.READ)
			if wasm_file == null:
				return {"ok": false, "reason": "wasm 文件加载失败: %s" % wasm_path}
			var wasm_bytes := wasm_file.get_buffer(wasm_file.get_length())
			wasm_file.close()
			var sb := WasmSandbox.new()
			if not sb.load_module(wasm_bytes):
				return {"ok": false, "reason": "wasm 模块校验失败（三道防线）"}
			sandbox = sb
		_:
			return {"ok": false, "reason": "暂不支持 runtime: %s" % runtime}

	# 可选拓扑声明 board.json（P0-A：通用邻接表 {positions, adjacency}，任意形状——
	# 三角形/六边形/自定义，不做形状枚举）。缺失 = 默认矩形。
	var board: Dictionary = {}
	var board_path := dir_path.path_join("board.json")
	if FileAccess.file_exists(board_path):
		var bf := FileAccess.open(board_path, FileAccess.READ)
		if bf != null:
			var bdata: Variant = JSON.parse_string(bf.get_as_text())
			bf.close()
			if bdata is Dictionary:
				board = bdata

	_mods[mod_id] = {
		"manifest": manifest,
		"capabilities": granted,
		"instance": instance,
		"sandbox": sandbox,  # P0-T7：wasm mod 的沙箱实例（非 wasm 为 null）
		"board": board,      # P0-A：mod 声明的棋盘拓扑（空 = 矩形）
		"state": STATE_LOADED,
		"crash_count": 0,
		"dir_path": dir_path,
		"rules": [],  # P0-T5：本 mod 经 on_load 注册的规则 id（卸载时清理）
		"defs": own_defs,  # RUNTIME_DEF：本 mod 注册进 DefEngine 的 [{name, type}]（供选关页展示）
	}

	# 调用 on_load 前快照 RuleRegistry + 共享 DefEngine，on_load 后对比——
	# 注册是 mod 自己调 RuleRegistry.register / 写 DefEngine 的（ModAPI 无法拦截），只能事后 diff。
	var before_rules: Array = RuleRegistry.default().all_ids()
	var before_clue_defs: Array = defs.clue_defs.keys()
	var before_constraint_defs: Array = defs.constraint_defs.keys()
	if not _call_hook(mod_id, HOOK_LOAD):
		# 失败回滚（v3.1）：on_load 中途崩溃时已注册进全局表的规则与 Def 按 diff 反向清理——
		# 否则坏 mod 每次启用都留下半初始化状态（规则缺失/生成失败/提示失效的表象
		# 与根因完全脱节）。
		for id in RuleRegistry.default().all_ids():
			if not before_rules.has(id):
				RuleRegistry.default().unregister(StringName(id))
		for k in defs.clue_defs.keys():
			if not before_clue_defs.has(k):
				defs.clue_defs.erase(k)
		for k in defs.constraint_defs.keys():
			if not before_constraint_defs.has(k):
				defs.constraint_defs.erase(k)
		_mods.erase(mod_id)
		return {"ok": false, "reason": "on_load 崩溃"}
	var after_rules: Array = RuleRegistry.default().all_ids()
	var owned_rules: Array = []
	for id in after_rules:
		if not before_rules.has(id):
			owned_rules.append(id)
	_mods[mod_id]["rules"] = owned_rules

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


## 卸载 Mod（on_disable + on_unload + 清理记录 + 重建 Def 引擎）。返回 { ok, reason }。
func unload_mod(mod_id: String) -> Dictionary:
	if not _mods.has(mod_id):
		return {"ok": false, "reason": "Mod 未加载: %s" % mod_id}
	var mod: Dictionary = _mods[mod_id]
	if mod["state"] == STATE_ENABLED:
		_call_hook(mod_id, HOOK_DISABLE)
	_call_hook(mod_id, HOOK_UNLOAD)
	# 清理该 mod 经 on_load 注册的规则（P0-T5），否则卸载后规则残留在选关页
	for rid in mod.get("rules", []):
		RuleRegistry.default().unregister(StringName(str(rid)))
	_mods.erase(mod_id)
	_rebuild_defs()  # DefEngine 无 unregister，卸载后重建（内置 + 剩余 Def mod）
	events.emit(EventBus.MOD_LOADED, {"id": mod_id, "unloaded": true})
	return {"ok": true, "reason": ""}


## 重建 Def 引擎：内置 Def + 所有已加载的 runtime=def mod。
## DefEngine 只有 register、无 unregister，卸载 mod 后必须整体重建才能移除其 Def。
func _rebuild_defs() -> void:
	defs = DefEngine.new()
	for id in _mods:
		var m: Dictionary = _mods[id]
		var manifest: Dictionary = m.get("manifest", {})
		var entry: Dictionary = manifest.get("entry", {})
		if str(entry.get("runtime", "")) == ManifestParser.RUNTIME_DEF:
			var def_loader := ModLoader.new()
			def_loader.engine = defs
			# 顺手刷新该 mod 的 Def 清单（重建后 mod 记录里的 defs 必须与实际注册的一致）
			m["defs"] = def_loader.load_mod_dir(str(m.get("dir_path", ""))).get("defs", [])


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


## 取 wasm mod 的沙箱实例（非 wasm mod 或未加载返回 null）。
## P0-T7：生成/验证路径据此调用 sandbox.call_clue / call_global_check。
func get_sandbox(mod_id: String) -> WasmSandbox:
	var mod := _get_mod(mod_id)
	if mod.is_empty():
		return null
	var sb: Variant = mod.get("sandbox")
	return sb as WasmSandbox


## 取 mod 声明的棋盘拓扑（board.json 内容；无声明返回空字典 = 默认矩形）。
## P0-A：格式为通用邻接表 {positions, adjacency}（AdjacencyGrid.setup_from_topo 形式 1），
## 任意形状均可表达，平台不做「三角形/六边形」枚举。
func get_board(mod_id: String) -> Dictionary:
	var mod := _get_mod(mod_id)
	if mod.is_empty():
		return {}
	var b: Variant = mod.get("board", {})
	return b if b is Dictionary else {}


## 查规则属于哪个 mod（P0-A：代码 Mod 经 on_load 注册的规则 → 其 board 拓扑）。
## 返回 mod_id；无归属（内置/未知）返回空字符串。
func find_rule_owner(rule_id: String) -> String:
	for id in _mods:
		var rules: Array = _mods[id].get("rules", [])
		if rules.has(rule_id):
			return id
	return ""


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
## 契约（v3.1）：代码 Mod 的钩子**必须 return true** 表示完成。
## GDScript 无 try/catch：钩子内运行时错误只中止脚本栈并 push_error，call 正常返回 null，
## 实例依然 valid——旧实现靠 is_instance_valid 判崩溃，永远检测不到，坏钩子被记为成功
## （CRASH_LIMIT/STATE_CRASHED 成不可达代码）。「钩子炸了」与「没按契约写返回值」在调用侧
## 都表现为非 true → 一律按失败计数（内置示例 demo/mods/custom_rule_mod 已同步 return true）。
## 注：on_load 中途崩溃时已注册进 RuleRegistry 的规则由 load_mod 按 diff 反向清理。
func _call_hook(mod_id: String, hook: String) -> bool:
	var mod := _get_mod(mod_id)
	if mod.is_empty():
		return false
	var instance: Object = mod["instance"]
	if instance == null or not is_instance_valid(instance):
		return true  # 无代码入口（Def/wasm 规则包）或已释放，不算失败
	if not instance.has_method(hook):
		return true  # 未实现该钩子，正常
	var ret: Variant = instance.call(hook)
	if ret is bool and bool(ret):
		mod["crash_count"] = 0
		return true
	# 钩子内脚本运行时错误（返回 null）或未按契约返回 true → 崩溃计数
	mod["crash_count"] = int(mod["crash_count"]) + 1
	if int(mod["crash_count"]) >= CRASH_LIMIT:
		mod["state"] = STATE_CRASHED
	return false
