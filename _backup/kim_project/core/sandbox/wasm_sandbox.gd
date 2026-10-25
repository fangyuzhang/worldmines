# wasm_sandbox.gd —— WASM 沙箱空壳（文档 §4.2 / 第一篇第八章）
# P4 接 godot-wasm 插件（wasm3，GDExtension）。
# 宿主只导入 host.tick()；16MB 静态内存上限；实例重置约定。
# 注意：不得出现 OS 超时兜底字样。
class_name WasmSandbox
extends RefCounted

const MEMORY_MAX_BYTES := 16 * 1024 * 1024


func _init() -> void:
	# P0 空壳：仅保证类存在，不加载任何 wasm。
	pass


## P4 契约：加载 .wasm 模块并校验三道防线。
func load_module(_wasm_bytes: PackedByteArray) -> bool:
	push_warning("wasm_sandbox: P0 空壳，P4 接 godot-wasm 实装")
	return false


## P4 契约：调用导出函数 clue(邻域状态) -> 数字。
func call_clue(_neighborhood: Array) -> int:
	return -1


## P4 契约：调用导出函数 globalCheck(盘面) -> bool。
func call_global_check(_board_state: Dictionary) -> bool:
	return false
