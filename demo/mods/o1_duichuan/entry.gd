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


func on_load() -> void:
	RuleRegistry.default().register(CrossPairRule.new())
