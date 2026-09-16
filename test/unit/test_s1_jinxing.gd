# test_s1_jinxing.gd —— S1「局部禁形」单元测试（GUT）
# 覆盖：插件契约（KIND_GLOBAL / id / describe）、构造式布雷（成功时雷数守恒 + 任意 2×2 ≤2 雷）、
# 成功率下界、与内置 pf 的规则等价性。
#
# 已知特性（非缺陷）：高密度（8×8/26 雷 = 40.6%）下构造式布雷会**偶发失败**——分层采样按对齐
# 2×2 块均衡分配，块内满员时相邻块在**跨块窗口**上易组合出 3+ 雷，需靠 _ok 过滤；纯随机兜底
# 通过率更低。**内置 pf 为同一实现**，行为一致。生成器侧有 attempts 重试 + 换 seed 兜底，
# 故产线表现为「偶发 empty 事件」而非坏关（见 batch 的 issues 统计）。
extends GutTest

const MOD_DIR := "res://demo/mods/s1_jinxing"
const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
const TRIALS := 60


func before_all() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod(MOD_DIR)


func _windows_ok(ms: Dictionary, side: int) -> int:
	"""返回违规窗口数（独立于插件 _ok 的第二实现，避免自证）。"""
	var bad := 0
	for rr in side - 1:
		for c in side - 1:
			var n := 0
			for d in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
				if ms.has(Vector2i(c + d.x, rr + d.y)):
					n += 1
			if n > 2:
				bad += 1
	return bad


func test_plugin_contract() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s1")
	assert_not_null(r, "s1 应已注册")
	assert_eq(str(r.call("get_kind")), RulePlugin.KIND_GLOBAL, "S1 应为全局约束类")
	var d: Dictionary = r.call("describe")
	assert_eq(str(d.get("name", "")), "局部禁形", "名称应为「局部禁形」")
	assert_true(str(d.get("rule_text", "")).length() > 0, "应有面向玩家的规则文案")


## 构造式布雷：成功时雷数守恒 + 约束成立；且各尺寸成功率有下界。
func test_place_mines_and_constraint() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s1")
	assert_not_null(r, "s1 未注册")
	for side in [5, 6, 7, 8, 9]:
		var want: int = R07_MINES[side]
		var ok_cnt := 0
		for t in TRIALS:
			var rng := RandomNumberGenerator.new()
			rng.seed = t * 7919 + side
			var mines: Array = r.call("place_mines", rng, side, side, want)
			if mines.size() != want:
				continue
			ok_cnt += 1
			var ms := {}
			for m in mines:
				ms[m] = true
			assert_eq(ms.size(), want, "%dx%d 雷位应无重复且数量守恒" % [side, side])
			assert_eq(_windows_ok(ms, side), 0, "%dx%d 产出盘应满足「任意 2×2 ≤ 2 雷」" % [side, side])
		# 成功率下界**分尺寸**：9×9 需 32 雷而容量 41（填充率 78%），相邻块满员时跨块窗口
		# 极易组合出 3+ 雷 → 分层采样通过率骤降（内置 pf 实测 ~3%，见 HANDOFF「9×9 通过率仅 3%」）。
		# 小尺寸填充率低则通过率高。下界取实测保守值，用于防「实现退化」回归。
		var floor_ratio := 0.05 if side == 9 else 0.5
		assert_gt(float(ok_cnt) / float(TRIALS), floor_ratio,
			"%dx%d 构造式布雷成功率应 > %d%%（实测 %d/%d）" % [
				side, side, int(floor_ratio * 100.0), ok_cnt, TRIALS])


## 与内置 pf 的等价性：同 seed 下两者应产出**完全相同**的雷位（同一算法移植）。
## 若实现有偏移，至少两者的成功率量级应一致（同为分层采样 + 随机兜底）。
func test_equivalence_with_builtin_pf() -> void:
	var r: Object = RuleRegistry.default().resolve(&"s1")
	var pf: Object = RuleRegistry.default().resolve(&"pf")
	assert_not_null(r, "s1 未注册")
	assert_not_null(pf, "内置 pf 未注册")
	var same := 0
	var both_ok := 0
	var trials := 30
	for side in [5, 6, 7]:
		var want: int = R07_MINES[side]
		for t in trials:
			var ra := RandomNumberGenerator.new()
			ra.seed = 31337 + t * 131 + side
			var rb := RandomNumberGenerator.new()
			rb.seed = 31337 + t * 131 + side
			var ma: Array = r.call("place_mines", ra, side, side, want)
			var mb: Array = pf.call("place_mines", rb, side, side, want)
			assert_eq(ma.size(), mb.size(), "%dx%d (seed %d) 两者结果应有相同规模" % [
				side, side, 31337 + t * 131 + side])
			if ma.size() > 0 and mb.size() > 0:
				both_ok += 1
				var sa := {}
				for m in ma:
					sa[m] = true
				var sb := {}
				for m in mb:
					sb[m] = true
				var identical := sa.size() == sb.size()
				if identical:
					for k in sa:
						if not sb.has(k):
							identical = false
							break
				if identical:
					same += 1
	assert_gt(both_ok, 0, "至少应有可对照的成功样本")
	assert_gt(float(same) / float(both_ok), 0.95,
		"s1 与内置 pf 应产出相同雷位（同算法移植；实测 %d/%d 相同）" % [same, both_ok])
