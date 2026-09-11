# wasm_sandbox.gd —— WASM 沙箱实装（P4，godot-wasm 插件 / wasmtime 运行时）
# 三道防线（文档 §4.2 / 第一篇第八章）：
#   1) 宿主只导入 host.tick()：模块无法触碰文件系统/网络，WASI 默认集被收紧的 imports 覆盖。
#   2) 16MB 静态内存上限：load 后校验线性内存 current 字节数，超限即拒绝加载。
#   3) 实例重置约定：每次 load_module 全新实例；reset() 丢弃旧实例，无跨关残留状态。
class_name WasmSandbox
extends RefCounted

const MEMORY_MAX_BYTES := 16 * 1024 * 1024
const PAGE_SIZE := 65536  # wasm 线性内存页 64KB
const MAX_TICKS := 1_000_000  # host_tick 审计上限（运行时无中断 API，超限仅记录）

var _wasm: Wasm = null
var _exports: Dictionary = {}
var _tick_count: int = 0


## 加载模块并校验三道防线。成功返回 true。
func load_module(wasm_bytes: PackedByteArray) -> bool:
	_reset()
	# 防线 0：WASM 魔数校验（\0asm）。Godot 的 Wasm.load 对非法字节会 push_error（引擎级），
	# 在 GUT 测试里被记为 Unexpected Error、在运行时污染错误日志。先校验魔数，
	# 垃圾字节直接拒绝，不触发引擎错误（沙箱应在边界外挡掉非法输入，而非让运行时炸）。
	if wasm_bytes.size() < 4 \
			or wasm_bytes[0] != 0x00 or wasm_bytes[1] != 0x61 \
			or wasm_bytes[2] != 0x73 or wasm_bytes[3] != 0x6d:
		return false
	var wasm := Wasm.new()
	# 防线 1：宿主只导入 host.tick()
	var err: int = wasm.load(wasm_bytes, {"env": {"host_tick": Callable(self, "_host_tick")}})
	if err != 0:
		return false
	_exports = wasm.inspect()
	# 防线 2：16MB 内存上限
	if not _check_memory_limit(_exports):
		_reset()
		return false
	_wasm = wasm
	return true


## 防线 2：校验线性内存不超过 16MB（inspect.memory 字段单位为字节）。
func _check_memory_limit(exports: Dictionary) -> bool:
	var mem_info: Variant = exports.get("memory", {})
	if mem_info is Dictionary:
		var cur: Variant = mem_info.get("current", 0)
		if cur is int and int(cur) > MEMORY_MAX_BYTES:
			return false
	return true


## 调用导出函数 clue(邻域状态) -> 数字。模块未导出或调用失败返回 -1。
func call_clue(neighborhood: Array) -> int:
	if _wasm == null or not _has_export("clue"):
		return -1
	var args: Array = []
	for v in neighborhood:
		args.append(int(v))
	var r: Variant = _wasm.function("clue", args)
	return int(r) if r != null else -1


## 调用导出函数 globalCheck(盘面) -> bool。
## 盘面 Dictionary 序列化为 2bit/格状态位流压缩为 i32 序列，
## 按模块导出签名（inspect 查询参数个数）分配传参。
func call_global_check(board_state: Dictionary) -> bool:
	if _wasm == null or not _has_export("globalCheck"):
		return false
	var arity := _export_arity("globalCheck")
	if arity <= 0:
		return false
	var words := _serialize_state(board_state)
	var args: Array = []
	for i in arity:
		args.append(words[i] if i < words.size() else 0)
	var r: Variant = _wasm.function("globalCheck", args)
	return r != null and int(r) != 0


## 模块导出信息（inspect 转发：import/export 函数、全局、内存）。
func inspect() -> Dictionary:
	return _exports


## host_tick 审计计数（模块主动调用的次数）。
func get_tick_count() -> int:
	return _tick_count


## 实例重置（防线 3，也可显式调用）。
func reset() -> void:
	_reset()


func _reset() -> void:
	_wasm = null
	_exports = {}
	_tick_count = 0


func _has_export(fn: String) -> bool:
	return _exports.get("export_functions", {}).has(fn)


## 导出函数参数个数（未知返回 -1）。
func _export_arity(fn: String) -> int:
	var fns: Dictionary = _exports.get("export_functions", {})
	if not fns.has(fn):
		return -1
	var sig: Array = fns[fn]
	if sig.is_empty():
		return -1
	return sig[0].size()


## 宿主导入：模块主动调用 host.tick() 汇报运行（审计计数，超限记录）。
func _host_tick() -> void:
	_tick_count += 1
	if _tick_count > MAX_TICKS:
		push_warning("WasmSandbox: host_tick 超审计上限 %d" % MAX_TICKS)


## 盘面序列化：按 (y, x) 行列序，每格 2bit：
##   00 空/未知  01 safe/revealed  10 mine  11 flagged
## 每 i32 压缩 15 格（留 2bit 余量避免符号位）。
func _serialize_state(board_state: Dictionary) -> Array:
	var entries: Array = []
	for pos in board_state:
		entries.append([pos, board_state[pos]])
	entries.sort_custom(func(a, b):
		var pa: Vector2i = a[0]
		var pb: Vector2i = b[0]
		return pa.y < pb.y or (pa.y == pb.y and pa.x < pb.x)
	)
	var words: Array = []
	var cur: int = 0
	var shift: int = 0
	for e in entries:
		var code := 0
		match str(e[1]):
			"safe", "revealed":
				code = 1
			"mine":
				code = 2
			"flagged", "flag":
				code = 3
		cur |= code << shift
		shift += 2
		if shift >= 30:
			words.append(cur)
			cur = 0
			shift = 0
	if shift > 0:
		words.append(cur)
	return words
