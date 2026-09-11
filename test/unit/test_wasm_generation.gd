# test_wasm_generation.gd —— wasm Mod 黑盒生成路径测试（P0-T7 二期）
extends GutTest

const CLUE_WASM := "res://tools/clue_test.wasm"


func _load_sandbox() -> WasmSandbox:
	var f := FileAccess.open(CLUE_WASM, FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var sb := WasmSandbox.new()
	if not sb.load_module(bytes):
		return null
	return sb


## 线索型 wasm 生成：clue_test.wasm（clue = 8 邻求和）→ 生成 → Board 加载 → 线索对拍 → 可玩。
func test_wasm_clue_generate_and_play() -> void:
	var sb := _load_sandbox()
	if sb == null:
		pending("wasm 模块不可用（跳过）")
		return
	var gen := WasmLevelGenerator.new()
	var level := {}
	for seed in range(1, 11):
		level = gen.generate_clue(sb, Vector2i(5, 5), 5, seed)
		if not level.is_empty():
			break
	assert_false(level.is_empty(), "wasm 线索应能在 10 个种子内生成关卡")
	if level.is_empty():
		return
	# Board 加载 + 线索对拍（wasm clue = 8 邻求和 ≡ classic）
	var b := Board.new()
	b.load_level(level)
	var ms := {}
	for m in b._static_mines:
		ms[m] = true
	var size := b.grid.size()
	for rr in size.y:
		for cc in size.x:
			var p := Vector2i(cc, rr)
			if ms.has(p):
				continue
			var expected := 0
			for d in ClueEngine.ring_dirs():
				var q := p + d
				if q.x >= 0 and q.x < size.x and q.y >= 0 and q.y < size.y and ms.has(q):
					expected += 1
			assert_eq(b.grid.get_cell(p).value, expected, "线索值应等于 8 邻求和 @%s" % str(p))
	# 可玩：翻开全部非雷格 → 胜利
	for rr in size.y:
		for cc in size.x:
			var p := Vector2i(cc, rr)
			if not ms.has(p):
				b.reveal(p)
	assert_eq(b.state, Board.GameState.WON, "翻完非雷格应胜利")


## 无 clue 导出的模块（huge_mem 被 16MB 拒绝）生成应返回空，不崩溃。
func test_wasm_generate_rejects_invalid_sandbox() -> void:
	var sb := WasmSandbox.new()
	var garbage := PackedByteArray()
	for x in [0, 1, 2, 3, 4, 5, 6, 7]:
		garbage.append(x)
	assert_false(sb.load_module(garbage), "垃圾字节应被魔数防线拒绝")
	var gen := WasmLevelGenerator.new()
	assert_true(gen.generate_clue(sb, Vector2i(5, 5), 5, 1).is_empty(), "无效沙箱生成应返回空")
	assert_true(gen.generate_global(sb, Vector2i(5, 5), 5, 1).is_empty(), "无效沙箱生成应返回空")
