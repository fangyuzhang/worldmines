extends GutTest

## 借鉴 GDD 的三项落地验证：PZ1 分享码 / 关卡结构校验 / R07 固定雷数规格。


# ==================== PZ1 分享码 ====================

func test_pz1_encode_decode_roundtrip() -> void:
	var code := PuzzleCode.encode("classic", ["mx"], Vector2i(5, 5), 4, 0, 1000)
	assert_eq(code, "PZ1|classic|mx|5x5|4|0|1000", "编码格式应为 PZ1|...|...")
	var p := PuzzleCode.decode(code)
	assert_eq(p["clue"], "classic")
	assert_eq(p["globals"], ["mx"])
	assert_eq(p["size"], Vector2i(5, 5))
	assert_eq(p["mines"], 4)
	assert_eq(p["mask_count"], 0)
	assert_eq(p["seed"], 1000)


func test_pz1_no_globals() -> void:
	var code := PuzzleCode.encode("classic", [], Vector2i(5, 5), 4, 0, 7)
	assert_eq(code, "PZ1|classic||5x5|4|0|7", "无全局规则应为空段")
	assert_eq(PuzzleCode.decode(code)["globals"], [], "无全局规则应解成空数组")


func test_pz1_decode_invalid() -> void:
	assert_eq(PuzzleCode.decode(""), {}, "空串应拒")
	assert_eq(PuzzleCode.decode("PZ1|classic"), {}, "段数不足应拒")
	assert_eq(PuzzleCode.decode("PZ2|classic|mx|5x5|4|0|1"), {}, "前缀错误应拒")
	assert_eq(PuzzleCode.decode("PZ1|classic|mx|5xx5|4|0|1"), {}, "尺寸非数字应拒")


func test_pz1_reproduce_deterministic() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var code := "PZ1|classic||5x5|4|0|1000"
	var a := PuzzleCode.reproduce(code)
	var b := PuzzleCode.reproduce(code)
	assert_false(a.is_empty(), "应复现出关卡")
	assert_false(b.is_empty(), "应复现出关卡")
	if not a.is_empty() and not b.is_empty():
		assert_eq(a["total_mines"], b["total_mines"], "雷数一致")
		assert_eq(_sorted_mines(a), _sorted_mines(b), "同码应复现同盘")


func _sorted_mines(level: Dictionary) -> Array:
	var out: Array = []
	for m in level.get("mines", []):
		out.append([int(m["c"]), int(m["r"])])
	out.sort()
	return out


# ==================== 关卡结构校验 ====================

func test_validator_accepts_valid_level() -> void:
	var level := {
		"size": {"rows": 3, "cols": 3}, "total_mines": 2,
		"mines": [{"r": 0, "c": 0}, {"r": 2, "c": 2}],
		"revealed": [{"r": 1, "c": 1}],
	}
	assert_true(bool(LevelValidator.validate_structure(level)["ok"]), "合法关卡应通过")


func test_validator_rejects_mine_in_revealed() -> void:
	var level := {
		"size": {"rows": 3, "cols": 3}, "total_mines": 1,
		"mines": [{"r": 0, "c": 0}],
		"revealed": [{"r": 0, "c": 0}],  # 雷格 ? 后门
	}
	var r := LevelValidator.validate_structure(level)
	assert_false(bool(r["ok"]), "翻开格是雷应被拒")
	assert_true(str(r["reason"]).contains("后门"), "应报「后门」原因")


func test_validator_rejects_oob_dup_bad_mines() -> void:
	var oob := LevelValidator.validate_structure({"size": {"rows": 3, "cols": 3}, "total_mines": 1,
		"mines": [{"r": 9, "c": 0}]})
	assert_false(bool(oob["ok"]), "雷位越界应被拒")
	var dup := LevelValidator.validate_structure({"size": {"rows": 3, "cols": 3}, "total_mines": 2,
		"mines": [{"r": 0, "c": 0}, {"r": 0, "c": 0}]})
	assert_false(bool(dup["ok"]), "雷位重复应被拒")
	var bad := LevelValidator.validate_structure({"size": {"rows": 3, "cols": 3}, "total_mines": 9,
		"mines": []})
	assert_false(bool(bad["ok"]), "雷数=格子总数应被拒")


func test_all_levels_pass_structure_validation() -> void:
	var d := DirAccess.open("res://levels")
	if d == null:
		pending("levels 目录不存在")
		return
	var failed: Array = []
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir() and n.ends_with(".json"):
			var f := FileAccess.open("res://levels/" + n, FileAccess.READ)
			if f == null:
				continue
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Dictionary:
				var r := LevelValidator.validate_structure(parsed)
				if not bool(r["ok"]):
					failed.append("%s: %s" % [n, r["reason"]])
		n = d.get_next()
	d.list_dir_end()
	assert_eq(failed.size(), 0, "所有关卡应结构合法：%s" % str(failed))


# ==================== R07 固定雷数 ====================

func test_r07_default_mines() -> void:
	assert_eq(LevelSpec.default_mines_for_size(Vector2i(5, 5)), 10)
	assert_eq(LevelSpec.default_mines_for_size(Vector2i(6, 6)), 14)
	assert_eq(LevelSpec.default_mines_for_size(Vector2i(7, 7)), 20)
	assert_eq(LevelSpec.default_mines_for_size(Vector2i(8, 8)), 26)
	assert_eq(LevelSpec.default_mines_for_size(Vector2i(9, 9)), -1, "9×9 不在 R07 规格内")
	assert_eq(LevelSpec.default_mines_for_size(Vector2i(5, 4)), -1, "非正方形不在规格内")
