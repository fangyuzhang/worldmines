# chunker.gd —— 分块计划（方案 C：大气盘性能）
# 把拓扑切成 ≤ target_cells 的子块，边界重叠（border_ids）保证跨界缝合。
# 高内聚：只负责「怎么切」，不负责「切完怎么解」；与生成管道通过 ChunkPlan 纯数据交互，零耦合。
class_name Chunker
extends RefCounted

class Chunk:
	extends RefCounted
	var cell_ids: Array = []      # 块内格子（Vector2i）
	var border_ids: Array = []    # 跨界格（邻接别的块，用于缝合线索）
	var seed: int = 0             # 本块子种子


class ChunkPlan:
	extends RefCounted
	var blocks: Array = []        # Array[Chunk]


## 用 BFS 贪心把拓扑分成若干块（每块 ≤ target_cells）。
## 确定性：起点/扩展顺序由传入 rng 决定。
static func plan(topo: GridInterface, target_cells: int, rng: RandomNumberGenerator) -> ChunkPlan:
	var plan := ChunkPlan.new()
	if topo == null or target_cells <= 0:
		return plan
	var positions := topo.all_positions()
	if positions.is_empty():
		return plan

	var unassigned := {}
	for p in positions:
		unassigned[p] = true

	var idx := 0
	while not unassigned.is_empty():
		var start: Vector2i = _pick_random(unassigned, rng)
		var block := Chunk.new()
		var queue: Array[Vector2i] = [start]
		var seen := {}
		while not queue.is_empty() and block.cell_ids.size() < target_cells:
			var p: Vector2i = queue.pop_front()
			if seen.has(p) or not unassigned.has(p):
				continue
			seen[p] = true
			unassigned.erase(p)
			block.cell_ids.append(p)
			for nb in topo.get_neighbors(p):
				if unassigned.has(nb) and not seen.has(nb):
					queue.append(nb)
		# 计算 border（块内格子中，邻接未分配格的）
		for p in block.cell_ids:
			for nb in topo.get_neighbors(p):
				if not seen.has(nb):
					block.border_ids.append(p)
					break
		block.seed = DeterministicRandom.derive(rng.seed, DeterministicRandom.STAGE_CHUNK, idx)
		plan.blocks.append(block)
		idx += 1
	return plan


static func _pick_random(m: Dictionary, rng: RandomNumberGenerator) -> Vector2i:
	var keys := m.keys()
	var i := rng.randi_range(0, keys.size() - 1)
	return keys[i]
