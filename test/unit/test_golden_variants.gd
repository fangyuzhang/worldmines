extends GutTest

## 验证资产②：黄金集（线索变体全覆盖）。
##
## 铁律（GDD 14.5.2）：期望值由人工按 **spec 定义**预先手推、写死为字面量，
## **禁止测试代码现场调用引擎计算期望值**——防止与实现共享同一错误。
## 本文件所有 `checks` 里的值均为手算（见 GOLDEN 上方每个 case 的注释），
## 与引擎实现无任何运行时依赖。
##
## 额外价值：classic/4n/sc/knight 的规则路径用 `RulePlugin.count_dirs`，
## 而内置变体路径用 `ClueEngine._count_dirs`——**两处是重复实现**。
## 黄金集对两条路径分别断言，可抓住二者之间的漂移（其余变体的规则直接委托 ClueEngine，
## 双路径断言自动退化为单路径，无害）。

var GOLDEN := {
	# ── classic：8 邻雷数 ──
	"classic": [
		# 中心单雷：所有非雷格都邻接中心 → 1
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 1)],
			"checks": {Vector2i(0, 0): 1, Vector2i(0, 1): 1, Vector2i(2, 2): 1}},
		# 十字（4 正交雷、中心空）：中心 8 邻含 4 雷 → 4；角 (0,0) 只邻 (1,0),(0,1) → 2
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 0), Vector2i(0, 1), Vector2i(2, 1), Vector2i(1, 2)],
			"checks": {Vector2i(1, 1): 4, Vector2i(0, 0): 2}},
		# 右下角单雷：(0,0) 与雷不相邻 → 0；(1,2) 邻 (2,2) → 1
		{"size": Vector2i(3, 3), "mines": [Vector2i(2, 2)],
			"checks": {Vector2i(0, 0): 0, Vector2i(1, 2): 1}},
	],
	# ── 4n：正交 4 格雷数 ──
	"4n": [
		# 中心单雷：正交邻中心者=1，对角角格=0
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 1)],
			"checks": {Vector2i(0, 0): 0, Vector2i(0, 1): 1, Vector2i(2, 2): 0}},
		# 十字：中心 4 正交全雷 → 4；角 (0,0) 正交邻 (1,0),(0,1) → 2
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 0), Vector2i(0, 1), Vector2i(2, 1), Vector2i(1, 2)],
			"checks": {Vector2i(1, 1): 4, Vector2i(0, 0): 2}},
		{"size": Vector2i(3, 3), "mines": [Vector2i(2, 2)],
			"checks": {Vector2i(0, 0): 0, Vector2i(1, 2): 1}},
	],
	# ── sc：对角 4 格雷数 ──
	"sc": [
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 1)],
			"checks": {Vector2i(0, 0): 1, Vector2i(0, 1): 0, Vector2i(2, 2): 1}},
		# 十字：中心对角四角全空 → 0
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 0), Vector2i(0, 1), Vector2i(2, 1), Vector2i(1, 2)],
			"checks": {Vector2i(1, 1): 0, Vector2i(0, 0): 0}},
		{"size": Vector2i(3, 3), "mines": [Vector2i(2, 2)],
			"checks": {Vector2i(0, 0): 0, Vector2i(1, 1): 1}},
	],
	# ── clock：8 邻顺时针首个雷方位（1=上,2=右上,3=右,4=右下,5=下,6=左下,7=左,8=左上），无雷=0 ──
	"clock": [
		# 中心单雷：从 (0,0) 顺时针扫，右下=4；(0,1) 的右=3；(2,2) 的左上=8
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 1)],
			"checks": {Vector2i(0, 0): 4, Vector2i(0, 1): 3, Vector2i(2, 2): 8}},
		# 十字：中心的正上=(1,0) 是雷 → 1；(0,0) 的右=(1,0) 是雷 → 3
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 0), Vector2i(0, 1), Vector2i(2, 1), Vector2i(1, 2)],
			"checks": {Vector2i(1, 1): 1, Vector2i(0, 0): 3}},
		# 右下角单雷：(0,0) 邻域无雷 → 0；(1,1) 右下=(2,2) → 4
		{"size": Vector2i(3, 3), "mines": [Vector2i(2, 2)],
			"checks": {Vector2i(0, 0): 0, Vector2i(1, 1): 4}},
	],
	# ── hv：纵横分计 [正交雷数, 对角雷数] ──
	"hv": [
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 1)],
			"checks": {Vector2i(0, 0): [0, 1], Vector2i(0, 1): [1, 0], Vector2i(2, 2): [0, 1]}},
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 0), Vector2i(0, 1), Vector2i(2, 1), Vector2i(1, 2)],
			"checks": {Vector2i(1, 1): [4, 0], Vector2i(0, 0): [2, 0]}},
		{"size": Vector2i(3, 3), "mines": [Vector2i(2, 2)],
			"checks": {Vector2i(0, 0): [0, 0], Vector2i(1, 1): [0, 1]}},
	],
	# ── fr：向右第一颗雷的距离（中间安全格数），无雷="inf" ──
	"fr": [
		# 中心单雷：(0,1) 右邻即雷 → 0；第 0/2 行右侧无雷 → "inf"
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 1)],
			"checks": {Vector2i(0, 0): "inf", Vector2i(0, 1): 0, Vector2i(0, 2): "inf"}},
		# 十字：(0,0) 右邻 (1,0) 是雷 → 0；(1,1) 右邻 (2,1) 是雷 → 0；(2,2) 右侧无雷 → "inf"
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 0), Vector2i(0, 1), Vector2i(2, 1), Vector2i(1, 2)],
			"checks": {Vector2i(0, 0): 0, Vector2i(1, 1): 0, Vector2i(2, 2): "inf"}},
		# 右下角单雷：(0,2) 距 (2,2) 有 1 格 → 1
		{"size": Vector2i(3, 3), "mines": [Vector2i(2, 2)],
			"checks": {Vector2i(0, 0): "inf", Vector2i(1, 1): "inf", Vector2i(0, 2): 1}},
	],
	# ── loopruns：8 邻环序（首尾相接）连续雷段数 ──
	"loopruns": [
		# 中心单雷：各角/边环序里只有 1 段雷 → 1
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 1)],
			"checks": {Vector2i(0, 0): 1, Vector2i(0, 1): 1, Vector2i(2, 2): 1}},
		# 十字：中心环序 [1,0,1,0,1,0,1,0] → 4 段；角 (0,0) 环序 [1,0,1] → 1 段
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 0), Vector2i(0, 1), Vector2i(2, 1), Vector2i(1, 2)],
			"checks": {Vector2i(1, 1): 4, Vector2i(0, 0): 1}},
		# 右下角单雷：(0,0) 邻域无雷 → 0；(1,1) 只有右下 1 段 → 1
		{"size": Vector2i(3, 3), "mines": [Vector2i(2, 2)],
			"checks": {Vector2i(0, 0): 0, Vector2i(1, 1): 1}},
		# 全雷环（v3.x 零值修复钉死）：中心 8 邻全雷，环上无 0→1 上升沿，
		# 旧实现误判 0（会触发零值误扩散）；修复后全环视作一整段 → 1
		{"size": Vector2i(3, 3),
			"mines": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1),
				Vector2i(2, 1), Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2)],
			"checks": {Vector2i(1, 1): 1}},
	],
	# ── distsum：正交×1 + 对角×2 ──
	"distsum": [
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 1)],
			"checks": {Vector2i(0, 0): 2, Vector2i(0, 1): 1, Vector2i(2, 2): 2}},
		{"size": Vector2i(3, 3), "mines": [Vector2i(1, 0), Vector2i(0, 1), Vector2i(2, 1), Vector2i(1, 2)],
			"checks": {Vector2i(1, 1): 4, Vector2i(0, 0): 2}},
		{"size": Vector2i(3, 3), "mines": [Vector2i(2, 2)],
			"checks": {Vector2i(0, 0): 0, Vector2i(1, 1): 2}},
	],
	# ── knight：骑士走位 8 格雷数（仅规则路径，无 ClueEngine 变体）──
	"knight": [
		# 5×5 单雷 (3,4)：(0,0) 骑士邻 (1,2),(2,1) 均非雷 → 0；(2,2) 骑士邻 (3,4) 是雷 → 1
		{"size": Vector2i(5, 5), "mines": [Vector2i(3, 4)],
			"checks": {Vector2i(0, 0): 0, Vector2i(2, 2): 1}},
	],
}

