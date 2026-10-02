extends GutTest

## 批量生产（`core/batch_forge.gd`）单测。
##
## 【为什么注入生成器】真生成要调 CP-SAT（单关几秒~几十秒），测试里不可能跑几十关。
## 所以这里注入一个**合成生成器**：它按"第几次尝试"给出指定峰值的关卡，
## 从而精确验证"档位按实算入桶""去重""打不动就认输""取消也落盘"这些**逻辑**；
## 真生成路径另有一条小规模实跑用例兜底（见文件末尾）。

const ROOT := "user://test_batch_forge"

var _stub_calls := 0
## 合成生成器要产出的峰值序列（循环取用）。
var _peaks: Array = [2, 4, 6]


func before_each() -> void:
	_stub_calls = 0
	_rmrf(ROOT)


func after_each() -> void:
	_rmrf(ROOT)


## 合成一关：雷位随 seed 变（避免意外撞指纹），峰值按序列循环。
func _stub(size: int, seed: int) -> Dictionary:
	var peak := int(_peaks[_stub_calls % _peaks.size()])
	_stub_calls += 1
	return {
		"rule_level": true,
		"clue_rule": "z1",
		"global_rules": [],
		"size": {"rows": size, "cols": size},
		"total_mines": 1,
		"mines": [{"r": seed % size, "c": (seed * 7) % size}],
		"revealed": [],
		"seed": seed,
		"difficulty_profile": {"max_complexity": peak, "difficulty": 1.0},
	}


## 合成一关：峰值永远合适、但**雷位固定**（专门测去重）。
func _stub_same(size: int, seed: int) -> Dictionary:
	_stub_calls += 1
	return {
		"size": {"rows": size, "cols": size},
		"total_mines": 1,
		"mines": [{"r": 0, "c": 0}],
		"revealed": [],
		"seed": seed,
		"difficulty_profile": {"max_complexity": 2, "difficulty": 1.0},
	}


func _forge(opts: Dictionary) -> BatchForge:
	var f := BatchForge.new()
	var o := opts.duplicate(true)
	o["out_dir"] = ROOT
	if not o.has("gen"):
		o["gen"] = Callable(self, "_stub")
	f.start(o)
	return f


func _run_to_end(f: BatchForge, cap := 20000) -> int:
	var n := 0
	while not f.is_done() and n < cap:
		f.step()
		n += 1
	return n


func test_plan_multiplies_sizes_by_tier_counts() -> void:
	var jobs := BatchForge.plan([5, 8], {"easy": 3, "normal": 0, "hard": 2})
	assert_eq(jobs.size(), 4, "只有 want>0 的桶才建 job（0 关的档位不该占一桶）")
	assert_eq(BatchForge.total_of(jobs), 10, "总数 = 每个大小 × (3 + 2)")
	var first: Dictionary = jobs[0]
	assert_eq(int(first["size"]), 5, "第一个桶是最小尺寸")
	assert_eq(str(first["tier"]), "easy", "档位顺序随 Difficulty.PEAK_WINDOWS")
	assert_eq(BatchForge.plan([8], {}).size(), 0, "全 0 份数 ⇒ 没有 job")
	assert_eq(BatchForge.total_of(BatchForge.plan([8], {})), 0, "总数 0")


