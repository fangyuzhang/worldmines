# test_creator_hub.gd —— 创作中心：本地版本登记 + 反馈包双向交换
#
# 硬约束（用户口径）：「没有服务器、也不打算租」。所以这里**没有**任何网络断言 ——
# 全部用例只碰 file:// 与 user:// 两个本地路径；反馈包的「传递」由玩家/作者自己完成。
extends GutTest

const Hub := preload("res://core/creator_hub.gd")


func _tmp(tag: String) -> String:
	return "user://test_hub_%s_%d_%d.json" % [tag, Time.get_ticks_usec(), randi()]


func _drop(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_slug() -> void:
	assert_eq(Hub.slug("My Puzzle Pack"), "my-puzzle-pack", "空格转短横线")
	assert_eq(Hub.slug("Hello_World"), "hello-world", "下划线也转短横线")
	assert_eq(Hub.slug("  "), "pack", "空标题给默认 id")
	assert_eq(Hub.slug("Pack-"), "pack", "末尾短横线要去掉")


func test_publish_then_update_versions() -> void:
	var path := _tmp("pub")
	var v1 := Hub.publish("My Pack", "首版：10 关", "user://pack.zip", path, 1000)
	assert_eq(int(v1["version"]), 1, "首次登记应是 v1")
	assert_eq(int(v1["published_at"]), 1000, "时间戳应写入")
	assert_eq((v1["history"] as Array).size(), 1, "历史应含 1 条")

	var v2 := Hub.publish("My Pack", "修了第 3 关的判定", "user://pack2.zip", path, 2000)
	assert_eq(int(v2["version"]), 2, "再次登记应是 v2")
	assert_eq(str(v2["notes"]), "修了第 3 关的判定", "最新变更说明应更新")
	assert_eq(str(v2["pack_file"]), "user://pack2.zip", "新包路径应更新")
	assert_eq((v2["history"] as Array).size(), 2, "历史应累积到 2 条")
	assert_eq(Hub.list_packs(path).size(), 1, "同一个 slug 只应有一条作品")
	_drop(path)


func test_publish_two_distinct_packs() -> void:
	var path := _tmp("two")
	Hub.publish("Alpha", "a", "", path, 1)
	Hub.publish("Beta", "b", "", path, 2)
	assert_eq(Hub.list_packs(path).size(), 2, "不同标题应为两条作品")
	var s := Hub.stats(path)
	assert_eq(int(s["packs"]), 2, "统计作品数")
	assert_eq(int(s["versions"]), 2, "统计版本数")
	_drop(path)


func test_feedback_roundtrip() -> void:
	var path := _tmp("fb")
	var out := _tmp("fbfile")
	Hub.publish("My Pack", "首版", "", path, 1000)
	assert_true(Hub.export_feedback_pack("my-pack", "小明", 4, "第 3 关有点难", out, 1, 5000),
		"导出反馈包应成功")
	var r := Hub.import_feedback(out, path)
	assert_true(bool(r["ok"]), "导入应成功：%s" % str(r["error"]))
	assert_eq(str((r["entry"] as Dictionary)["tester"]), "小明", "反馈人应被记录")
	var fb := Hub.feedback_of("my-pack", path)
	assert_eq(fb.size(), 1, "作品下应挂 1 条反馈")
	assert_almost_eq(Hub.average_rating("my-pack", path), 4.0, 0.001, "平均分应为 4")
	_drop(path)
	_drop(out)


func test_import_rejects_bad_inputs() -> void:
	var path := _tmp("bad")
	var f := _tmp("badfile")
	Hub.publish("My Pack", "首版", "", path, 1)

	assert_eq(str(Hub.import_feedback("user://definitely_missing_hub.json", path)["error"]),
		"missing", "缺文件应报 missing")

	var fh := FileAccess.open(f, FileAccess.WRITE)
	fh.store_string("{ 这不是 JSON")
	fh.close()
	assert_eq(str(Hub.import_feedback(f, path)["error"]), "bad_json", "坏 JSON 应报 bad_json")

	fh = FileAccess.open(f, FileAccess.WRITE)
	fh.store_string(JSON.stringify({"kind": "something_else"}))
	fh.close()
	assert_eq(str(Hub.import_feedback(f, path)["error"]), "bad_kind", "非反馈包应报 bad_kind")

	fh = FileAccess.open(f, FileAccess.WRITE)
	fh.store_string(JSON.stringify({"kind": Hub.FEEDBACK_KIND, "pack_id": ""}))
	fh.close()
	assert_eq(str(Hub.import_feedback(f, path)["error"]), "bad_id", "缺作品 id 应报 bad_id")

	fh = FileAccess.open(f, FileAccess.WRITE)
	fh.store_string(JSON.stringify({"kind": Hub.FEEDBACK_KIND, "pack_id": "nope"}))
	fh.close()
	assert_eq(str(Hub.import_feedback(f, path)["error"]), "unknown_pack", "本地没有该作品应报 unknown_pack")
	assert_eq(Hub.feedback_of("my-pack", path).size(), 0, "失败的导入不得留下反馈")
	_drop(path)
	_drop(f)


func test_import_tolerates_missing_store() -> void:
	var path := _tmp("nostore")
	var out := _tmp("only")
	Hub.export_feedback_pack("ghost", "tester", 3, "hi", out, 1, 1)
	assert_eq(str(Hub.import_feedback(out, path)["error"]), "unknown_pack",
		"存档不存在时按「没有这个作品」处理，不得报错")
	_drop(out)


func test_remove_pack() -> void:
	var path := _tmp("rm")
	Hub.publish("Gone", "x", "", path, 1)
	assert_true(Hub.remove_pack("gone", path), "删除已登记作品应成功")
	assert_eq(Hub.list_packs(path).size(), 0, "删除后应为空")
	assert_false(Hub.remove_pack("gone", path), "再删应返回 false")
	_drop(path)


func test_average_rating_without_feedback() -> void:
	var path := _tmp("empty")
	Hub.publish("Empty", "x", "", path, 1)
	assert_almost_eq(Hub.average_rating("empty", path), -1.0, 0.001, "无反馈返回 -1")
	_drop(path)


func test_load_data_tolerates_broken_file() -> void:
	var path := _tmp("broken")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[1, 2, 3]")
	f.close()
	var d := Hub.load_data(path)
	assert_true(d.get("packs") is Array, "坏档应退回空表结构")
	assert_eq((d["packs"] as Array).size(), 0, "坏档不得凭空造出作品")
	_drop(path)
