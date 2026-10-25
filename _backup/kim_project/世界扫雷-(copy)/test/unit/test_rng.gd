# test_rng.gd —— RNG 确定性（文档 §4.4 / §3.6）
extends GutTest


func test_same_seed_same_result() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var a1 := rng.randi_range(1, 1000000)
	rng.seed = 12345
	var a2 := rng.randi_range(1, 1000000)
	assert_eq(a1, a2, "同种子必须得到相同随机数")


func test_different_seed_different_result() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var a1 := rng.randi_range(1, 1000000)
	rng.seed = 2
	var a2 := rng.randi_range(1, 1000000)
	assert_ne(a1, a2, "不同种子通常得到不同随机数")


func test_rng_service_deterministic() -> void:
	RNGService.seed_with(42)
	var v1 := RNGService.randi_range(1, 1000)
	RNGService.seed_with(42)
	var v2 := RNGService.randi_range(1, 1000)
	assert_eq(v1, v2, "RNGService 封装后仍保持确定性")


func test_rng_snapshot_self_check() -> void:
	# 首次运行会写入快照，之后应通过（或提示引擎变更）
	assert_true(RNGService.self_check(), "RNG 快照自检应通过（首次运行建立基准）")
