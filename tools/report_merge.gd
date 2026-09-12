extends SceneTree

## report_merge.gd —— 多分片报告汇总器（v2.9.3）
##
## batch_all_variants 分片模式每进程写各自的 all_report_shard_XX.json——
## 8 份报告人工看不便。本工具合并为一份：统计相加、清单去重合并，
## 输出 <dir>/all_report_merged.json + 终端摘要。
##
## 用法：godot --headless --path . -s res://tools/report_merge.gd -- [dir]
##   dir 默认 user://batch_all
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var dir := str(args[0]) if args.size() >= 1 and str(args[0]) != "" else "user://batch_all"
	var files: Array[String] = []
	var d := DirAccess.open(dir)
	if d != null:
		d.list_dir_begin()
		var n := d.get_next()
		while n != "":
			if not d.current_is_dir() and n.begins_with("all_report") and n.ends_with(".json") \
					and not n.contains("merged"):
				files.append(dir.path_join(n))
			n = d.get_next()
		d.list_dir_end()
	files.sort()
	if files.is_empty():
		print("未找到分片报告：%s" % dir)
		CliShutdown.request_exit(1)
		return
	var agg := {"units": 0, "ok": 0, "partial": 0, "skipped": 0, "design_skip": 0, "resumed": 0,
		"tiers": {"easy": 0, "normal": 0, "hard": 0}}
	var elapsed_max := 0.0
	var design_skip := {}
	var skipped := {}
	var partial := {}
	for f in files:
		var fh := FileAccess.open(f, FileAccess.READ)
		var data: Variant = JSON.parse_string(fh.get_as_text()) if fh != null else null
		if fh != null:
			fh.close()
		if not (data is Dictionary):
			continue
		var r: Dictionary = data
		var st: Dictionary = r.get("stats", {})
		for k in ["units", "ok", "partial", "skipped", "design_skip", "resumed"]:
			agg[k] = int(agg.get(k, 0)) + int(st.get(k, 0))
		var tt: Dictionary = st.get("tiers", {})
		for t in ["easy", "normal", "hard"]:
			agg["tiers"][t] = int(agg["tiers"][t]) + int(tt.get(t, 0))
		elapsed_max = maxf(elapsed_max, float(r.get("elapsed_s", 0.0)))
		for key in ["design_skip", "skipped", "partial"]:
			for item in r.get(key, []):
				if key == "design_skip":
					design_skip[str(item)] = true
				elif key == "skipped":
					skipped[str(item)] = true
				else:
					partial[str(item)] = true
	var ds: Array = design_skip.keys()
	var sk: Array = skipped.keys()
	var pt: Array = partial.keys()
	ds.sort()
	sk.sort()
	pt.sort()
	print("=== 多分片报告汇总（%d 份，运行态统计——各分片本次运行口径相加）===" % files.size())
	print("  单元: %d | 入库 %d 关 | 设计跳过 %d | 数学UNSAT跳过(去重前) %d | 续跑跳过 %d | 部分成功单元 %d" % [
		agg["units"], agg["ok"], agg["design_skip"], agg["skipped"], agg["resumed"], agg["partial"]])
	print("  难度分布(本次运行新增): easy=%d normal=%d hard=%d" % [
		agg["tiers"]["easy"], agg["tiers"]["normal"], agg["tiers"]["hard"]])
	print("  ⚠ 全库权威统计（实际文件扫描）请跑 batch_audit_r07.gd：单元满额/未满 + 全库难度分布")
	if pt.size() > 0:
		print("  未满单元(%d): %s" % [pt.size(), ", ".join(pt.slice(0, 20))])
	if sk.size() > 0:
		print("  UNSAT 单元(%d): %s" % [sk.size(), ", ".join(sk.slice(0, 10))])
	var out := {
		"shards": files.size(), "elapsed_max_s": elapsed_max, "stats": agg,
		"design_skip": ds, "skipped": sk, "partial": pt,
	}
	var f2 := FileAccess.open("%s/all_report_merged.json" % dir, FileAccess.WRITE)
	if f2 != null:
		f2.store_string(JSON.stringify(out, "  "))
		f2.close()
		print("  已写: %s/all_report_merged.json" % dir)
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
