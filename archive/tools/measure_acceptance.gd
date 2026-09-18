# measure_acceptance.gd —— P1 变体构造式接受率实测（plan1.9 §6.3 / plan1.8 §3.1）
#
# 运行（全部）： godot --headless --path <proj> -s res://tools/measure_acceptance.gd
# 运行（指定）： godot --headless --path <proj> -s res://tools/measure_acceptance.gd -- clock hv sc
# 产出： user://accept_rate.json（每变体测完立即落盘，中途被杀也保留已测数据）
extends SceneTree

const SIZE := Vector2i(5, 5)
const MINES := 5
const DEFAULT_TRIALS := 3
const FR_TRIALS := 3

var _gen := PuzzleGenerator.new()
var _result := {}


## ⚠️ 口径提示（2026-09-18，本文件属**归档**工具）：
## 默认遍历的 `VariantRegistry.all_codes()` 是**旧 16 变体**，其中 7 个已移入
## `demo/mods/legacy_rules`（列入 BUNDLED_SKIP，默认不加载）→ 直接跑会大面积失败。
## 按终版口径量产请用 `tools/batch_all_variants.gd`（官方三轴，164 组合）；
## 若确实要用本工具，请用命令行参数显式传官方 id（`o1` / `s1` / `z1` …）。
func _initialize() -> void:
	var codes: Array = []
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		codes = args
	else:
		for code in VariantRegistry.all_codes():
			if code != "classic":
				codes.append(code)

	_result = {}
	for code in codes:
		var trials: int = FR_TRIALS if code == "fr" else DEFAULT_TRIALS
		var ok := 0
		for t in trials:
			var level := _gen.generate_constructive(code, SIZE, MINES, t + 1)
			if level.is_empty():
				print("  [%s] seed=%d x" % [code, t + 1])
			else:
				ok += 1
				print("  [%s] seed=%d ok" % [code, t + 1])
		var rate := float(ok) / float(trials)
		_result[code] = {"ok": ok, "trials": trials, "rate": rate}
		print("[acc] %-9s %d/%d = %.0f%%" % [code, ok, trials, rate * 100.0])
		_flush()

	print("[acc] done -> user://accept_rate.json")
	quit(0)


func _flush() -> void:
	var f := FileAccess.open("user://accept_rate.json", FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"suite": "accept_rate", "method": "constructive",
		"size": [SIZE.x, SIZE.y], "mines": MINES, "variants": _result}, "  "))
	f.close()
