# gen_style_shape_levels.gd —— 「形状风格」异形关生成工具（离线 CLI）
#
# 运行： godot --headless --path . -s res://tools/gen_style_shape_levels.gd [-- 族名]
#       族名 ∈ grid / hex / t488 / warp / variant（不传 = 全部）
# 产出： res://levels/sty_*.json
#
# 设计思想（对标 Tametsi 的形状谱系）：「每关看起来全新，构造却同源」——
# **邻接图不变，只变几何与配色**。几何变换按「作用域」分三层，可任意叠加：
#   ① 盘面形变（对**世界坐标**做非线性映射，格心与顶点一起动）——
#      · taper  梯形/扇面：x 随 y 线性缩（上窄下宽）
#      · persp  透视：以顶部中心为消失点，越往下格子越大（两轴同时缩）
#      · arch   拱形：y 按 |x| 上拱（上下缘成弧）
#   ② 逐格旋转（spiral 涡流）：每格绕**自己的格心**转，角度随「到盘心距离」变化
#      ——格心不动、只转朝向 ⇒ 涡旋纹理（Tametsi 无此款，是我们在同一套数据上多走的一步）
#   ③ 尺寸因子（shrink）：<1 留缝（0.95，Tametsi 口径）/ >1 **故意重叠**（叠瓦，BOX·缩放叠格思路）
#
# 形状族（拓扑 + 基础多边形）：
#   grid  6×6 满格（Moore 8 邻）：4 顶点方块
#   hex   蜂窝盘（6 邻）：6 顶点六边形（与渲染层 hex_polygon_px 同式）
#   t488  截角正方形镶嵌（八角 + 菱形填隙）：等边密铺，几何自洽——
#         切角 a = 1/(2+√2) ⇒ 直边 1−2a = a√2 = 菱形边长（菱形旋转 45° 填在四角之间）。
#         八边形在偶数坐标 (2c,2r)、菱形在奇数坐标 (2c+1,2r+1)（与 ShapeGenerator.build_t488 同拓扑）。
#
# ⚠️ 生成走第一帧 _process（不是 _initialize）：规则/CP-SAT 由 autoload 装配（同
#    gen_variant_shape_levels.gd 注释）。
extends SceneTree

const EXIT_FRAMES := 3
const OUT_DIR := "res://levels"
const LEVEL_LOADER_PATH := "res://ui/level_loader.gd"
const ATTEMPTS := 30
const MAX_TRIES := 8
const MAX_MINES_BUMP := 3
const GEN_TIMEOUT_MS := 60000
const MIN_PEAK := 1

const SQ2 := 1.4142135623730951
const SQ3 := 1.7320508075688772
## 尺寸因子（默认 1.0 = **相邻格严格贴合、零可见缝**）。
## 设计规范（2026-09-21）：同一连通区域内相邻格子之间**不允许**出现可见空隙 ——
## 玩家必须能一眼看出哪些格子是连通的；不同区域之间才允许有间隔。
##   · 1.0 = 贴合（所有生成关卡用这个）
##   · >1  = 故意重叠（叠瓦风格；重叠不属于「空隙」，合规）
##   · <1（如 Tametsi 原版的 0.95 收缩）会引入 5% 缝 ⇒ **不用于我们的生成关卡**
##     （复刻原版关卡时保留原版收缩，那是「原版长什么样」的事实，不属于本工具的产出）
const SHRINK := 1.0

## 9 色提示族的亮档（Tametsi 原版值，见 ColorPresets_palette.md）。
const COLORS := {
	"RED": [216, 40, 37], "ORANGE": [234, 139, 37], "YELLOW": [218, 210, 0],
	"GREEN": [112, 214, 55], "BLUE": [82, 179, 255], "INDIGO": [69, 69, 234],
	"VIOLET": [144, 0, 234], "PINK": [234, 51, 234],
}
const PALETTE_BASE := {
	"background": [20, 0, 35],
	"tile": [127, 127, 127],
	"tile_border": [200, 200, 200],
	"tile_highlight": [255, 255, 255],
	"flagged_tile": [230, 230, 230],
	"revealed": [51, 51, 51],
	"revealed_text": [255, 255, 255],
}