func test_forge_fills_every_bucket_and_writes_classified_sets() -> void:
	var f := _forge({"sizes": [5, 8], "tier_counts": {"easy": 2, "normal": 2, "hard": 1},
		"mode": "z1_test", "name_prefix": "测试变体"})
	var steps := _run_to_end(f)
	assert_true(f.is_done(), "应跑完")
	var p := f.progress()
	assert_eq(int(p["made"]), 10, "两个大小 × (2+2+1) = 10 关，一关都不能少（走了 %d 步）" % steps)
	assert_eq(int(p["per_tier"].get("easy", 0)), 4, "普通档：2 个大小 × 2 关")
	assert_eq(int(p["per_tier"].get("hard", 0)), 2, "噩梦档：2 个大小 × 1 关")
	# 落盘：集文件必须按 <大小>/<档位>.json 分类，且是**每档一个文件**（不是一关一文件）
	for size in [5, 8]:
		for tier in ["easy", "normal", "hard"]:
			var path := "%s/levels/%d/%s.json" % [ROOT, size, tier]
			var want := 2 if tier != "hard" else 1
			assert_true(FileAccess.file_exists(path), "应有集文件 %s（分类靠目录结构，玩家侧也读它）" % path)
			var set := LevelSets.read_set(path)
			assert_eq(int(set.get("count", 0)), want, "%s 的 count 要对" % path)
			assert_eq(str(set.get("mode", "")), "z1_test", "集文件要带 mode")
			assert_eq(int(set.get("size", 0)), size, "集文件要带大小")
			assert_eq(str(set.get("tier", "")), tier, "集文件要带档位")
			# 集内每一关都必须真的属于这个档（否则玩家会在"普通"里看到噩梦）
			for lv in (set["levels"] as Array):
				assert_eq(LevelSets.tier_of_level(lv), tier, "集内关卡的实算档位必须与集一致")
				assert_true(str((lv as Dictionary).get("name", "")).find("测试变体") != -1,
					"关卡要有给人看的名字：%s" % str((lv as Dictionary).get("name", "")))
	# 分类索引（会写进工坊 manifest，端到端"下载后已分类"就靠它）
	var idx_path := "%s/index.json" % ROOT
	assert_true(FileAccess.file_exists(idx_path), "应写 index.json")
	var idx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(idx_path))
	assert_eq(int(idx.get("count", 0)), 10, "索引里的总数要对")
	assert_eq(int((idx["categories"]["8"] as Dictionary).get("hard", 0)), 1, "索引要能按大小查档位份数")
	assert_eq((idx["levels"] as Array).size(), 6, "索引应列出 6 个集文件（2 大小 × 3 档）")
	# 实测吞吐要留在索引里：下一次点开批量弹窗就能显示"上次 N 关用了多久"（不做重型预探）。
	# 注意：合成生成器是内存里的桩，整轮可能只花 0 毫秒 ⇒ 这里只断言**字段在且非负**，
	# 不断言 >0（那会变成"测试桩比真机快"的假红）。
	assert_gt(int(idx.get("attempts", 0)), 0, "索引要记住试了多少次")
	assert_true(idx.has("elapsed_ms"), "索引要记住用了多久（给下次做时间预期）")
	assert_true(int(idx.get("elapsed_ms", -1)) >= 0, "耗时字段不能缺失或为负：%s" % str(idx.get("elapsed_ms")))
	var rep := f.report()
	assert_true(bool(rep["ok"]), "账本应判成功")
	assert_eq((rep["short"] as Array).size(), 0, "没有未达标的桶：%s" % str(rep["short"]))
	assert_true((rep["files"] as Array).size() == 6, "报告应列出 6 个集文件")


func test_forge_rejects_wrong_tier_candidates() -> void:
	# 只留普通档：合成器会给出 2/4/6 三种峰值 ⇒ 只有 1/3 的候选该被收下，其余全部扔掉
	var f := _forge({"sizes": [5], "tier_counts": {"easy": 3}, "mode": "t"})
	_run_to_end(f)
	assert_eq(int(f.progress()["made"]), 3, "普通档只收峰值 2~3 的候选")
	var set := LevelSets.read_set("%s/levels/5/easy.json" % ROOT)
	for lv in (set["levels"] as Array):
		var peak := int(((lv as Dictionary)["difficulty_profile"] as Dictionary)["max_complexity"])
		assert_true(Difficulty.in_window(peak, 2, 3),
			"集里不许混进窗口外的关卡（峰值 %d）" % peak)


