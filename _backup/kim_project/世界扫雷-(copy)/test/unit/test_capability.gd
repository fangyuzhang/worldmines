# test_capability.gd —— Capability 能力令牌测试（文档 23 号 §2.2 / 21 号 R32）
extends GutTest


func test_default_granted() -> void:
	var r := Capability.resolve([])
	assert_true(Capability.has(r["granted"], Capability.BOARD_READ), "board.read 应默认授予")
	assert_true(Capability.has(r["granted"], Capability.RNG_STREAM), "rng.stream 应默认授予")
	assert_eq(r["rejected"].size(), 0, "空声明无拒绝")


func test_declared_capability() -> void:
	var r := Capability.resolve([Capability.CLUE_REGISTER])
	assert_true(Capability.has(r["granted"], Capability.CLUE_REGISTER), "声明的能力应授予")


func test_never_granted_rejected() -> void:
	var r := Capability.resolve([Capability.BOARD_WRITE_ANSWER, Capability.RNG_GLOBAL])
	assert_false(Capability.has(r["granted"], Capability.BOARD_WRITE_ANSWER), "board.write_answer 永不授予")
	assert_false(Capability.has(r["granted"], Capability.RNG_GLOBAL), "rng.global 永不授予")
	assert_true(r["rejected"].has(Capability.BOARD_WRITE_ANSWER), "永不授予应进 rejected")


func test_unknown_rejected() -> void:
	var r := Capability.resolve([&"fs.write_system"])
	assert_true(r["rejected"].has(&"fs.write_system"), "未知令牌应进 rejected")


func test_known_never_default() -> void:
	assert_true(Capability.is_known(Capability.CLUE_REGISTER), "合法令牌 is_known=true")
	assert_true(Capability.is_known(Capability.BOARD_WRITE_ANSWER), "永不授予令牌也属已知")
	assert_false(Capability.is_known(&"fs.nope"), "未知令牌 is_known=false")
	assert_true(Capability.is_never(Capability.BOARD_WRITE_ANSWER), "is_never 正确")
	assert_true(Capability.is_default(Capability.BOARD_READ), "is_default 正确")
	assert_false(Capability.is_default(Capability.CLUE_REGISTER), "非默认令牌 is_default=false")