## 规格：形状族 × 几何变换 × 配色 × （可选）S/Z 轴全局约束。
##   kind     : "grid" / "hex" / "t488"（t488 用 size）
##   taper/persp/arch : 盘面形变（见文件头）
##   spiral   : 度/环（逐格旋转；正值逆时针）
##   shrink   : 尺寸因子（默认 1.0 = 不留缝；<1 会引入**缝**，见文件头 ③ 与常量区的
##               禁止说明；>1 = 叠瓦）
##   rot/scale/xf/aspect : 整体线性变换（一次性作用于所有格）
##   colors   : 两色组名；pattern: rings/checker/stripes/quad
##   globals  : S/Z 轴约束 id（缺省 = 纯 classic）
const SPECS: Array = [
	# ================= 第一批：基础几何变形（12 关，已交付） =================
	{"file": "sty_sq_plain.json", "kind": "grid", "name": "方格 01 · 素方",
		"desc": "6×6 正方形 · 环层双色", "colors": ["BLUE", "PINK"], "pattern": "rings", "seed": 21001},
	{"file": "sty_sq_diamond.json", "kind": "grid", "name": "方格 02 · 菱格",
		"desc": "菱形（整格旋转 45°）· 交错双色", "rot": 45.0, "scale": SQ2,
		"colors": ["GREEN", "ORANGE"], "pattern": "checker", "seed": 21011},
	{"file": "sty_sq_para.json", "kind": "grid", "name": "方格 03 · 斜格",
		"desc": "平行四边形（横切 0.5）· 横带双色", "xf": [1.0, 0.5, 0.0, 1.0],
		"colors": ["VIOLET", "YELLOW"], "pattern": "stripes", "seed": 21021},
	{"file": "sty_sq_para2.json", "kind": "grid", "name": "方格 04 · 陡斜格",
		"desc": "平行四边形（纵切 0.55）· 象限双色", "xf": [1.0, 0.0, 0.55, 1.0],
		"colors": ["RED", "INDIGO"], "pattern": "quad", "seed": 21031},
	{"file": "sty_sq_wide.json", "kind": "grid", "name": "方格 05 · 宽砖",
		"desc": "拉长矩形（宽 1.5×，面积守恒）· 环层双色", "aspect": 1.5,
		"colors": ["ORANGE", "BLUE"], "pattern": "rings", "seed": 21041},
	{"file": "sty_sq_tall.json", "kind": "grid", "name": "方格 06 · 立砖",
		"desc": "拉长矩形（高 1.45×，面积守恒）· 横带双色", "aspect": 0.69,
		"colors": ["PINK", "GREEN"], "pattern": "stripes", "seed": 21051},
	{"file": "sty_hex_plain.json", "kind": "hex", "size": 5, "name": "蜂窝 06 · 素巢",
		"desc": "正六边形 · 环层双色", "colors": ["BLUE", "VIOLET"], "pattern": "rings", "seed": 22001},
	{"file": "sty_hex_flat.json", "kind": "hex", "size": 5, "name": "蜂窝 07 · 扁巢",
		"desc": "压扁六边形（高 0.72×）· 交错双色", "aspect": 0.72,
		"colors": ["GREEN", "PINK"], "pattern": "checker", "seed": 22011},
	{"file": "sty_hex_tall.json", "kind": "hex", "size": 5, "name": "蜂窝 08 · 高巢",
		"desc": "拉长六边形（高 1.35×）· 横带双色", "aspect": 1.35,
		"colors": ["ORANGE", "INDIGO"], "pattern": "stripes", "seed": 22021},
	{"file": "sty_hex_lean.json", "kind": "hex", "size": 5, "name": "蜂窝 09 · 斜巢",
		"desc": "斜切六边形（横切 0.35）· 环层双色", "xf": [1.0, 0.35, 0.0, 1.0],
		"colors": ["YELLOW", "VIOLET"], "pattern": "rings", "seed": 22031},
	{"file": "sty_hex_big.json", "kind": "hex", "size": 7, "name": "蜂窝 10 · 大素巢",
		"desc": "正六边形（size 7）· 环层双色", "colors": ["RED", "BLUE"], "pattern": "rings", "seed": 22041},
	{"file": "sty_hex_bigflat.json", "kind": "hex", "size": 7, "name": "蜂窝 11 · 大扁巢",
		"desc": "压扁六边形（size 7，高 0.75×）· 象限双色", "aspect": 0.75,
		"colors": ["PINK", "YELLOW"], "pattern": "quad", "seed": 22051},

	# ================= 第二批：盘面形变 + 涡流 + 叠瓦（8 关） =================
	{"file": "sty_sq_trapez.json", "kind": "grid", "name": "方格 07 · 梯形",
		"desc": "梯面（x 随行渐缩 0.5）· 环层双色", "taper": 0.5,
		"colors": ["BLUE", "ORANGE"], "pattern": "rings", "seed": 23001},
	{"file": "sty_sq_persp.json", "kind": "grid", "name": "方格 08 · 透视",
		"desc": "透视（顶部中心为消失点，下大上小 0.55）· 横带双色", "persp": 0.55,
		"colors": ["GREEN", "VIOLET"], "pattern": "stripes", "seed": 23011},
	{"file": "sty_sq_arch.json", "kind": "grid", "name": "方格 09 · 拱格",
		"desc": "拱形（y 随 |x| 上拱 0.35）· 交错双色", "arch": 0.35,
		"colors": ["RED", "YELLOW"], "pattern": "checker", "seed": 23021},
	{"file": "sty_sq_spiral.json", "kind": "grid", "name": "方格 10 · 涡格",
		"desc": "涡流（每环转 14°）· 环层双色", "spiral": 14.0,
		"colors": ["PINK", "INDIGO"], "pattern": "rings", "seed": 23031},
	{"file": "sty_sq_spiral2.json", "kind": "grid", "name": "方格 11 · 强涡",
		"desc": "涡流（每环转 -26°）+ 轻微透视 · 象限双色", "spiral": -26.0, "persp": 0.25,
		"colors": ["ORANGE", "BLUE"], "pattern": "quad", "seed": 23041},
	{"file": "sty_sq_overlap.json", "kind": "grid", "name": "方格 12 · 叠瓦",
		"desc": "故意重叠（1.18×，叠瓦效果）· 横带双色", "shrink": 1.18,
		"colors": ["VIOLET", "YELLOW"], "pattern": "stripes", "seed": 23051},
	{"file": "sty_hex_spiral.json", "kind": "hex", "size": 5, "name": "蜂窝 12 · 涡巢",
		"desc": "涡流（每环转 18°）· 环层双色", "spiral": 18.0,
		"colors": ["BLUE", "GREEN"], "pattern": "rings", "seed": 23061},
	{"file": "sty_hex_fan.json", "kind": "hex", "size": 5, "name": "蜂窝 13 · 扇巢",
		"desc": "扇面（x 随行渐缩 0.55）+ 涡流 8° · 交错双色", "taper": 0.55, "spiral": 8.0,
		"colors": ["ORANGE", "PINK"], "pattern": "checker", "seed": 23071},

	# ================= T488 族：八角 + 菱形填隙（4 关） =================
	{"file": "sty_t488_a.json", "kind": "t488", "size": 3, "name": "八角 01 · 素嵌",
		"desc": "截角正方形镶嵌（八角 + 菱形）· 环层双色", "colors": ["BLUE", "ORANGE"], "pattern": "rings", "seed": 24001},
	{"file": "sty_t488_b.json", "kind": "t488", "size": 3, "name": "八角 02 · 深浅嵌",
		"desc": "同族换色 · 交错双色", "colors": ["GREEN", "PINK"], "pattern": "checker", "seed": 24011},
	{"file": "sty_t488_c.json", "kind": "t488", "size": 4, "name": "八角 03 · 宽嵌",
		"desc": "同族大盘（size 4）· 象限双色", "colors": ["VIOLET", "YELLOW"], "pattern": "quad", "seed": 24021},
	{"file": "sty_t488_d.json", "kind": "t488", "size": 3, "name": "八角 04 · 涡嵌",
		"desc": "同族 + 涡流（每环转 20°）· 横带双色", "spiral": 20.0,
		"colors": ["RED", "INDIGO"], "pattern": "stripes", "seed": 24031},

	# ================= 第三批：变体规则 × 形状风格（5 关） =================
	{"file": "sty_var_1.json", "kind": "grid", "name": "菱格 · 不行",
		"desc": "S1「不行」× 菱形格 · 交错双色", "rot": 45.0, "scale": SQ2, "globals": ["s1"],
		"colors": ["GREEN", "ORANGE"], "pattern": "checker", "seed": 25001},
	{"file": "sty_var_2.json", "kind": "grid", "name": "涡格 · 散散",
		"desc": "S3「散散」× 涡流格（14°/环）· 环层双色", "spiral": 14.0, "globals": ["s3"],
		"colors": ["PINK", "INDIGO"], "pattern": "rings", "seed": 25011},
	{"file": "sty_var_3.json", "kind": "hex", "size": 5, "name": "扁巢 · 步步",
		"desc": "Z2「步步」× 压扁六边形 · 交错双色", "aspect": 0.72, "globals": ["z2"],
		"colors": ["GREEN", "PINK"], "pattern": "checker", "seed": 25021},
	{"file": "sty_var_4.json", "kind": "hex", "size": 5, "name": "斜巢 · 连排",
		"desc": "S5「连排」× 斜切六边形 · 横带双色", "xf": [1.0, 0.35, 0.0, 1.0], "globals": ["s5"],
		"colors": ["YELLOW", "VIOLET"], "pattern": "stripes", "seed": 25031},
	{"file": "sty_var_5.json", "kind": "t488", "size": 3, "name": "八角 · 骨牌",
		"desc": "骨牌 × 截角正方形镶嵌 · 环层双色", "globals": ["dt"],
		"colors": ["ORANGE", "BLUE"], "pattern": "rings", "seed": 25041},

	# ================= 第四批：补齐各变体的形状覆盖（2026-09-21） =================
	# 目标：**每个可用变体 ≥ 3 种异形棋盘**，让「先选变体、再选棋盘」的两级浏览每层都有内容。
	# ⚠️ 变体 × 形状的可行性不是全全组合（实测：s4/s6 在挖洞方格上生成不出，
	# 详见 gen_variant_shape_levels.gd 头注释）——本批逐条实测，失败项不落盘、下次调整。
	{"file": "sty_var_6.json", "kind": "grid", "name": "菱格 · 稳稳",
		"desc": "S2「稳稳」× 菱形格 · 交错双色", "rot": 45.0, "scale": SQ2, "globals": ["s2"],
		"colors": ["BLUE", "GREEN"], "pattern": "checker", "seed": 26001},
	{"file": "sty_var_7.json", "kind": "t488", "size": 3, "name": "八角 · 稳稳",
		"desc": "S2「稳稳」× 截角正方形镶嵌 · 环层双色", "globals": ["s2"],
		"colors": ["ORANGE", "GREEN"], "pattern": "rings", "seed": 26011},
	{"file": "sty_var_8.json", "kind": "t488", "size": 3, "name": "八角 · 层层",
		"desc": "S4「层层」× 截角正方形镶嵌 · 环层双色", "globals": ["s4"],
		"colors": ["RED", "BLUE"], "pattern": "rings", "seed": 26021},
	{"file": "sty_var_9.json", "kind": "grid", "name": "菱格 · 层层",
		"desc": "S4「层层」× 菱形格 · 交错双色", "rot": 45.0, "scale": SQ2, "globals": ["s4"],
		"colors": ["VIOLET", "GREEN"], "pattern": "checker", "seed": 26031},
	{"file": "sty_var_10.json", "kind": "t488", "size": 3, "name": "八角 · 偶偶",
		"desc": "S6「偶偶」× 截角正方形镶嵌 · 环层双色", "globals": ["s6"],
		"colors": ["YELLOW", "INDIGO"], "pattern": "rings", "seed": 26041},
	{"file": "sty_var_11.json", "kind": "grid", "name": "菱格 · 偶偶",
		"desc": "S6「偶偶」× 菱形格 · 交错双色", "rot": 45.0, "scale": SQ2, "globals": ["s6"],
		"colors": ["PINK", "ORANGE"], "pattern": "checker", "seed": 26051},
	{"file": "sty_var_12.json", "kind": "grid", "name": "菱格 · 块块",
		"desc": "S7「块块」× 菱形格 · 交错双色", "rot": 45.0, "scale": SQ2, "globals": ["s7"],
		"colors": ["BLUE", "PINK"], "pattern": "checker", "seed": 26061},
	{"file": "sty_var_13.json", "kind": "t488", "size": 3, "name": "八角 · 块块",
		"desc": "S7「块块」× 截角正方形镶嵌 · 环层双色", "globals": ["s7"],
		"colors": ["GREEN", "VIOLET"], "pattern": "rings", "seed": 26071},
]