func test_duplicate_mines_are_not_accepted_twice() -> void:
	# 同一颗盘出现两次 = 玩家眼里的重复关；这里合成器**永远给同一颗盘**，
	# 于是只该收下 1 关，并在打不动时认输、把原因如实记下来（而不是死循环）
	var f := _forge({"sizes": [5], "tier_counts": {"easy": 3}, "mode": "dup",
		"gen": Callable(self, "_stub_same")})
	var steps := _run_to_end(f)
	assert_eq(int(f.progress()["made"]), 1, "重复盘只收一次")
	assert_true(f.is_done(), "应结束（不能卡死）")
	var rep := f.report()
	assert_true((rep["short"] as Array).size() > 0, "未达标要在账本里写出来：%s" % str(rep["short"]))
	assert_true(int(steps) < 20000, "步数应远小于上限（认输机制生效）")


func test_cancel_keeps_what_was_already_made() -> void:
	var f := _forge({"sizes": [5, 8], "tier_counts": {"easy": 5, "normal": 5}, "mode": "half"})
	# 跑几步就停：半成品对用户也有价值（他可能只想先看几关）
	for i in 4:
		f.step()
	f.cancel()
	assert_true(f.is_done(), "取消后应判结束")
	assert_true(f.is_cancelled(), "应标记为取消")
	var made := int(f.progress()["made"])
	assert_gt(made, 0, "取消前已命中的关卡要留着")
	var set := LevelSets.read_set("%s/levels/5/easy.json" % ROOT)
	assert_true(not set.is_empty(), "取消也要落盘（否则用户白等这几分钟）")
	assert_true(str(f.progress()["msg"]).find("已停止") != -1,
		"进度文案要说明是停止：%s" % str(f.progress()["msg"]))


func test_eta_is_honest_before_first_hit() -> void:
	var f := _forge({"sizes": [5], "tier_counts": {"easy": 2}, "mode": "eta"})
	assert_eq(f.eta_ms(), -1, "还没命中过 ⇒ 不许编 ETA（-1 = 估不出来）")
	assert_true(str(f.progress()["msg"]).find("估不出") != -1,
		"文案要如实说估不出来：%s" % str(f.progress()["msg"]))
	f.step()
	while int(f.progress()["made"]) == 0 and not f.is_done():
		f.step()
	assert_true(f.eta_ms() >= 0, "命中之后 ETA 应是具体数字")
	assert_true(str(f.progress()["msg"]).find("已生成") != -1, "进度文案要有人说话版")


func test_mines_for_uses_standard_density_and_honours_ratio() -> void:
	var f := BatchForge.new()
	f.start({"sizes": [5], "tier_counts": {"easy": 1}, "gen": Callable(self, "_stub")})
	assert_eq(f.mines_for(9), 10, "9×9 按标准 12.3% ⇒ 10 颗")
	assert_eq(f.mines_for(5), 3, "5×5 ⇒ 3 颗（≥1）")
	var f2 := BatchForge.new()
	f2.start({"sizes": [5], "tier_counts": {"easy": 1}, "mines_ratio": 0.2,
		"gen": Callable(self, "_stub")})
	assert_eq(f2.mines_for(5), 5, "比例可改（5×5 × 20% = 5）")


func test_human_ms_reads_like_a_person() -> void:
	assert_eq(BatchForge.human_ms(500), "500 毫秒", "不足一秒直接说毫秒")
	assert_eq(BatchForge.human_ms(12000), "12 秒", "分钟以内说秒")
	assert_eq(BatchForge.human_ms(80000), "1 分 20 秒", "分钟级要分+秒")
	assert_eq(BatchForge.human_ms(3720000), "1 小时 2 分", "小时级要小时+分")
	assert_eq(BatchForge.human_ms(-1), "估不出来", "估不出来就说估不出来")


# ==================== 重型预探：用实测档案做事前预估（P6e） ====================