# 线索规则 id → ClueEngine.Variant（knight 无内置变体，记 -1）
const ENGINE_VARIANT := {
	"classic": ClueEngine.Variant.CLASSIC,
	"4n": ClueEngine.Variant.N4,
	"sc": ClueEngine.Variant.SAME_COLOR,
	"clock": ClueEngine.Variant.CLOCK,
	"hv": ClueEngine.Variant.HV,
	"fr": ClueEngine.Variant.FR,
	"loopruns": ClueEngine.Variant.LOOP_RUNS,
	"distsum": ClueEngine.Variant.DIST_SUM,
	"knight": -1,
}


func test_golden_values_match_spec() -> void:
	var reg := RuleRegistry.default()
	var checked := 0
	var mismatches: Array[String] = []
	for rule_id in GOLDEN:
		var rule: Object = reg.resolve(StringName(rule_id))
		assert_true(rule != null, "规则 %s 应已注册" % rule_id)
		if rule == null:
			continue
		var engine_variant: int = ENGINE_VARIANT[rule_id]
		for case in GOLDEN[rule_id]:
			var size: Vector2i = case["size"]
			var mine_set := {}
			for m in case["mines"]:
				mine_set[m] = true
			for pos in case["checks"]:
				var expected: Variant = case["checks"][pos]
				checked += 1
				# 规则路径（生产）
				var got_rule: Variant = rule.compute_clue(mine_set, pos, size)
				if not _eq(got_rule, expected):
					mismatches.append("%s/规则 (%d,%d): 得 %s 期望 %s" % [rule_id, pos.x, pos.y, str(got_rule), str(expected)])
				# 内置变体路径（与规则路径是两套独立实现，须同时符合）
				if engine_variant >= 0:
					var got_eng: Variant = ClueEngine.compute(engine_variant, mine_set, pos, size)
					if not _eq(got_eng, expected):
						mismatches.append("%s/引擎 (%d,%d): 得 %s 期望 %s" % [rule_id, pos.x, pos.y, str(got_eng), str(expected)])
	assert_gt(checked, 0, "黄金集应非空")
	assert_eq(mismatches.size(), 0, "黄金集与 spec 手推值不一致：%s" % str(mismatches))


## 值等价：int / String("inf") / Array（HV 双值）统一比较。
func _eq(a: Variant, b: Variant) -> bool:
	if a is Array and b is Array:
		var aa: Array = a
		var bb: Array = b
		if aa.size() != bb.size():
			return false
		for i in aa.size():
			if int(aa[i]) != int(bb[i]):
				return false
		return true
	return str(a) == str(b)
