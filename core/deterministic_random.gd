# deterministic_random.gd —— 层级种子派生（方案 B）
# 每个生成阶段拿到「独立且确定」的子种子，互不干扰：改一个阶段不影响其他阶段的确定性。
# 派生公式完全确定（不依赖 hash()/浮点），保证同 seed + 同阶段 → 同子种子。
class_name DeterministicRandom
extends RefCounted

const STAGE_TOPOLOGY := "topology"
const STAGE_MINES := "mines"
const STAGE_PRUNE := "prune"
const STAGE_MASK := "mask"
const STAGE_CHUNK := "chunk"

static var _stage_nums := {
	STAGE_TOPOLOGY: 1,
	STAGE_MINES: 2,
	STAGE_PRUNE: 3,
	STAGE_MASK: 4,
	STAGE_CHUNK: 5,
}


## 从主种子派生某阶段某次的子种子（完全确定）。
static func derive(seed: int, stage: String, index: int = 0) -> int:
	var sn: int = _stage_nums.get(stage, 99)
	return seed * 1000003 + sn * 1000033 + index * 9176 + 17


## 构造确定性 RNG（供布雷/删线索/遮蔽/分块使用）。
static func make_rng(seed: int, stage: String, index: int = 0) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = derive(seed, stage, index)
	return rng