var _exit_code := 0
var _exit_pending := false
var _exit_frames := 0
var _started := false
var _fail := 0
var _ok := 0


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()          # autoload 就绪后才跑（规则/CP-SAT 装配时机，见文件头）
		return false
	if not _exit_pending:
		return false
	_exit_frames += 1
	if _exit_frames < EXIT_FRAMES:
		return false
	quit(_exit_code)
	return true


func _run() -> void:
	var want := _selected_families()
	print("=== 形状风格 异形关生成 ===")
	var todo: Array = []
	for spec: Dictionary in SPECS:
		if want.is_empty() or want.has(_family_of(spec)):
			todo.append(spec)
	print("  规格 %d / %d 关（clue=classic；峰值要求 ≥ %d）" % [todo.size(), SPECS.size(), MIN_PEAK])
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var t_all := Time.get_ticks_msec()
	for spec: Dictionary in todo:
		if _gen_one(spec):
			_ok += 1
		else:
			_fail += 1
	print("=== 完成：成功 %d / 失败 %d，耗时 %.1f s ===" % [
		_ok, _fail, float(Time.get_ticks_msec() - t_all) / 1000.0])
	if _fail > 0:
		print("=== STYLE-SHAPE-FAILED ===")
		_request_exit(1)
		return
	print("=== STYLE-SHAPE-OK ===")
	_request_exit(0)


