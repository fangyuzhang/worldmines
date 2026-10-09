# glyph_font.gd —— 文字 → 字形点阵 → 格集（编辑器「文字转形状」的栅格化层）
#
# 背景：`core/text_to_shape.gd` 的 `text_to_cells(text, font_mask, scale, grid, origin)` 早就在，
# 但全仓**没有**产出 `font_mask` 的那一层 —— 于是「文字转形状」在 UI 上一直没法接通
# （用户视角等于没有这个功能）。本模块补的就是这一层。
#
# 【为什么用**仓库自带字体**而不是系统字体】文档 §8「字体陷阱」写得很明确：依赖本机字体 ⇒
# 别人没装同一个字体，重新生成的结果就变了。本模块只读 `res://assets/fonts/WenYuanRoundedSCVF.ttf`
# （就是 `ThemeDB.fallback_font`，随包发布、版本固定）⇒ 同文本 + 同像素高度 ⇒ 逐格相同结果，
# 跨机器可复现。栅格化产物最后**固化进结果层**（`_write_board_shape` 把格集写回关卡），
# 字体只作参考 —— 与文档要求的落盘口径一致。
#
# 【为什么不用 `Font.draw_string` + Viewport 截图】那条路要真渲染管线（headless 下拿不到像素，
# 测试没法钉住结果）。本模块走 `TextServer` 的字形图集：`font_render_glyph` → 图集 `Image` →
# 按 UV 裁剪 → 按 alpha 阈值出点阵。**纯 CPU、headless 可跑、可单测**（实测 Godot 4.7.2 可用）。
#
# 【点阵口径：与 ShapeGenerator.build_from_mask 同源】
#   有格 = "#"，空 = "." —— 与 `ShapeGenerator.MASK_FILLED` / `MASK_EMPTY` 的字母表一致
#   （"#" 在 FILLED 集合里，"." 在 EMPTY 集合里）。本模块不另立字母表，也不碰那个常量。
#
# 【策略：能拒绝就拒绝，绝不静默降级】
#   · 字体里没有的字符（如生僻字 / emoji）⇒ 整体拒绝并列名，不悄悄跳过；
#   · 空格：`TextToShape._glyph_rows` 要求「至少一个填充格」（全空点阵不成形状）⇒ 空格无法作为
#     字形表达。本模块**剔除空格并记账**（ignored_spaces），由 UI 明确告知用户，
#     不假装它还在（字符间距另有 `TextToShape.GLYPH_GAP_CELLS`）。
#   · 多行：本模块只吃单行（`\n` / `\t` ⇒ 拒绝），避免"换行静默变成一串糊在一起的格"。
class_name GlyphFont
extends RefCounted

const TTS := preload("res://core/text_to_shape.gd")

## 唯一支持的字体（随包发布，版本固定 ⇒ 跨机器可复现；见文件头）。
const DEFAULT_FONT_PATH := "res://assets/fonts/WenYuanRoundedSCVF.ttf"

## 像素高度上下限：下限 3（再小没有任何笔画能成格），上限 96（再大只是把一张大图切成几格，
## 徒增内存；真正决定棋盘尺寸的是"每像素几格"这一档 scale，不是这里）。
const MIN_PX := 3
const MAX_PX := 96

## 单次最多几个字符：防手滑粘一整段（每个字符都要走一遍字形图集）。
const MAX_CHARS := 16

const FILLED := "#"
const EMPTY := "."


