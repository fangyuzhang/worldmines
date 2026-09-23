extends SceneTree

## O1 产物分析：档位/难度统计 + 盘面多样性（重复 + Jaccard 峰值）+ issues 事件汇总。
## 用法：godot --headless --path . -s res://tools/_analyze_o1.gd -- <root_dir>
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var root := str(args[0]) if args.size() >= 1 else "res://_staged_levels/o1_batch_20260914"
	print("=== 分析根目录: %s ===" % root)
	for combo_dir in DirAccess.get_directories_at(root):
		var cd := root.path_join(combo_dir)
		for side_dir in DirAccess.get_directories_at(cd):
			var t0 := Time.get_ticks_msec()
			_analyze_dir(cd.path_join(side_dir))
			print("  [done %s %s in %.1fs]" % [combo_dir, side_dir, (Time.get_ticks_msec() - t0) / 1000.0])
	for combo_dir in DirAccess.get_directories_at(root):
		_issues_summary(root.path_join(combo_dir), combo_dir)
	print("=== ANALYZE_DONE ===")
	CliShutdown.request_exit(0)


func _list_json(dir_path: String) -> Array:
	var out: Array = []
	for f in DirAccess.get_files_at(dir_path):
		if str(f).ends_with(".json"):
			out.append(str(f))
	return out


func _load(p: String) -> Dictionary:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var v: Variant = JSON.parse_string(txt)
	return v if v is Dictionary else {}


func _mset(lv: Dictionary) -> Dictionary:
	var s := {}
	for m in lv.get("mines", []):
		s[Vector2i(int(m["c"]), int(m["r"]))] = true
	return s


func _fp(lv: Dictionary) -> String:
	var arr: Array = []
	for m in lv.get("mines", []):
		arr.append("%d,%d" % [int(m["c"]), int(m["r"])])
	arr.sort()
	return "|".join(arr)


func _jac(a: Dictionary, b: Dictionary) -> float:
	var inter := 0
	for p in a:
		if b.has(p):
			inter += 1
	var uni: int = a.size() + b.size() - inter
	return float(inter) / float(uni) if uni > 0 else 0.0


func _analyze_dir(dir_path: String) -> void:
	var files := _list_json(dir_path)
	if files.is_empty():
		return
	var by_tier := {"easy": [], "normal": [], "hard": []}
	var seen := {"easy": {}, "normal": {}, "hard": {}}
	var dup := 0
	for f in files:
		var bn := str(f).get_basename()
		var tier := "easy"
		if bn.begins_with("normal_"):
			tier = "normal"
		elif bn.begins_with("hard_"):
			tier = "hard"
		var lv := _load(dir_path.path_join(f))
		if lv.is_empty():
			continue
		var diff := float((lv.get("difficulty_profile", {}) as Dictionary).get("difficulty", 0.0))
		by_tier[tier].append({"f": f, "d": diff, "lv": lv})
		var fp := _fp(lv)
		if (seen[tier] as Dictionary).has(fp):
			dup += 1
		else:
			(seen[tier] as Dictionary)[fp] = true
	print("=== %s：%d 关（重复盘 %d）===" % [dir_path.get_file(), files.size(), dup])
	for tier in ["intro", "easy", "normal", "hard"]:
		var arr: Array = by_tier[tier]
		if arr.is_empty():
			continue
		var dmin := INF
		var dmax := -INF
		var dsum := 0.0
		var msets: Array = []
		for it in arr:
			dmin = minf(dmin, float(it["d"]))
			dmax = maxf(dmax, float(it["d"]))
			dsum += float(it["d"])
			msets.append(_mset(it["lv"]))
		var peak := 0.0
		var over := 0
		var pairs := 0
		# Jaccard 抽样：每档最多取前 40 关（全量对在 GDScript 太慢；抽样峰值代表性足够）
		var sample_n: int = mini(msets.size(), 40)
		for i in sample_n:
			for j in range(i + 1, sample_n):
				var jv := _jac(msets[i], msets[j])
				pairs += 1
				if jv > peak:
					peak = jv
				if jv > 0.85:
					over += 1
		print("  %s: %d 关 | 难度 %.2f~%.2f (avg %.2f) | Jaccard 峰值 %.3f（抽样 %d 关/%d 对）| >0.85 对 %d" % [
			tier, arr.size(), dmin, dmax, dsum / float(arr.size()), peak, sample_n, pairs, over])


func _issues_summary(combo_dir: String, name: String) -> void:
	var p := combo_dir.path_join("issues.jsonl")
	if not FileAccess.file_exists(p):
		print("=== issues %s:（无文件——单元未完成或未写）===" % name)
		return
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return
	var counts: Dictionary = {}
	var unit_done: Dictionary = {}
	var total := 0
	while not f.eof_reached():
		var line := f.get_line()
		if line.strip_edges() == "":
			continue
		var v: Variant = JSON.parse_string(line)
		if not (v is Dictionary):
			continue
		total += 1
		var t := str(v.get("t", ""))
		counts[t] = int(counts.get(t, 0)) + 1
		if t == "unit_done":
			unit_done[str(v.get("side", 0))] = v
	f.close()
	print("=== issues %s：%d 行 ===" % [name, total])
	var parts: Array = []
	for k in counts:
		parts.append("%s=%d" % [k, counts[k]])
	print("  " + ", ".join(parts))
	for sd in unit_done:
		var u: Dictionary = unit_done[sd]
		print("  side=%s: made=%s by_tier=%s tried=%s tier_empty=%s full_stall=%s cost=%.0fs" % [
			sd, str(u.get("made")), str(u.get("by_tier")), str(u.get("tried")),
			str(u.get("tier_empty")), str(u.get("full_stall")), float(u.get("cost_s", 0.0))])