## 族过滤（命令行 `-- grid,hex,t488,warp,variant`）：变体族 = 带 globals 的规格。
func _family_of(spec: Dictionary) -> String:
	if spec.has("globals"):
		return "variant"
	if spec.has("taper") or spec.has("persp") or spec.has("arch") or spec.has("spiral") \
			or float(spec.get("shrink", SHRINK)) > 1.0:
		return "warp"
	return str(spec["kind"])


func _selected_families() -> Array:
	var out: Array = []
	for a in OS.get_cmdline_user_args():
		var s := str(a).strip_edges().to_lower()
		if s != "":
			out.append(s)
	return out


func _gen_one(spec: Dictionary) -> bool:
	var file_name := str(spec["file"])
	var path := OUT_DIR + "/" + file_name
	var kind := str(spec["kind"])
	# 1. 拓扑：grid = 6×6 满格（Moore 8 邻）；hex = build_hex(size)；t488 = build_t488(size)
	var topo: AdjacencyGrid
	match kind:
		"grid":
			topo = ShapeGenerator.to_adjacency_grid("holed_grid", {"rows": 6, "cols": 6, "holes": []})
		"hex":
			topo = ShapeGenerator.to_adjacency_grid("hex", {"size": int(spec.get("size", 5))})
		_:
			topo = ShapeGenerator.to_adjacency_grid("t488", {"size": int(spec.get("size", 3))})
	if topo == null:
		push_error("%s: 拓扑构建失败" % file_name)
		return false
	topo = AdjacencyGrid.normalized(topo)

	# 2. 几何：逐格多边形（盘面形变 → 涡流扭转 → 尺寸因子）
	#    两遍：先求「全盘顶点均值」作为涡流扭转中心（扭转是全局坐标场），再逐格生成。
	var bounds := _world_bounds(kind, topo, spec)
	var sum_v := Vector2.ZERO
	var cnt := 0
	for p: Vector2i in topo.all_positions():
		for v: Vector2 in _warped_poly(kind, p, spec, bounds):
			sum_v += v
			cnt += 1
	var spiral_c := sum_v / maxf(float(cnt), 1.0)
	var cells_geo: Array = []
	for p: Vector2i in topo.all_positions():
		cells_geo.append({"pos": p, "poly": _cell_poly(kind, p, spec, bounds, spiral_c)})

	# 3. 生成（内建 R01）→ 峰值验收 → ProofLog 复核
	var globals: Array = spec.get("globals", [])
	var n := topo.cell_count()
	var mines := maxi(1, int(round(float(n) * 0.3)))
	var gen := PuzzleGenerator.new()
	var level: Dictionary = {}
	var used_mines := 0
	var best_peak := -1
	var tries := 0
	for b in MAX_MINES_BUMP + 1:
		for t in MAX_TRIES:
			tries += 1
			var cand: Dictionary = gen.generate_with_rules(
					"classic", globals, topo.size(), mines + b, int(spec["seed"]) + t, 0, ATTEMPTS,
					topo, GEN_TIMEOUT_MS)
			if cand.is_empty():
				continue
			var prof: Dictionary = cand.get("difficulty_profile", {})
			best_peak = maxi(best_peak, int(prof.get("max_complexity", -1)))
			if int(prof.get("max_complexity", 0)) < MIN_PEAK:
				continue
			if not _proof_ok(cand):
				continue
			level = cand
			used_mines = mines + b
			break
		if not level.is_empty():
			break
	if level.is_empty():
		push_error("%s: %d 次尝试无一达到峰值 ≥ %d（最高 %d）" % [file_name, tries, MIN_PEAK, best_peak])
		return false

	# 4. 落盘
	level["name"] = str(spec["name"])
	level["desc"] = str(spec["desc"])
	level["shape_kind"] = "风格棋盘" if globals.is_empty() else "变体风格"
	level["custom_shapes"] = _custom_shapes(kind, cells_geo, str(spec["colors"][0]),
			str(spec["colors"][1]), str(spec["pattern"]), topo)
	var pal := PALETTE_BASE.duplicate(true)
	var cs: Array = spec["colors"]
	pal["groups"] = {str(cs[0]): COLORS[str(cs[0])], str(cs[1]): COLORS[str(cs[1])]}
	level["palette"] = pal

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("%s: 无法写入 %s" % [file_name, path])
		return false
	f.store_string(JSON.stringify(level, "  "))
	f.close()

	# 5. 自校验
	var board: Board = _load_level(path)
	if board == null or not board.has_meta("custom_shapes"):
		push_error("%s: 自校验失败（载入 %s / custom_shapes meta）" % [
			file_name, "null" if board == null else "ok"])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return false
	var prof2: Dictionary = level.get("difficulty_profile", {})
	print("  OK   %-22s %-16s %d 格 · %d 雷 · 峰值 %s%s · %d 次" % [
		file_name, str(spec["name"]), n, used_mines, str(prof2.get("max_complexity", "?")),
		"" if globals.is_empty() else " · 规则 %s" % str(globals), tries])
	return true