## 把 `text` 按 `cell_px` 像素高度栅格化成 `font_mask`（口径见 `TextToShape.text_to_cells`）。
##
## 返回：
##   {ok: bool, font_mask: Dictionary, reason: String,
##    cell_px: int, ignored_spaces: int, chars: int, glyph_px: Dictionary}
##   · ok=true  ⇒ font_mask 非空，且每个字形点阵都过 `TextToShape._glyph_rows` 的同款校验；
##   · ok=false ⇒ font_mask = {}，reason 可读（空文本 / 多行 / 像素高度越界 / 字符数超限 /
##                字体缺字 / 字体加载失败 / 图集取不到）。
## 纯函数（同一字体 + 同一输入 ⇒ 逐位相同输出）：不写盘、不读全局设置、不做随机。
static func mask_for(text: String, cell_px: int, font_path: String = DEFAULT_FONT_PATH) -> Dictionary:
	if text.strip_edges().is_empty():
		return _fail("文字为空：先输入要转成形状的文字")
	if text.contains("\n") or text.contains("\r") or text.contains("\t"):
		return _fail("多行文字暂不支持：请一次只转一行（换行 / 制表符会被拆成互不相连的形状）")
	if cell_px < MIN_PX or cell_px > MAX_PX:
		return _fail("像素高度必须在 %d~%d 之间（收到 %d）" % [MIN_PX, MAX_PX, cell_px])

	# 空格无法作为字形表达（见文件头）⇒ 剔除并记账，由调用方告知用户。
	var chars: Array[String] = []
	var ignored_spaces := 0
	for ch in text:
		if ch == " ":
			ignored_spaces += 1
			continue
		chars.append(ch)
	if chars.is_empty():
		return _fail("文字里只有空格：空格不成形状")
	if chars.size() > MAX_CHARS:
		return _fail("一次最多 %d 个字符（收到 %d）：先转短一点的文字，或用「批量生成」逐块摆" % [
			MAX_CHARS, chars.size()])

	var font := _load_font(font_path)
	if font == null:
		return _fail("字体加载失败：%s 不是可用的字体资源" % font_path)
	var rids: Array = font.get_rids()
	if rids.is_empty():
		return _fail("字体没有可用的字形图集（%s）：TextServer 没能为它建出 size cache" % font_path)
	var rid: RID = rids[0]
	var ts: TextServer = TextServerManager.get_primary_interface()
	if ts == null:
		return _fail("取不到 TextServer：字形栅格化需要 TextServer 主接口")

	var mask: Dictionary = {}
	var glyph_px: Dictionary = {}
	var size := Vector2i(cell_px, 0)
	for ch in chars:
		if mask.has(ch):
			continue
		var gi: int = int(ts.call("font_get_glyph_index", rid, cell_px, ch.unicode_at(0), 0))
		if gi == 0:
			return _fail("字体里没有这个字符「%s」：换一个字符，或改用「手绘轮廓」（生僻字 / emoji 常缺字形）" % ch)
		# 先渲染进图集，再按 UV 裁剪（顺序不能反：没渲染过时取不到有效 UV）。
		ts.call("font_render_glyph", rid, size, gi)
		var uv: Rect2 = ts.call("font_get_glyph_uv_rect", rid, size, gi)
		if uv.size.x < 1.0 or uv.size.y < 1.0:
			return _fail("字形「%s」栅格化失败：TextServer 返回的图集区域为空（%.1f×%.1f）" % [
				ch, uv.size.x, uv.size.y])
		var tex_idx: int = int(ts.call("font_get_glyph_texture_idx", rid, size, gi))
		var img: Image = ts.call("font_get_texture_image", rid, size, tex_idx)
		if img == null:
			return _fail("字形「%s」栅格化失败：拿不到图集图像（texture_idx=%d）" % [ch, tex_idx])
		var rect := Rect2i(Vector2i(int(uv.position.x), int(uv.position.y)),
			Vector2i(int(uv.size.x), int(uv.size.y)))
		var rows: Array = _crop_to_mask(img, rect)
		if rows.is_empty():
			return _fail("字形「%s」栅格化后没有笔画（像素高度 %d 太小？）" % [ch, cell_px])
		mask[ch] = rows
		glyph_px[ch] = {"w": rect.size.x, "h": rect.size.y}

	return {
		"ok": true,
		"font_mask": mask,
		"reason": "",
		"cell_px": cell_px,
		"ignored_spaces": ignored_spaces,
		"chars": chars.size(),
		"glyph_px": glyph_px,
	}