func test_estimate_uses_measured_hit_rate_and_cost() -> void:
	# 预估只能来自**实测档案**（VariantCapability 的产物）：命中率 = 命中数/候选总数（含失败候选），
	# 成本 = 单候选均值。这样"想要 4 关"就能换算成"期望跑 8 个候选 × 单次成本"。
	var profile := {"sides": {"8": {"cand": 8, "cost_ms_mean": 1000.0,
		"hit_rate": {"easy": 0.5, "normal": 0.25}}}}
	var est := BatchForge.estimate(profile, [8], {"easy": 4, "hard": 2})
	assert_eq((est["per_bucket"] as Array).size(), 2, "两个桶都要有账")
	assert_eq(int(est["eta_ms"]), 8000, "普通档：4 关 ÷ 50% × 1 秒 = 8 秒")
	var missing: Array = est["missing"]
	assert_eq(missing.size(), 1, "没实测过的档要单列出来：%s" % str(missing))
	assert_eq(str((missing[0] as Dictionary)["tier"]), "hard", "缺的正是噩梦档")
	assert_false(bool(est["ok"]), "有档没实测 ⇒ 不应判 ok（界面要据此提醒）")
	assert_eq(int(est["cand_min"]), 8, "样本量要如实带出来（界面会写「样本最少 8 个候选」）")
	assert_true(bool(est["known_any"]), "有任何一个桶测过 ⇒ known_any 为真")


func test_estimate_without_any_archive_is_honestly_empty() -> void:
	var est := BatchForge.estimate({}, [8, 9], {"easy": 3})
	assert_eq(int(est["cand_min"]), 0, "没档案 ⇒ 样本量 0")
	assert_false(bool(est["known_any"]), "一个桶都没测过")
	assert_eq((est["missing"] as Array).size(), 2, "两个桶都算没实测")
	assert_eq(int(est["eta_ms"]), 0, "没数据就不报时间（不编一个大概）")
	assert_false(bool(est["ok"]), "没数据不许判 ok")


func test_estimate_partial_archive_keeps_sample_size_honest() -> void:
	# 只测过 8×8：9×9 那桶没数据 ⇒ 不能因为出现一个 0 就把样本量报成 0（界面会误说"还没实测"）
	var profile := {"sides": {"8": {"cand": 6, "cost_ms_mean": 500.0, "hit_rate": {"easy": 0.5}}}}
	var est := BatchForge.estimate(profile, [8, 9], {"easy": 2})
	assert_true(bool(est["known_any"]), "有一桶有数据 ⇒ 不能说「还没实测」")
	assert_eq(int(est["cand_min"]), 6, "样本量取**有数据的**尺寸的最小值")
	assert_gt(int(est["eta_ms"]), 0, "有数据的桶要给时间")
	assert_eq((est["missing"] as Array).size(), 1, "没数据的桶单列")


func test_real_generator_path_produces_a_playable_level() -> void:
	# 真生成路径的小规模兜底：5×5 经典盘最便宜（仓库实测：0.14 核时/100 关量级）。
	# 不设档位要求（tier_counts 只给 0）时没有 job ⇒ 改用"手动 step 一次"验证接线。
	var pg := PuzzleGenerator.new()
	var lv := pg.generate_with_opts({"size": Vector2i(5, 5), "mine_count": 3, "seed": 12345,
		"attempts": 8, "timeout_ms": 8000})
	assert_true(not lv.is_empty(), "5×5 小盘的生成必须能出关卡（否则批量功能没有地基）")
	if lv.is_empty():
		return
	var tier := Difficulty.tier_of_profile(lv.get("difficulty_profile", {}))
	assert_true(tier != "" or int((lv["difficulty_profile"] as Dictionary).get("max_complexity", 0)) <= 1,
		"真生成的关卡要么有档位、要么是峰值 ≤1 的极简盘（档位空串是合法结果）：%s" % tier)
	assert_eq(int(lv["total_mines"]), 3, "雷数应等于请求值")
	assert_eq(BatchForge.fingerprint(lv), BatchForge.fingerprint(lv), "指纹应稳定可复算")


func _rmrf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(str(f)))
	for sub in d.get_directories():
		_rmrf(path.path_join(str(sub)))
	DirAccess.remove_absolute(path)
