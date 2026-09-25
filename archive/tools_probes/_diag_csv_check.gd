extends SceneTree

# 临时诊断：取代码侧事实，供与桌面「关卡集总表.csv」核对。
# SceneTree 没有 get_tree()，等帧用 `await process_frame`（SceneTree 自带信号）。

func _init() -> void:
	await process_frame
	await process_frame
	var out: Array[String] = []
	out.append('SIZES=%s' % str(LevelSequence.SIZES))
	out.append('MINE_COUNTS=%s' % str(LevelSequence.MINE_COUNTS))
	out.append('OBS=%s' % str(VariantAxes.OBS))
	out.append('STRUCT=%s' % str(VariantAxes.STRUCT))
	out.append('CONSERVE=%s' % str(VariantAxes.CONSERVE))
	out.append('is_available(o1)=%s' % str(VariantCatalog.is_available('o1')))
	# 官方中文名（VariantCatalog.display_name）—— 供核对文档用词是否与代码一致
	out.append('--- display_name ---')
	out.append('classic=%s' % str(VariantCatalog.display_name('classic')))
	for id in VariantAxes.OBS:
		out.append('%s=%s' % [str(id), str(VariantCatalog.display_name(str(id)))])
	for id in VariantAxes.STRUCT:
		out.append('%s=%s' % [str(id), str(VariantCatalog.display_name(str(id)))])
	for id in VariantAxes.CONSERVE:
		out.append('%s=%s' % [str(id), str(VariantCatalog.display_name(str(id)))])
	for s in LevelSequence.SIZES:
		var m: int = int(LevelSequence.MINE_COUNTS[s])
		out.append('size=%d mixed=%d gg=%d conserved=%d' % [
			s,
			VariantCatalog.mixed_all(Vector2i(s, s), m).size(),
			VariantCatalog.gg_all(Vector2i(s, s), m).size(),
			VariantCatalog.conserved_all(Vector2i(s, s), m).size()])
	# 单算子逐尺寸可行性：线索算子 = query(id, [], s, m)；结构/守恒 = query("", [id], s, m)
	for id in VariantAxes.OBS:
		var line := 'OBS %s:' % id
		for s in LevelSequence.SIZES:
			var m: int = int(LevelSequence.MINE_COUNTS[s])
			var ok: bool = RuleFeasibility.query(str(id), [], s, m)
			line += ' %d=%s' % [s, 'Y' if ok else 'N']
		out.append(line)
	for id in VariantAxes.STRUCT:
		var line := 'STRUCT %s:' % id
		for s in LevelSequence.SIZES:
			var m: int = int(LevelSequence.MINE_COUNTS[s])
			var ok: bool = RuleFeasibility.query('', [str(id)], s, m)
			line += ' %d=%s' % [s, 'Y' if ok else 'N']
		out.append(line)
	for id in VariantAxes.CONSERVE:
		var line := 'CONSERVE %s:' % id
		for s in LevelSequence.SIZES:
			var m: int = int(LevelSequence.MINE_COUNTS[s])
			var ok: bool = RuleFeasibility.query('', [str(id)], s, m)
			line += ' %d=%s' % [s, 'Y' if ok else 'N']
		out.append(line)
	var txt := '\n'.join(out)
	var f := FileAccess.open('user://csv_check_out.txt', FileAccess.WRITE)
	if f != null:
		f.store_string(txt)
		f.close()
	print(txt)
	quit()