## 「自动适配盘面」：从 `start_px` 起**只往下试**（每次 1 像素），直到 `TextToShape.text_to_cells`
## 接受为止。越界的判据、拒绝的理由全部来自 `TextToShape`（单一事实来源），本函数只负责降档重试。
##
## 返回 `TextToShape.text_to_cells` 的结果，另附：
##   · used_px  : int  实际用上的像素高度（== start_px 表示一次就成功）；
##   · shrunk   : bool 是否缩小过（UI 必须把这件事说出来，不许静默缩）；
##   · attempts : int  试了几档；
##   · reason   : 全部档位都失败时，**最小档位**的理由（最有解释力的一条）。
static func text_cells_fit(text: String, grid: GridInterface, origin: Vector2i,
		start_px: int, min_px: int = MIN_PX) -> Dictionary:
	var hi := clampi(start_px, MIN_PX, MAX_PX)
	var lo := clampi(min_px, MIN_PX, hi)
	var attempts := 0
	var last_reason := ""
	var first_fail_reason := ""
	for px in range(hi, lo - 1, -1):
		attempts += 1
		var m := mask_for(text, px)
		if not bool(m["ok"]):
			# 栅格化层面的错（缺字 / 多行 / 空格…）与尺寸无关 ⇒ 立刻返回，不必把每档都试一遍。
			return {
				"ok": false, "cells": {}, "reason": str(m["reason"]),
				"used_px": px, "shrunk": false, "attempts": attempts,
				"ignored_spaces": int(m.get("ignored_spaces", 0)), "font_mask_ok": false,
			}
		var r: Dictionary = TTS.text_to_cells(text.replace(" ", ""), m["font_mask"], 1, grid, origin)
		if bool(r["ok"]):
			return {
				"ok": true, "cells": r["cells"], "reason": "",
				"used_px": px, "shrunk": px != hi, "attempts": attempts,
				"ignored_spaces": int(m["ignored_spaces"]), "font_mask_ok": true,
			}
		if first_fail_reason == "":
			first_fail_reason = str(r["reason"])
		last_reason = str(r["reason"])
	var why := last_reason if last_reason != "" else first_fail_reason
	if why == "":
		why = "文字放不进这块盘面：把像素高度调到 %d 以下，或先换一块更大的盘" % lo
	return {
		"ok": false, "cells": {}, "reason": why,
		"used_px": lo, "shrunk": true, "attempts": attempts,
		"ignored_spaces": 0, "font_mask_ok": true,
	}


# ============================== 内部 ==============================

static func _load_font(font_path: String) -> FontFile:
	if not ResourceLoader.exists(font_path):
		return null
	var res: Resource = load(font_path)
	if res is FontFile:
		return res as FontFile
	if res is Font:
		# FontVariation / 系统字体等：取它自己的 rids 也能跑，但本模块只声明支持 FontFile。
		return null
	return null


## 把图集里的 `rect` 裁成点阵行（alpha ≥ 0.5 记有格）。裁到空 / 越界 ⇒ 返回空数组（调用方报可读原因）。
static func _crop_to_mask(img: Image, rect: Rect2i) -> Array:
	var out: Array = []
	var w := rect.size.x
	var h := rect.size.y
	if w <= 0 or h <= 0:
		return out
	for y in h:
		var row := ""
		for x in w:
			var px := Vector2i(rect.position.x + x, rect.position.y + y)
			var ink := false
			if px.x >= 0 and px.y >= 0 and px.x < img.get_width() and px.y < img.get_height():
				ink = img.get_pixel(px.x, px.y).a >= 0.5
			row += FILLED if ink else EMPTY
		out.append(row)
	# 全空行（字形的上下留白）留着没问题，但**整块全空**要报出去（调用方靠空数组判"没有笔画"）。
	var any_ink := false
	for r: String in out:
		if r.contains(FILLED):
			any_ink = true
			break
	if not any_ink:
		return []
	return out


static func _fail(reason: String) -> Dictionary:
	return {
		"ok": false, "font_mask": {}, "reason": reason,
		"cell_px": 0, "ignored_spaces": 0, "chars": 0, "glyph_px": {},
	}