## 世界包围盒（供 taper/persp/arch 归一化用；只按基础形状的粗略范围，够用即可）。
func _world_bounds(kind: String, topo: AdjacencyGrid, spec: Dictionary) -> Rect2:
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for p: Vector2i in topo.all_positions():
		for v: Vector2 in _base_poly(kind, p, spec):
			lo = Vector2(minf(lo.x, v.x), minf(lo.y, v.y))
			hi = Vector2(maxf(hi.x, v.x), maxf(hi.y, v.y))
	return Rect2(lo, hi - lo)


## 基础多边形（世界坐标，未经盘面形变/扭转/尺寸因子）。
##   grid：格心 (c+0.5, r+0.5)，4 角 ±0.5
##   hex ：格心 (0.75(x+y), √3/4(x−y))，6 顶点外接半径 0.475（与渲染层同式）
##   t488：偶数坐标 = 八角（单位方形切角 a）；奇数坐标 = 菱形填隙（顶点距心 a）
##
## ⚠️ 线性变换（rot/scale/xf/aspect）必须作用在**盘面坐标**上（`xf * (格心 + 偏移)`），
## **不能**只作用于「顶点偏移」（`格心 + xf * 偏移`）——后者格心不动、格子被单独压扁，
## 相邻格之间会裂出大小不均的缝（实测：大素巢/扁巢/宽砖 都因此出现可见空隙）。
## 作用在盘面坐标上是**全局仿射变换**：共享边的两个端点仍映射到同一位置 ⇒ 密铺严格保持。
func _base_poly(kind: String, pos: Vector2i, spec: Dictionary) -> Array:
	var out: Array = []
	var xf := _linear_xf(spec)
	if kind == "grid":
		var c := Vector2(float(pos.x) + 0.5, float(pos.y) + 0.5)
		for corner: Vector2 in [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5)]:
			out.append(xf * (c + corner))
	elif kind == "hex":
		var c2 := Vector2(0.75 * float(pos.x + pos.y), SQ3 / 4.0 * float(pos.x - pos.y))
		for i in 6:
			var a := TAU * float(i) / 6.0 + PI / 6.0
			out.append(xf * (c2 + Vector2(cos(a), sin(a)) * 0.475))
	else:
		var ca := 1.0 / (2.0 + SQ2)          # 切角：直边 1−2a == a√2（等边）
		var c3 := Vector2(float(pos.x) * 0.5, float(pos.y) * 0.5)
		if pos.x % 2 == 0 and pos.y % 2 == 0:
			var h := 0.5
			for v: Vector2 in [Vector2(-h + ca, -h), Vector2(h - ca, -h), Vector2(h, -h + ca),
					Vector2(h, h - ca), Vector2(h - ca, h), Vector2(-h + ca, h),
					Vector2(-h, h - ca), Vector2(-h, -h + ca)]:
				out.append(xf * (c3 + v))
		else:
			# 菱形填隙：顶点在轴向（±a, 0）/（0, ±a）——与四邻八角的斜边严格贴合
			for v2: Vector2 in [Vector2(-ca, 0.0), Vector2(0.0, -ca), Vector2(ca, 0.0), Vector2(0.0, ca)]:
				out.append(xf * (c3 + v2))
	return out


