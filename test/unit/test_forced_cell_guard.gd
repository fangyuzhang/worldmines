extends GutTest

## C# forced-cell 超时/越界守卫回归（v2.9.3 交叉检查修复）：
## ① 超时（Unknown）绝不当「不可行」误报强制格——修复前 FindForcedCells 会把
##    Unknown 判为 UNSAT → 误报「必雷/必安全」→ 错误推理链/错误提示（R02 风险）；
## ② IsForcedCell 越界坐标此前会抛 C# 异常穿过 try 边界——修复后返回 false。


func test_no_false_forced_cells_under_tiny_timeout() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	# 构造「显然无强制格」的盘：全自由、无线索、总雷数宽松（任何格可雷可安）。
	# 即使 1ms 超时触发 Unknown，正确结果也必须是空（不得误报）。
	# 注：小盘 1ms 可能恰好求解完成（结果同样为空），此时覆盖不到 Unknown 分支，
	# 但「无误报」这一核心不变量在所有情况下都被断言。
	var spec := {
		"rows": 9, "cols": 9, "total_mines": 30,
		"safe_cells": [], "mine_cells": [],
		"clues": [], "globals": [], "aux": [],
		"timeout_ms": 1,
	}
	var forced: Dictionary = RuleCpSat.find_forced_cells(spec)
	var mines: Array = forced.get("mine", [])
	var safes: Array = forced.get("safe", [])
	assert_eq(mines.size(), 0, "超时下不得误报必雷格（修复前会全盘误报）")
	assert_eq(safes.size(), 0, "超时下不得误报必安全格（修复前会全盘误报）")


func test_is_forced_cell_out_of_bounds_no_crash() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var spec := {
		"rows": 3, "cols": 3, "total_mines": 1,
		"safe_cells": [], "mine_cells": [],
		"clues": [], "globals": [], "aux": [],
		"timeout_ms": 5000,
	}
	assert_false(RuleCpSat.is_forced_cell(spec, -1, 0), "负坐标应返回 false 而非抛异常")
	assert_false(RuleCpSat.is_forced_cell(spec, 3, 0), "行越界应返回 false")
	assert_false(RuleCpSat.is_forced_cell(spec, 0, 9), "列越界应返回 false")
