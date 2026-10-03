# tutorial_expand_boards.gd —— 一次性维护脚本（2026-10-03）
#
# 目的：给 `res://levels/tutorial/*.txt` 这批**静态**教程页补上"一页多盘"（B2 口径：
# 只给一张盘时用户往往只看到一片 0，学不到东西）。
#
# 为什么可以自动补：教程盘面上的数字**必须由该变体的规则算出来**，手写必然出错；
# 而 `RuleLegend.build_pages_for_ids()` 已经是"按规则生成示例盘 + 每张都过裁决器"的那套机器
# （游戏运行时打开教程用的就是它）⇒ 这里**复用**它，一个数字都不手写。
#
# 用法：Godot --headless --path . -s res://tools/tutorial_expand_boards.gd
# 幂等：已经有 `--` 分隔符的文件会被跳过。
extends SceneTree


func _init() -> void:
	var names := DirAccess.get_files_at("res://levels/tutorial")
	var changed := 0
	var skipped := 0
	for n in names:
		var name := str(n)
		if not name.begins_with("tutorial_") or not name.ends_with(".txt"):
			continue
		var path := "res://levels/tutorial/%s" % name
		var src := FileAccess.get_file_as_string(path)
		if src.find("\n--\n") != -1:
			skipped += 1
			continue
		var extra := _extra_boards(_combo_of(name))
		if extra == "":
			skipped += 1
			continue
		var idx := src.find("\n?")
		if idx < 0:
			skipped += 1
			continue
		var out := src.substr(0, idx) + "\n--\n" + extra + src.substr(idx)
		var wf := FileAccess.open(path, FileAccess.WRITE)
		if wf == null:
			skipped += 1
			continue
		wf.store_string(out)
		wf.close()
		# 自检：写回后必须仍能解析，且第一张盘的行数与原来一致（兼容字段不许变）
		var before := Tutorial.parse(src)
		var after := Tutorial.parse(FileAccess.get_file_as_string(path))
		var ok := str(after["error"]) == "" \
			and (after["rows"] as Array).size() == (before["rows"] as Array).size() \
			and (after["boards"] as Array).size() > 1
		print("[expand] %s ⇒ %d 张盘 %s" % [name, (after["boards"] as Array).size(), "OK" if ok else "!! 自检失败"])
		changed += 1
	print("[expand] 完成：改了 %d 个，跳过 %d 个" % [changed, skipped])
	quit()


## `tutorial_<组合>_<序号>.txt` ⇒ `<组合>`（组合里的 `_` 在文件名里就是 `_`，保持原样）。
func _combo_of(file_name: String) -> String:
	var s := file_name.trim_suffix(".txt").trim_prefix("tutorial_")
	var cut := s.rfind("_")
	return s.substr(0, cut) if cut > 0 else s


## 用规则机器造 1~2 张**附加盘**（与首盘用 `--` 分隔）。造不出就返回 ""（宁缺勿错）。
func _extra_boards(combo: String) -> String:
	if combo.is_empty():
		return ""
	var clue := ""
	var globals: Array = []
	for part in combo.replace("+", "_").split("_", false):
		var r: Object = RuleRegistry.default().resolve(StringName(part))
		if r == null:
			continue
		if str(r.call("get_kind")) == RulePlugin.KIND_GLOBAL:
			globals.append(part)
		else:
			clue = part
	if clue == "" and globals.is_empty():
		return ""
	var built: Dictionary = RuleLegend.build_pages_for_ids(combo, clue, globals)
	if not bool(built["ok"]):
		return ""
	var blocks: Array[String] = []
	for p in (built["pages"] as Array):
		var text := str((p as Dictionary).get("text", ""))
		var cut := text.find("\n?")
		var board_text := text.substr(0, cut) if cut >= 0 else text
		if board_text.strip_edges() == "":
			continue
		for b in (Tutorial.parse(board_text)["boards"] as Array):
			var rows: Array = (b as Dictionary)["rows"]
			var lines: Array[String] = []
			for row in rows:
				var cells: Array[String] = []
				for cd in (row as Array):
					var d: Dictionary = cd
					var ann: String = "{%s}" % str((d["annotations"] as Array)[0]) if not (d["annotations"] as Array).is_empty() else ""
					cells.append(ann + str(d["value"]))
				lines.append("\t".join(cells))
			blocks.append("\n".join(lines))
			if blocks.size() >= 2:
				break
		if blocks.size() >= 2:
			break
	if blocks.is_empty():
		return ""
	return "\n--\n".join(blocks)
