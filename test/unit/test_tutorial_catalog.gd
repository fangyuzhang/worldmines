# test_tutorial_catalog.gd —— 教学树：分章 / 顺序 / 软解锁 / 进度
#
# 注意：本用例读的是 **res://levels/tutorial 下的真实文件**（教学树的成员就是从文件推导的），
# 所以断言写成「下界 + 关键页存在」而不是写死 42 ——新增教学页不该把用例打红。
extends GutTest

const TutTree := preload("res://core/tutorial_catalog.gd")
const TProg := preload("res://core/tutorial_progress.gd")


func test_chapters_are_nonempty_and_ordered() -> void:
	var ch := TutTree.chapters()
	assert_gte(ch.size(), 5, "至少 5 章（基础/经典/观测/结构/守恒/复合）")
	var idx := 0
	for c in ch:
		idx += 1
		assert_eq(int(c["index"]), idx, "章序号应从 1 连续")
		assert_ne(str(c["name"]), "", "章要有名称")
		assert_ne(str(c["desc"]), "", "章要有一句话说明")
		assert_gt((c["pages"] as Array).size(), 0, "空章不应出现在列表里")


func test_flatten_covers_all_axis_seats() -> void:
	var flat := TutTree.flatten()
	assert_gte(flat.size(), 40, "全树至少 40 页（实测 42）")
	for id in ["tutorial_basics_0", "tutorial_classic_0", "tutorial_o1_0",
			"tutorial_o10_0", "tutorial_s7_0", "tutorial_z5_0"]:
		assert_true(flat.has(id), "全树应包含 %s" % id)


func test_chapter_of() -> void:
	assert_eq(TutTree.chapter_of("tutorial_o1_0"), "observe", "o1 属观测章")
	assert_eq(TutTree.chapter_of("tutorial_s3_0"), "structure", "s3 属结构章")
	assert_eq(TutTree.chapter_of("tutorial_z2_0"), "conserve", "z2 属守恒章")
	assert_eq(TutTree.chapter_of("tutorial_basics_0"), "basics", "basics 属第 1 章")
	assert_eq(TutTree.chapter_of("tutorial_nope_0"), "", "未知页无章")


func test_soft_unlock_chain() -> void:
	var seen := {}
	var ch := TutTree.chapters()
	assert_true(TutTree.is_chapter_unlocked(str(ch[0]["id"]), seen), "第 1 章永远解锁")
	assert_false(TutTree.is_chapter_unlocked(str(ch[1]["id"]), seen), "读过第 1 章之前，第 2 章锁着")
	# 看过第 1 章任意一页 → 第 2 章解锁（软门：不要求读完）
	var first_page := str((ch[0]["pages"] as Array)[0])
	seen[first_page] = true
	assert_true(TutTree.is_chapter_unlocked(str(ch[1]["id"]), seen), "看过上一章 1 页即解锁下一章")
	assert_false(TutTree.is_chapter_unlocked("no_such_chapter", seen), "未知章不解锁")


func test_progress_and_next_page() -> void:
	var seen := {}
	var p := TutTree.progress(seen)
	assert_eq(int(p["seen"]), 0, "未读时为 0")
	assert_gte(int(p["total"]), 40, "总页数应与全树一致")
	assert_eq((p["chapters"] as Array).size(), TutTree.chapters().size(), "逐章进度条数应一致")

	var first := TutTree.next_page(seen)
	assert_eq(first, TutTree.flatten()[0], "下一课应是全树第一页")

	for id in TutTree.flatten():
		seen[id] = true
	assert_eq(TutTree.next_page(seen), "", "全部读完后没有下一课")
	assert_eq(int(TutTree.progress(seen)["seen"]), int(TutTree.progress(seen)["total"]), "读满后进度相等")


func test_chapter_progress_counts() -> void:
	var seen := {}
	var pages := TutTree.pages_of_chapter("conserve")
	assert_gte(pages.size(), 5, "守恒章至少 5 页")
	seen[pages[0]] = true
	var p := TutTree.chapter_progress("conserve", seen)
	assert_eq(int(p["seen"]), 1, "只读了 1 页")
	assert_eq(int(p["total"]), pages.size(), "总数 = 该章页数")


func test_subtitle_comes_from_page_text() -> void:
	var s := TutTree.subtitle_of("tutorial_o1_0")
	assert_ne(s, "", "教学页应能给出一行副标题")
	assert_lt(s.length(), 80, "副标题应被截断到一行长度")
	assert_eq(TutTree.subtitle_of("tutorial_no_such_page"), "", "缺页返回空（不得报错）")


func test_tutorial_progress_store_persists() -> void:
	# 教学进度与关卡进度是两套存档：这里只验证「标记 → 读回」这条路。
	TProg.reset_cache()
	var before := TProg.count()
	var fresh := "tutorial_unit_probe_%d" % randi()
	assert_true(TProg.mark_seen(fresh), "首次标记应返回 true")
	assert_false(TProg.mark_seen(fresh), "重复标记应返回 false")
	assert_true(TProg.is_seen(fresh), "应能读回已读状态")
	assert_eq(TProg.count(), before + 1, "已读计数 +1")
	assert_true(TProg.seen().has(fresh), "seen() 集合应含该页")
	# 清理：把探针页从存档里移除（避免污染真实进度）
	var d := {"version": 1, "seen": []}
	for id in TProg.seen().keys():
		if str(id) != fresh:
			(d["seen"] as Array).append(str(id))
	var f := FileAccess.open(TProg.PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "  "))
	f.close()
	TProg.reset_cache()
