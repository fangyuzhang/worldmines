# apply_texture_marks.gd —— 按 TextureMarks 规则表校正关卡的 palette.texture
#
# 用途（2026-09-23 审计续）：把散落的历史补丁（手工加值、换约束后未同步的旧值）一次收敛
# 到唯一规则源 tools/texture_marks.gd。
#
# 作用范围（**保守**）：只处理「带 global_rules 的关」——它们的徽记由变体轴唯一决定
#（s1→forbid … dt→pip），补值与纠错都没有歧义（例如 ani_turtle 在水母换约束后仍是旧值
# block，按表应改成 s2 的 anchor）。不带 global_rules 的形状关现状已正确
#（holed=strata、hex=comb、iso=cube…），且同一 topology.style 可能对应多种徽记
#（holed_grid 下既有 holed_* 的 strata 也有 sty_sq_* 的 weave），不宜按 style 反推——
# 那些族由各自的生成器在写盘时按 kind 解析（已接入 TextureMarks）。
#
# 写盘走 level_staging（暂存 → 校验 → 原子转正），与其他生成器一致。
# 用法： godot --headless --path . -s res://tools/apply_texture_marks.gd [--dry]
extends SceneTree

const LEVELS_DIR := "res://levels"
const Marks := preload("res://tools/texture_marks.gd")
const LevelStaging := preload("res://tools/level_staging.gd")

var _dry := false
var _scanned := 0
var _changed := 0
var _kept := 0
var _no_mark := 0
var _rows: Array = []


func _initialize() -> void:
	_dry = "--dry" in OS.get_cmdline_user_args()
	_scan()
	_report()
	quit(0)


func _scan() -> void:
	var d := DirAccess.open(LEVELS_DIR)
	if d == null:
		push_error("打不开 %s" % LEVELS_DIR)
		return
	for fn in d.get_files():
		if not fn.ends_with(".json"):
			continue
		var path := "%s/%s" % [LEVELS_DIR, fn]
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if not (parsed is Dictionary):
			continue
		var lv: Dictionary = parsed
		var globals_arr: Variant = lv.get("global_rules", [])
		if not (globals_arr is Array) or (globals_arr as Array).is_empty():
			continue                                  # 无变体：不在本工具范围（见文件头）
		_scanned += 1
		var variant := str((globals_arr as Array)[0])
		var want := Marks.resolve("", variant, "")
		if want == "":
			_no_mark += 1                             # 该变体没有专属徽记（z1/z3/z4/z5 等）
			continue
		var pal: Variant = lv.get("palette", null)
		if not (pal is Dictionary):
			pal = {}
		var cur := str((pal as Dictionary).get("texture", ""))
		if cur == want:
			_kept += 1
			continue
		_rows.append("%s（%s）: %s → %s" % [fn, variant, cur if cur != "" else "(无)", want])
		_changed += 1
		if _dry:
			continue
		(pal as Dictionary)["texture"] = want
		lv["palette"] = pal
		var tmp := LevelStaging.write_text(path, JSON.stringify(lv, "  "))
		if tmp != "":
			LevelStaging.promote(tmp, path)


func _report() -> void:
	print("[texture-marks] 带变体的关 %d：需校正 %d，已合规 %d，该变体无专属徽记 %d%s" % [
		_scanned, _changed, _kept, _no_mark, "（--dry 未写盘）" if _dry else ""])
	for r in _rows:
		print("  ", r)
	print("=== TEXTURE-MARKS-OK ===")