## 整体线性变换（rot/scale 或 aspect 或显式 xf）——一次性作用于所有格。
func _linear_xf(spec: Dictionary) -> Transform2D:
	var xf := Transform2D()
	if spec.has("rot"):
		xf = Transform2D(deg_to_rad(float(spec["rot"])),
				Vector2(float(spec.get("scale", 1.0)), float(spec.get("scale", 1.0))))
	if spec.has("aspect"):
		var a := float(spec["aspect"])
		xf = Transform2D(Vector2(a, 0), Vector2(0, 1.0 / a), Vector2.ZERO)
	if spec.has("xf"):
		var m: Array = spec["xf"]
		xf = Transform2D(Vector2(float(m[0]), float(m[2])), Vector2(float(m[1]), float(m[3])), Vector2.ZERO)
	return xf


## 逐格多边形 = 基础形（含整体线性变换）→ 盘面形变 → 涡流扭转 → 尺寸因子。
## ⚠️ 除最后一层「尺寸因子」外，全部是**坐标函数**：相邻格共享边上的点被映射到同一位置，
## 密铺严格保持 ⇒ 格与格之间零缝（规范：同一连通区域内相邻格子不得有可见空隙）。
func _cell_poly(kind: String, pos: Vector2i, spec: Dictionary, bounds: Rect2,
		spiral_center: Vector2) -> Array:
	var pts := _warped_poly(kind, pos, spec, bounds)
	# 涡流：**极坐标扭转**（坐标场旋转：每个点绕盘心转 θ(半径)），不是「逐格绕自己转」——
	# 后者每格独立旋转会让共享边错开、裂出缝（旧实现实测的 bug）。
	if spec.has("spiral"):
		var k := deg_to_rad(float(spec["spiral"]))
		var roted: Array = []
		for v: Vector2 in pts:
			var d := v - spiral_center
			roted.append(spiral_center + d.rotated(k * d.length()))
		pts = roted
	# 尺寸因子：1.0 = 贴合（默认）；>1 = 故意重叠（叠瓦）；<1 不再使用（会留缝）
	var shrink := float(spec.get("shrink", SHRINK))
	if not is_equal_approx(shrink, 1.0):
		var c := Vector2.ZERO
		for v2: Vector2 in pts:
			c += v2
		c /= float(pts.size())
		var out: Array = []
		for v3: Vector2 in pts:
			out.append(c + (v3 - c) * shrink)
		return out
	return pts


