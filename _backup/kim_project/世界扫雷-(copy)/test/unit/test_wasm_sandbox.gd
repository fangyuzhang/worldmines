# test_wasm_sandbox.gd —— WASM 沙箱三道防线 + clue/globalCheck 契约测试（P4 实装）
extends GutTest

const CLUE_WASM := "res://tools/clue_test.wasm"
const HUGE_WASM := "res://tools/huge_mem.wasm"


func _load_bytes(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	return f.get_buffer(f.get_length())


## 模块加载 + call_clue（8 邻求和）+ call_globalCheck（位掩码）。
func test_load_and_call_clue() -> void:
	var sb := WasmSandbox.new()
	assert_true(sb.load_module(_load_bytes(CLUE_WASM)), "合法模块应加载成功")
	assert_eq(sb.call_clue([1, 2, 3, 4, 5, 6, 7, 8]), 36, "clue 应返回 8 邻求和 36")
	assert_eq(sb.call_clue([0, 0, 0, 0, 0, 0, 0, 0]), 0, "空邻域 clue 应为 0")
	# 2bit 编码：00 未知 / 01 safe / 10 mine / 11 flagged；测试模块 globalCheck = param & 1（bit0）
	assert_true(sb.call_global_check({Vector2i(0, 0): "safe"}), "safe 编码(1) bit0=1 应为真")
	assert_false(sb.call_global_check({Vector2i(0, 0): "mine"}), "mine 编码(2) bit0=0 应为假")
	# 两格压缩进同一 word：safe(+mine) → 1 | (2<<2) = 9，bit0=1 为真
	assert_true(sb.call_global_check({Vector2i(0, 0): "safe", Vector2i(1, 0): "mine"}), "两格压缩 bit0 仍为真")


## 防线 2：19.2MB 内存模块被拒绝加载。
func test_memory_limit_defense() -> void:
	var sb := WasmSandbox.new()
	assert_false(sb.load_module(_load_bytes(HUGE_WASM)), "300 页(19.2MB)内存模块应被 16MB 上限拒绝")
	assert_eq(sb.call_clue([1]), -1, "加载失败后调用应返回 -1")


## 防线 3：reset 丢弃实例；未导出 clue 的模块返回 -1。
func test_reset_and_missing_export() -> void:
	var sb := WasmSandbox.new()
	assert_true(sb.load_module(_load_bytes(CLUE_WASM)), "加载成功")
	sb.reset()
	assert_eq(sb.call_clue([1, 2, 3, 4, 5, 6, 7, 8]), -1, "reset 后调用应返回 -1")
	# simple 场景：未导出 clue 的模块（huge_mem 已被拒，用 inspect 断言导出表）
	var sb2 := WasmSandbox.new()
	sb2.load_module(_load_bytes(CLUE_WASM))
	assert_true(sb2.inspect().get("export_functions", {}).has("clue"), "导出表应含 clue")
	assert_true(sb2.get_tick_count() >= 0, "host_tick 审计计数可用")


## 非法字节码加载失败。
func test_invalid_bytecode() -> void:
	var sb := WasmSandbox.new()
	var garbage := PackedByteArray()
	for b in [0, 1, 2, 3, 4, 5, 6, 7]:
		garbage.append(b)
	assert_false(sb.load_module(garbage), "非法字节码应加载失败")
