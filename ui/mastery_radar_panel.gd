# mastery_radar_panel.gd —— 解谜者画像（三轴掌握度雷达）
#
# 自绘（H2 口径：本项目界面图形一律自绘，不引入图片资源）：参考三角环 + 数据多边形 + 轴名。
# 右侧是逐轴计数条 + 画像文案；数据全部来自 core/mastery_radar.gd 的纯函数，
# 本文件只负责「怎么显示」，不参与任何判定（判定可离线断言，见 test_mastery_radar.gd）。
#
# ⚠️ 刻意不写 class_name（坑表 #26）。入口：`MasteryRadarPanel.open(host)`。
extends RefCounted


const Shell := preload("res://ui/tool_shell.gd")
const Radar := preload("res://core/mastery_radar.gd")


## 三轴雷达图（自绘）。
class RadarChart extends Control:
	var counts: Dictionary = {}

	func set_counts(c: Dictionary) -> void:
		counts = c
		queue_redraw()

	func _draw() -> void:
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.34
		if radius <= 8.0:
			return
		var font := get_theme_default_font()
		var text_col: Color = ThemeManager.text()
		var accent: Color = ThemeManager.accent()
		# 参考环（三圈）
		for k in [0.34, 0.67, 1.0]:
			var ring := Radar.ring_points(center, radius, float(k))
			var closed := PackedVector2Array()
			for p in ring:
				closed.append(p)
			if ring.size() > 0:
				closed.append(ring[0])
			draw_polyline(closed, Color(text_col, 0.25), 1.0, true)
		# 轴辐条
		for p in Radar.ring_points(center, radius, 1.0):
			draw_line(center, p, Color(text_col, 0.20), 1.0, true)
		# 数据多边形
		var ratios := Radar.ratios(counts)
		var total := 0.0
		for v in ratios:
			total += float(v)
		var poly := Radar.polygon_points(ratios, center, radius)
		if total > 0.0 and poly.size() >= 3:
			draw_colored_polygon(poly, Color(accent, 0.35))
			var outline := PackedVector2Array()
			for p in poly:
				outline.append(p)
			outline.append(poly[0])
			draw_polyline(outline, accent, 2.0, true)
			for p in poly:
				draw_circle(p, 4.0, accent)
		# 轴名
		var ids := Radar.axis_ids()
		var i := 0
		for p in Radar.ring_points(center, radius + 26.0, 1.0):
			if i < ids.size():
				var lb := Radar.axis_name(str(ids[i]))
				var wdt := font.get_string_size(lb, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
				draw_string(font, p - Vector2(wdt * 0.5, 0.0), lb,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 15, text_col)
			i += 1


static func open(host: Control) -> Control:
	var counts := Radar.counts_from_levels(ProgressStore.levels())
	var persona := Radar.persona(counts)
	var sh := Shell.build(host, "解谜者画像",
		"按三轴统计已通关的关卡（一关可以同时计入多条轴）—— 共 %d 关计入" % int(counts["total"]))
	if sh.is_empty():
		return null
	var body: VBoxContainer = sh["body"]

	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 20)
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(split)

	var chart := RadarChart.new()
	chart.name = "RadarChart"
	chart.custom_minimum_size = Vector2(400, 360)
	chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chart.set_meta("radar_chart", true)
	chart.set_counts(counts)
	split.add_child(chart)

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(340, 0)
	right.add_theme_constant_override("separation", 8)
	split.add_child(right)

	var ids := Radar.axis_ids()
	var maxv := 1
	for id in ids:
		maxv = maxi(maxv, int(counts.get(id, 0)))
	for id in ids:
		var c := int(counts.get(id, 0))
		var head := Label.new()
		head.text = "%s  %d 关" % [Radar.axis_name(id), c]
		head.add_theme_font_size_override("font_size", 15)
		right.add_child(head)
		var bar := ProgressBar.new()
		bar.max_value = float(maxv)
		bar.value = float(c)
		bar.custom_minimum_size = Vector2(0, 14)
		bar.set_meta("radar_axis_" + id, true)
		right.add_child(bar)

	if int(counts.get("other", 0)) > 0:
		right.add_child(Shell.note("另有 %d 关不属于任何官方轴席（经典 / 混合代号 / 特殊算子），不计入三轴。"
			% int(counts["other"])))

	right.add_child(Shell.note(""))   # 间隔
	var title := Label.new()
	title.text = str(persona["title"])
	title.add_theme_font_size_override("font_size", 20)
	title.set_meta("persona_title", true)
	right.add_child(title)
	var blurb := Label.new()
	blurb.text = str(persona["blurb"])
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_font_size_override("font_size", 14)
	blurb.set_meta("persona_blurb", true)
	right.add_child(blurb)

	body.add_child(Shell.note(
		"统计口径：只算已通关的关卡；「跳过」不计；同一关同时命中多条轴时会同时计入。"))
	return sh["root"] as Control