## 盘面形变（taper 梯形 / persp 透视 / arch 拱形）：世界坐标的非线性映射。
## 同为**坐标函数** ⇒ 密铺保持（相邻格共享边的端点被映射到同一处）。
func _warped_poly(kind: String, pos: Vector2i, spec: Dictionary, bounds: Rect2) -> Array:
	var pts := _base_poly(kind, pos, spec)
	var taper := float(spec.get("taper", 0.0))
	var persp := float(spec.get("persp", 0.0))
	var arch := float(spec.get("arch", 0.0))
	if taper == 0.0 and persp == 0.0 and arch == 0.0:
		return pts
	var w := maxf(bounds.size.x, 0.0001)
	var h := maxf(bounds.size.y, 0.0001)
	var ox := bounds.position.x
	var oy := bounds.position.y
	var out: Array = []
	for v: Vector2 in pts:
		var q := v
		var yn := (q.y - oy) / h          # 0..1（上→下）
		var xn := (q.x - ox) / w - 0.5    # -0.5..0.5
		if taper != 0.0:
			q.x = ox + (q.x - ox) * (1.0 + taper * (yn - 0.5))          # 上窄下宽
		if persp != 0.0:
			# 以「顶部中心」为消失点：越往下整体放大（两轴同步 ⇒ 透视收缩）
			var s := 1.0 + persp * yn
			var pivot := Vector2(ox + w * 0.5, oy)
			q = pivot + (q - pivot) * s
		if arch != 0.0:
			q.y -= arch * (0.25 - xn * xn)                              # 上拱（缘成弧）
		out.append(q)
	return out


