extends GutTest

# test_level_loader_limits.gd —— 审计 H2/L4 回归：恶意/损坏关卡 JSON 的资源上限。
#
# 几百字节的 JSON 声明超大 rows×cols 曾能让 Board 网格分配打爆内存（导入的 mod 关卡
# 与未来工坊关卡完全不受信任）。上限常量见 ui/level_loader.gd（MAX_CELLS / MAX_FILE_BYTES）。
#
# 注意：被拒路径会 push_error（预期行为）。若 GUT 把它记为「Unexpected Error」误报，
# 把 gut_config.json 的 failure_error_types 移除 "push_error" 即可——与本测试的断言无关。

const DIR := "user://test_ll_limits"


func after_each() -> void:
	var d := DirAccess.open(DIR)
	if d != null:
		for f in d.get_files():
			DirAccess.remove_absolute(DIR.path_join(str(f)))
		DirAccess.remove_absolute(DIR)


func _write_level(name: String, text: String) -> String:
	DirAccess.make_dir_recursive_absolute(DIR)
	var p := DIR.path_join(name)
	var f := FileAccess.open(p, FileAccess.WRITE)
	assert_true(f != null, "测试准备：应能写入 " + p)
	if f != null:
		f.store_string(text)
		f.close()
	return p


## 数百字节的 JSON 声明 1 亿格 → 必须被 MAX_CELLS 拦截，返回 null（不得触发网格分配/OOM）。
func test_oversized_grid_rejected() -> void:
	var p := _write_level("huge.json",
			'{"name":"bomb","size":{"rows":100000,"cols":100000},"total_mines":0,"mines":[],"revealed":[]}')
	var b = LevelLoader.load_level(p)
	assert_null(b, "超大尺寸关卡应被 MAX_CELLS 拦截")


## 上限边缘内的正常关卡不受影响（25 格，远小于 64×64）。
func test_normal_level_still_loads() -> void:
	var p := _write_level("ok.json",
			'{"name":"ok","size":{"rows":5,"cols":5},"total_mines":0,"mines":[],"revealed":[{"r":0,"c":0}]}')
	var b = LevelLoader.load_level(p)
	assert_not_null(b, "正常小关卡不受上限影响")


## 超长雷位数组（> MAX_CELLS）→ 拒绝。
func test_mine_list_too_long_rejected() -> void:
	var mines := []
	for i in 5000:
		mines.append({"r": i % 80, "c": int(i / 80.0) % 80})
	var p := _write_level("longmines.json",
			'{"name":"x","size":{"rows":80,"cols":80},"total_mines":5000,"mines":'
			+ JSON.stringify(mines) + ',"revealed":[]}')
	var b = LevelLoader.load_level(p)
	assert_null(b, "超长雷位数组应被拦截")
