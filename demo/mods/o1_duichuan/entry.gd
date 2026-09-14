# entry.gd —— O1「对穿」（v3.0 GDD §4.2 O1）
#
# 规则：以该格为中心有四条轴（横 / 竖 / 主对角 / 副对角）。
# 轴**完整** ⟺ 两端格都在盘内；不完整轴恒不计入。
# 数字 = 两端都是雷的完整轴数。仅内部格生成线索，最外圈不显示。
# 值域：内部 0–4（角/边不生成线索）。
#
# 求解器编码（每完整轴一个布尔 z_a）：
#   z_a ≤ B₊ 、 z_a ≤ B₋ 、 z_a ≥ B₊ + B₋ − 1   （z ⟺ B₊ ∧ B₋ 的线性化）
#   Σ z_a = value
#
# 零值扩散：不可（GDD §4.3——0 值含义是「无轴两端双雷」，非「周围安全」）。
# 遮蔽：不支持（非计数型，GDD §6.2 整体不参与遮蔽）。
# 构造式布雷：不需要（观测算子，随机布雷 + 线索正向计算；轴约束由序贯验证保证）。
#
# 本算子为 v3.0 换血试点第一个（Mod 形态先行，验证五件套：插件+IR+生成+门禁+测试）。
extends RefCounted


class CrossPairRule:
	extends RulePlugin

	## 四轴：每轴 [方向 A, 方向 B]（互为反向）。
	const AXES := [
		[Vector2i(-1, 0), Vector2i(1, 0)],   # 横
		[Vector2i(0, -1), Vector2i(0, 1)],   # 竖
		[Vector2i(-1, -1), Vector2i(1, 1)],  # 主对角
		[Vector2i(1, -1), Vector2i(-1, 1)],  # 副对角
	]

	const NB8 := [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
	]

	func get_rule_id() -> StringName:
		return &"o1"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {
			"name": "对穿",
			"rule_text": "四条直线（横、竖、两条对角）穿过这个数字，数字 = 几条直线两头都是雷；盘内任一侧邻域不足时该方向不计",
		}

	func applies_to(_pos: Vector2i, _grid_size: Vector2i) -> bool:
		# v3.0 方案 A 修正（试点预检驱动）：全部格铺线索。
		# 原设计「仅内部格」信息量不足——5 尺寸 20 盘预检全线索序贯可解率 0%
		#（内部线索 ~5.8 条/盘 × 值域 0–4，低于全盘雷分布熵；见 op_design_precheck 与 HANDOFF）。
		# 外圈格完整轴少 → 值域自然更小（角 0–1、边 0–2），但每格都携带信息。
		return true

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		var k := 0
		for ax in AXES:
			var pa: Vector2i = pos + ax[0]
			var pb: Vector2i = pos + ax[1]
			# 完整轴：两端都在盘内（缺一端恒不计入）。
			if pa.x < 0 or pa.x >= grid_size.x or pa.y < 0 or pa.y >= grid_size.y:
				continue
			if pb.x < 0 or pb.x >= grid_size.x or pb.y < 0 or pb.y >= grid_size.y:
				continue
			if mine_set.has(pa) and mine_set.has(pb):
				k += 1
		return k

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var zs: Array = []
		for ax in AXES:
			var pa: Vector2i = pos + ax[0]
			var pb: Vector2i = pos + ax[1]
			if not b.in_board(pa.y, pa.x) or not b.in_board(pb.y, pb.x):
				continue  # 不完整轴恒不计入（与正向一致）
			var ba := b.cell_var(pa.y, pa.x)
			var bb := b.cell_var(pb.y, pb.x)
			var z := b.bool_var()
			b.add_imp(z, ba)                              # z → B₊
			b.add_imp(z, bb)                              # z → B₋
			b.add_bool_or([b.not_lit(ba), b.not_lit(bb), z])  # B₊ ∧ B₋ → z
			zs.append(z)
		b.add_eq(b.sum(zs), int(value))

	func value_upper_bound(_grid_size: Vector2i) -> int:
		return 4

	## 效率布雷（v3.0 接受率专项·定案版）：「低聚类 + 偏边缘」加权序列采样。
	## 依据（60 seed 相关性）：雷聚类度 vs 难度 r=−0.44（越分散越难）、边缘雷 r=+0.29；
	## 特征 Top20 盘平均难度 0.49 vs Bottom20 的 0.13（3.8×）。
	## A/B 实测（7×7，60 seed）：废品率（<0.1）48%→22%、normal+（≥1.2）5%→8%（不降反升）、
	## 平均难度 0.359→0.413。曾试「65/35 混合随机模式」，实测全面劣于纯效率（A/B 数据）——
	## 「随机模式补偿 normal+」的假设不成立，已回滚为纯效率布雷。
	## 合规：一次成型加权采样（非「随机 + 拒绝重采」，R03）；确定性由传入 rng 保证（同 seed 同盘）。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		return _place_weighted(rng, cols, rows, count)

	## 效率模式：低聚类（抑制已选雷八邻权重）+ 偏边缘（边缘格 ×1.25）加权序列采样。
	func _place_weighted(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		var weights: Dictionary = {}
		for r in rows:
			for c in cols:
				var edge := c == 0 or r == 0 or c == cols - 1 or r == rows - 1
				weights[Vector2i(c, r)] = 1.25 if edge else 1.0
		var out: Array[Vector2i] = []
		for _i in count:
			var total := 0.0
			for p in weights:
				total += float(weights[p])
			if total <= 0.0:
				break
			var pick := rng.randf() * total
			var acc := 0.0
			var chosen := Vector2i(-1, -1)
			for p in weights:
				acc += float(weights[p])
				if acc >= pick:
					chosen = p
					break
			if chosen.x < 0:
				break
			out.append(chosen)
			weights.erase(chosen)
			for d in NB8:
				var q: Vector2i = chosen + d
				if weights.has(q):
					weights[q] = maxf(0.05, float(weights[q]) * 0.35)
		return out


func on_load() -> void:
	RuleRegistry.default().register(CrossPairRule.new())
