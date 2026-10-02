extends GutTest

## 关卡集（`core/level_sets.gd`）单测：批量生产写它、工坊打包收集它、玩家侧列表读它 ——
## 三处共用的格式只能有一份实现，所以这里把"两种布局都能读出来"钉死：
## 否则老包（`ui/mod_select.gd` 的平铺单关）会变成"装好了却一关都不显示"的静默失败。

const ROOT := "user://test_level_sets"


func before_each() -> void:
	_rmrf(ROOT)


func after_each() -> void:
	_rmrf(ROOT)


## 造一关（难度画像只填档位判据 max_complexity，与真实产出同字段）。
func _lv(peak: int, r := 0, c := 0) -> Dictionary:
	return {
		"size": {"rows": 8, "cols": 8},
		"total_mines": 1,
		"mines": [{"r": r, "c": c}],
		"revealed": [],
		"difficulty_profile": {"max_complexity": peak, "difficulty": 1.0},
	}


func test_write_then_read_round_trips_envelope() -> void:
	var levels := [_lv(2, 1, 1), _lv(3, 2, 2)]
	assert_true(LevelSets.write_set(ROOT + "/levels/8/easy.json", "z1", 8, "easy", levels),
		"写集文件应成功（目录不存在要自动建）")
	var set := LevelSets.read_set(ROOT + "/levels/8/easy.json")
	assert_eq(str(set.get("mode", "")), "z1", "mode 要原样带回来")
	assert_eq(int(set.get("size", 0)), 8, "大小要原样带回来")
	assert_eq(str(set.get("tier", "")), "easy", "档位要原样带回来")
	assert_eq(int(set.get("count", 0)), 2, "count 应等于关卡数")
	assert_eq((set.get("levels", []) as Array).size(), 2, "关卡数组要能读回来")


func test_read_set_rejects_non_set_json() -> void:
	# 单关 json 也是字典，但它没有 levels 数组 ⇒ 必须被判成"不是集文件"，
	# 否则玩家侧会把一个关卡当成"含 0 关的集"，列表静默变空。
	assert_true(LevelSets.write_set(ROOT + "/levels/8/easy.json", "m", 8, "easy", [_lv(2)]),
		"前置：先有一个合法集文件")
	var f := FileAccess.open(ROOT + "/one.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(_lv(2)))
	f.close()
	assert_true(LevelSets.read_set(ROOT + "/one.json").is_empty(), "单关文件不得被当成集文件")
	assert_eq(LevelSets.read_level(ROOT + "/one.json").size() > 0, true, "但单关读取要能读它")


func test_tier_comes_from_profile_and_falls_back() -> void:
	# 档位只认 difficulty_profile（与官方库同口径）
	assert_eq(LevelSets.tier_of_level(_lv(2)), "easy", "峰值 2 ⇒ 普通")
	assert_eq(LevelSets.tier_of_level(_lv(4)), "normal", "峰值 4 ⇒ 困难")
	assert_eq(LevelSets.tier_of_level(_lv(6)), "hard", "峰值 6 ⇒ 噩梦")
	assert_eq(LevelSets.tier_of_level(_lv(1)), "", "峰值 1 不进档 ⇒ 空（调用方自己决定怎么显示）")
	assert_eq(LevelSets.tier_of_level({}, "hard"), "hard", "读不到画像时用 fallback")


func test_collect_reads_both_layouts_and_groups_them() -> void:
	# 真实布局 = `user://mods/<id>/levels/...`（玩家侧就是对这个 levels 目录调 collect）
	var levels_root := ROOT + "/levels"
	# ① 新布局：集文件 <大小>/<档位>.json
	assert_true(LevelSets.write_set(levels_root + "/8/easy.json", "z1", 8, "easy",
		[_lv(2, 1, 1), _lv(3, 2, 2)]), "写 8×8 普通集")
	assert_true(LevelSets.write_set(levels_root + "/9/hard.json", "z1", 9, "hard",
		[_lv(7, 3, 3)]), "写 9×9 噩梦集")
	# ② 老布局：平铺单关 <规则>_<档位>_NN.json（ui/mod_select.gd 既有的产出）
	#    这关**故意不带** difficulty_profile ⇒ 只能靠文件名认档位，否则会掉进 unknown
	var flat := {"size": {"rows": 5, "cols": 5}, "total_mines": 1, "mines": [{"r": 0, "c": 0}], "revealed": []}
	var f := FileAccess.open(levels_root + "/z1_normal_01.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(flat))
	f.close()

	var got := LevelSets.collect(levels_root)
	assert_true(bool(got["ok"]), "collect 应成功：%s" % str(got["reason"]))
	assert_eq(int(got["count"]), 4, "两种布局共 4 关都要数到（漏一种 = 玩家看不到那批）")
	assert_eq(got["sizes"], [5, 8, 9], "大小轴应升序：%s" % str(got["sizes"]))
	var g8: Dictionary = got["groups"]["8"]
	assert_eq((g8["easy"] as Array).size(), 2, "8×8 普通应有 2 关")
	var g9: Dictionary = got["groups"]["9"]
	assert_eq((g9["hard"] as Array).size(), 1, "9×9 噩梦应有 1 关")
	var g5: Dictionary = got["groups"]["5"]
	assert_true(g5.has("normal"), "平铺单关要靠文件名认档位（normal）：%s" % str(g5))
	assert_eq(int(got["per_tier"].get("easy", 0)), 2, "per_tier 统计要对")
	assert_eq(int(got["per_size"].get("8", 0)), 2, "per_size 统计要对")


func test_collect_reports_missing_dir_instead_of_silence() -> void:
	# 目录不存在必须**说出来**：玩家侧如果静默返回空，界面就成了"这个 Mod 没有关卡"（骗人）
	var got := LevelSets.collect("user://definitely_not_here_%d" % randi())
	assert_false(bool(got["ok"]), "目录不存在应 ok=false")
	assert_true(str(got["reason"]).find("目录不存在") != -1, "要给得出人话原因：%s" % str(got["reason"]))
	assert_eq(int(got["count"]), 0, "数量仍为 0")


func test_materialize_writes_a_playable_single_file() -> void:
	var lv := _lv(2, 3, 4)
	var path := LevelSets.materialize(lv, "8_easy_01", ROOT + "/play")
	assert_true(path != "", "物化应返回路径")
	assert_true(FileAccess.file_exists(path), "物化文件要真的存在：%s" % path)
	var back := LevelSets.read_level(path)
	assert_eq((back.get("mines", []) as Array).size(), 1, "物化后关卡内容要一致（玩家点的就是它）")
	# 再物化一次必须**覆盖**（宁可多写一次，也不让玩家玩到过期数据）
	lv["total_mines"] = 2
	assert_eq(LevelSets.materialize(lv, "8_easy_01", ROOT + "/play"), path, "同名应覆盖同一路径")
	assert_eq(int(LevelSets.read_level(path).get("total_mines", 0)), 2, "内容要更新")


func test_group_label_uses_the_single_tier_wording_source() -> void:
	# 档位中文只许有 Difficulty 一个来源（编辑器进度 / 玩家侧组头共用）
	assert_eq(LevelSets.group_label(8, "easy"), "8×8　%s" % Difficulty.tier_short("easy"),
		"组头文案要复用 Difficulty.tier_short，不许另写一份")


func _rmrf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(str(f)))
	for sub in d.get_directories():
		_rmrf(path.path_join(str(sub)))
	DirAccess.remove_absolute(path)
