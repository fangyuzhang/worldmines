# rng_service.gd —— RNGService 门面单例（文档 §3.6）
# 【人工锁死语义】全工程唯一 RNG 入口。禁止任何地方出现 randi()/randf()/randf_range()。
# P0 铁律：本服务唯一用途 = 启动自检。P1 起生成器/遮蔽/回退全部经此服务。
extends Node

var _rng := RandomNumberGenerator.new()

# 首次运行自检时写入的快照文件（P0 自校准；P1 生成器实装后固化为内置常量）
const SNAPSHOT_PATH := "user://rng_snapshot.json"
const SNAPSHOT_SEED := 12345
const SNAPSHOT_COUNT := 1000


func seed_with(n: int) -> void:
	_rng.seed = n


func randi_range(lo: int, hi: int) -> int:
	return _rng.randi_range(lo, hi)


## 启动自检：seed=12345 连续取 1000 次，结果串接后 SHA-256。
## 首次运行：写入 user://rng_snapshot.json 作为基准（P0 自校准）。
## 后续运行：与快照比对，不一致弹警告。
func self_check() -> bool:
	var probe := RandomNumberGenerator.new()
	probe.seed = SNAPSHOT_SEED
	var bytes := PackedByteArray()
	for i in SNAPSHOT_COUNT:
		var v: int = probe.randi()
		bytes.append(v & 0xFF)
		bytes.append((v >> 8) & 0xFF)
		bytes.append((v >> 16) & 0xFF)
		bytes.append((v >> 24) & 0xFF)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	var digest := ctx.finish().hex_encode()

	if not FileAccess.file_exists(SNAPSHOT_PATH):
		var f := FileAccess.open(SNAPSHOT_PATH, FileAccess.WRITE)
		if f == null:
			push_warning("RNG 快照写入失败（自检基线未建立）: %s" % SNAPSHOT_PATH)
			return false
		f.store_string(digest)
		f.close()
		return true

	var old := FileAccess.get_file_as_string(SNAPSHOT_PATH).strip_edges()
	if old != digest:
		push_warning("引擎 RNG 行为已变更，旧谜题 ID 可能无法精确复现")
		return false
	return true