## custom_shapes：与雏菊链复刻同一格式（渲染层 _ensure_custom_cache 逐字段读）。
func _custom_shapes(kind: String, cells_geo: Array, col_a: String, col_b: String,
		pattern: String, topo: AdjacencyGrid) -> Dictionary:
	var min_v := Vector2(1e9, 1e9)
	var max_v := Vector2(-1e9, -1e9)
	for rec: Dictionary in cells_geo:
		for v: Vector2 in rec["poly"]:
			min_v = Vector2(minf(min_v.x, v.x), minf(min_v.y, v.y))
			max_v = Vector2(maxf(max_v.x, v.x), maxf(max_v.y, v.y))
	var positions: Array = topo.all_positions()
	var sum := Vector2i.ZERO
	for p: Vector2i in positions:
		sum += p
	var mid := Vector2i(int(round(float(sum.x) / float(positions.size()))),
			int(round(float(sum.y) / float(positions.size()))))
	var out_cells: Array = []
	for rec: Dictionary in cells_geo:
		var poly: Array = rec["poly"]
		var pos: Vector2i = rec["pos"]
		var center := Vector2.ZERO
		for v: Vector2 in poly:
			center += v
		center /= float(poly.size())
		var rel: Array = []
		for v2: Vector2 in poly:
			var d := v2 - center
			rel.append([snappedf(d.x, 0.0000001), snappedf(d.y, 0.0000001)])
		out_cells.append({
			"x": pos.x, "y": pos.y,
			"center": [snappedf(center.x - min_v.x, 0.0000001), snappedf(center.y - min_v.y, 0.0000001)],
			"poly": rel,
			"hl": [],
			"taper": [false, false],
			"group": _group_of(pos, mid, kind, pattern, col_a, col_b),
		})
	return {
		"kind": "poly_set",
		"bbox": [0.0, 0.0, snappedf(max_v.x - min_v.x, 0.0000001), snappedf(max_v.y - min_v.y, 0.0000001)],
		"unit": 1.0,
		"cells": out_cells,
	}


## 分区（两色）：rings 环层 / checker 交错 / stripes 横带 / quad 象限。
func _group_of(pos: Vector2i, mid: Vector2i, kind: String, pattern: String,
		col_a: String, col_b: String) -> String:
	var d := pos - mid
	var idx := 0
	match pattern:
		"checker":
			idx = (pos.x + pos.y) % 2
		"stripes":
			idx = pos.y % 2
		"quad":
			idx = ((1 if d.x >= 0 else 0) + (2 if d.y >= 0 else 0)) % 2
		_:
			var ring := 0
			if kind == "hex":
				ring = maxi(maxi(absi(d.x), absi(d.y)), absi(d.x + d.y))
			elif kind == "t488":
				ring = maxi(absi(d.x), absi(d.y)) / 2      # t488 的坐标步长是 2
			else:
				ring = maxi(absi(d.x), absi(d.y))
			idx = ring % 2
	return col_a if idx == 0 else col_b


func _proof_ok(level: Dictionary) -> bool:
	var pl: GDScript = load("res://core/proof_log.gd")
	if pl == null:
		return true
	var log: Variant = pl.call("build", level)
	return log is Dictionary and bool((log as Dictionary).get("solved", false))


func _load_level(path: String) -> Board:
	var loader: GDScript = load(LEVEL_LOADER_PATH)
	if loader == null:
		return null
	var b: Variant = loader.call("load_level", path)
	return b as Board


func _request_exit(code: int) -> void:
	ProjectSettings.set_setting("application/run/flush_stdout_on_print", true)
	_exit_code = code
	_exit_frames = 0
	_exit_pending = true
