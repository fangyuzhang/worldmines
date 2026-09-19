# batch_merge.gd —— 合并多进程分片产物（batch_generate.gd 的配套脚本）
# 把 out_dir/shard_*/*.json 汇总到 out_dir/ 顶层，按难度档全局编号，
# 并聚合各分片 report.json 输出总报告。
#
# 用法（命令行，-- 后为 out_dir）：
#   godot --headless --path . -s res://tools/batch_merge.gd -- user://batch40
#
# 产出：out_dir/<tier>_NN.json（全局编号）+ out_dir/merged_report.json + 删除已合并的分片子目录。
extends SceneTree

# 可靠退出：见 cli_shutdown.gd 顶部注释（Godot 4.7.2 mono 在本工程 quit() 后间歇性不退出）。
const CliShutdown := preload("res://tools/cli_shutdown.gd")

var _out_dir := "user://batch_levels"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1 and args[0] != "":
		_out_dir = args[0]

	# 收集所有分片
	var shards := _list_shards()
	if shards.is_empty():
		print("未找到分片产物（%s/shard_*），先跑 batch_generate.gd（带 shard 参数）" % _out_dir)
		CliShutdown.request_exit(1)
		return

	# 汇总各分片的关卡 + 统计
	# 四档缺一不可：曾漏掉 "intro"，而同文件下方的遍历按四档走、`if by_tier.has(tier)` 一挡
	# → **intro 关在合并阶段被静默丢弃**（2026-09-19 架构审计发现）。档位名单应与
	# core/difficulty.gd 的 TIERS 同源，勿手写。下面 agg 的 tiers 计数同理（同一事故的第二处）。
	var by_tier := {"intro": [], "easy": [], "normal": [], "hard": []}
	var agg := {"total": 0, "ok": 0, "fail": 0, "dup": 0, "cross_dup": 0,
		"tiers": {"intro": 0, "easy": 0, "normal": 0, "hard": 0}, "elapsed_ms": 0}
	var seen := {}  # 跨分片去重：不同 seed 撞出同一盘时只留第一次出现

	for shard in shards:
		var files := _list_json("%s/shard_%02d" % [_out_dir, shard])
		for f in files:
			var data: Variant = _load_json(f)
			if not (data is Dictionary):
				continue
			var fp := _fingerprint(data)
			if seen.has(fp):
				agg["cross_dup"] += 1
				continue  # 跨分片重复盘（仅小棋盘理论可能；大棋盘概率≈0），跳过
			seen[fp] = true
			var tier := str(data.get("name", "").split("_", false)[0])
			if by_tier.has(tier):
				by_tier[tier].append(data)
		# 聚合统计
		var rep: Dictionary = _load_json("%s/shard_%02d/report.json" % [_out_dir, shard])
		if not rep.is_empty():
			var st: Dictionary = rep.get("stats", {})
			agg["total"] += int(st.get("total", 0))
			agg["ok"] += int(st.get("ok", 0))
			agg["fail"] += int(st.get("fail", 0))
			agg["dup"] += int(st.get("dup", 0))
			agg["elapsed_ms"] += int(st.get("elapsed_ms", 0))
			var ts: Dictionary = st.get("tiers", {})
			for t in ["intro", "easy", "normal", "hard"]:
				agg["tiers"][t] += int(ts.get(t, 0))

	# 全局编号写回顶层
	for tier in by_tier:
		var idx := 1
		for data in by_tier[tier]:
			data["name"] = "%s_%02d" % [tier, idx]
			var f := FileAccess.open("%s/%s_%02d.json" % [_out_dir, tier, idx], FileAccess.WRITE)
			if f != null:
				f.store_string(JSON.stringify(data, "  "))
				f.close()
			idx += 1

	# 总报告
	agg["accept_rate"] = snappedf(float(agg["ok"]) / float(maxi(1, agg["total"])), 0.001)
	var mf := FileAccess.open("%s/merged_report.json" % _out_dir, FileAccess.WRITE)
	if mf != null:
		mf.store_string(JSON.stringify({"out_dir": _out_dir, "shards": shards.size(), "stats": agg}, "  "))
		mf.close()

	print("=== 合并完成 ===")
	print("  分片数: %d" % shards.size())
	print("  总关卡: easy=%d normal=%d hard=%d" % [agg["tiers"]["easy"], agg["tiers"]["normal"], agg["tiers"]["hard"]])
	print("  总尝试: %d | 成功 %d | 失败 %d | 重复 %d | 跨分片去重 %d | 接受率 %.0f%%" % [
		agg["total"], agg["ok"], agg["fail"], agg["dup"], agg["cross_dup"], agg["accept_rate"] * 100.0])
	print("  输出: %s/<tier>_NN.json + merged_report.json" % _out_dir)
	# ASCII 判据（供流水线脚本判定成功）
	print("=== BATCH-MERGE-OK ===")
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)


func _list_shards() -> Array:
	var out: Array = []
	var dir := DirAccess.open(_out_dir)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir() and name.begins_with("shard_"):
			out.append(int(name.substr(6)))
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _list_json(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".json") and name != "report.json":
			out.append(dir_path.path_join(name))
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return data if data is Dictionary else {}


## 关卡指纹：mines 坐标（排序）+ 尺寸 + 雷数（与 batch_generate._fingerprint 同口径）。
## 跨分片去重用：不同 seed 撞出同一盘面时（小棋盘理论可能）视为重复。
func _fingerprint(level: Dictionary) -> String:
	var parts: Array = []
	parts.append("%dx%d-%d" % [int(level["size"]["cols"]), int(level["size"]["rows"]), int(level["total_mines"])])
	var ms: Array = []
	for m in level["mines"]:
		ms.append("%d,%d" % [int(m["c"]), int(m["r"])])
	ms.sort()
	parts.append("|".join(ms))
	return "|".join(parts)
