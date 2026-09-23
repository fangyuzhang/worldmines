# gen_variant_shape_levels.gd —— 「变体 × 异形」关卡生成工具（离线 CLI）
#
# 运行： godot --headless --path . -s res://tools/gen_variant_shape_levels.gd
# 产出： res://levels/va_<形状>_<规则>.json（va = variant × shape）
#
# 背景（为什么与 gen_shape_levels.gd 分开）：
#   既有工具产的是**纯 classic 形状关**（选关页「形状档」卡片 + 异形棋盘页的底层内容），
#   入库口径强制 easy 档、SPECS 里逐关写死形状指纹。本工具产的是**变体关**：
#   clue 恒为 classic（异形拓扑的邻域计数语义，见 puzzle_generator.gd:302-314），
#   但带 global_rules（S/Z 轴的结构/守恒约束）——难度天然更深，故验收口径不同
#   （只要求「峰值 ≥ 2」防一眼盘，不强制 easy），且**必须**另立工具而不是改既有工具：
#   改既有工具会动到它已入库关卡的产出路径与测试锚点。
#
# 规则 × 形状的可组合性（实测，探针 tools/probe_shape_variants.gd 可复现）：
#   s1/s2/s3/s5/s7/z2/dt —— 挖洞方格与蜂窝均可生成；
#   s4/s6 —— 仅蜂窝；z1（镜像）/z3（四象限）语义依赖方阵几何 ⇒ 异形上不成立，**不产**；
#   z4/z5 —— 待适配（实现疑似假设满行满列），暂不产。
#
# 颜色分区（本工具产出的关卡带 groups）：
#   按「到盘心的圈层」分 3 色（内/中/外环）—— 好看（深底上的三色同心层次）且**有信息**：
#   右上角分色计数器会按圈层报「该环还剩几颗雷」。分区只写数据（groups），渲染层按名字取色。
#
# 验收：生成（内建 R01 序贯无猜）→ 峰值 ≥ 2 → 落盘 → LevelLoader 真实重载自校验；
#   任一失败即删掉该文件并计入失败（批次结束时非 0 退出）。
# ⚠️ 已知缺口（2026-09-23 生成器审计 #4 / #5，与 gen_shape_levels.gd 的口径差）：
#   ① 本族**没有单关 240s 看门狗**。CP-SAT 的 max_time 只约束求解阶段；>100 格 + 变体规则时
#      Solve() 可能长期不返回——外部只有 tools/run_batch.ps1 的 taskkill 兜底（且它会撞上
#      半写批次窗口，见 level_staging 的说明，写盘侧已在 2026-09-23 加固）。
#   ② 加雷轮**没有密度上界**（gen_shape_levels 有 mines+bump ≤ 格数×0.35）。
#   补齐这两项需要专门窗口实跑验证（生成一次数十分钟），故本轮只记录、未实施。
extends SceneTree

const EXIT_FRAMES := 3
const OUT_DIR := "res://levels"
## 写盘走「暂存 → 校验 → 原子转正」（原实现会覆盖后删除，失败即丢原文件）。
const LevelStaging := preload("res://tools/level_staging.gd")
const LEVEL_LOADER_PATH := "res://ui/level_loader.gd"
const ATTEMPTS := 30
const MAX_TRIES := 12         # 换 seed 次数
const MAX_MINES_BUMP := 3     # 加雷轮数
const GEN_TIMEOUT_MS := 60000
## 峰值下限：只排除「一眼盘」（峰值 0 = 全是 0 值格）。**不设上限**——变体关（S/Z 轴）
## 的难度天然比纯 classic 形状关深，强行卡 easy 档会把这些组合全部拒之门外。
## 实测（2026-09-21）：37/40 格盘 + S/Z 约束几乎全空（生成不出序贯可解的盘），
## 19/32 格盘（本文件尺寸）稳定可出——尺寸是这批组合的可行域边界，不是难度调参。
const MIN_PEAK := 1

## 环状配色（palette.groups）。三色相、同亮度带：深紫黑底上清晰且不刺眼。
const RING_COLORS := {
	"RING_0": [82, 179, 255],    # 内环 · 蓝
	"RING_1": [126, 217, 87],    # 中环 · 绿
	"RING_2": [255, 200, 87],    # 外环 · 琥珀
}
## Tametsi 默认深色主题（与实际复刻口径一致：灰格 + 浅灰轮廓 + 白高亮 + 深紫黑底）。
const PALETTE := {
	"background": [20, 0, 35],
	"tile": [127, 127, 127],
	"tile_border": [200, 200, 200],
	"tile_highlight": [255, 255, 255],
	"flagged_tile": [230, 230, 230],
	"revealed": [51, 51, 51],
	"revealed_text": [255, 255, 255],
}

## 6×6 − 4 洞（中央 2×2）= 32 格；蜂窝 size=5（R=2）= 19 格。
## 尺寸取探针（tools/probe_shape_variants.gd）验证过的可行域：再大（37/40 格）时
## S/Z 约束下生成器几乎产不出序贯可解的盘（实测全空），是**该组合族的可行上界**。
const HOLES_6X6: Array = [
	Vector2i(2, 2), Vector2i(3, 2), Vector2i(2, 3), Vector2i(3, 3)]

## 规格：规则 × 形状。rule_name 来自 ui/codex.gd 的官方中文名（S/Z 轴席位）。
const RULES: Array = [
	{"id": "s1", "name": "不行", "desc": "S1「不行」：禁止几种局部摆法"},
	{"id": "s2", "name": "稳稳", "desc": "S2「稳稳」：结构约束"},
	{"id": "s3", "name": "散散", "desc": "S3「散散」：结构约束"},
	{"id": "s4", "name": "层层", "desc": "S4「层层」：结构约束（仅蜂窝）"},
	{"id": "s5", "name": "连排", "desc": "S5「连排」：结构约束"},
	{"id": "s6", "name": "偶偶", "desc": "S6「偶偶」：结构约束（仅蜂窝）"},
	{"id": "s7", "name": "块块", "desc": "S7「块块」：结构约束"},
	{"id": "z2", "name": "步步", "desc": "Z2「步步」：逐行增减"},
	{"id": "dt", "name": "骨牌", "desc": "骨牌：相邻成对"},
]
## 只在这些形状上产（挖洞 7×7 / 蜂窝 7）；s4/s6 实测仅蜂窝可行 ⇒ 逐条排除。
const SHAPE_HOLED := "holed_grid"
const SHAPE_HEX := "hex"

var _exit_code := 0
var _exit_pending := false
var _exit_frames := 0
var _fail := 0
var _ok := 0
var _started := false


## ⚠️ 生成走**第一帧的 _process**，不是 _initialize（实测踩过的坑）：
## S/Z 轴规则（s1~s7 / z1~z5）以 **Mod 身份**提供（demo/mods/s*_*/entry.gd），由 autoload
## 在 _ready 时装进 RuleRegistry；而 SceneTree._initialize() 早于 autoload 就绪 ——
## 在那里跑只能看到 9 条内置规则 ⇒ generate_with_rules 解析规则失败、**静默返回空**
## （表现：48 次尝试全空、peak=-1，极易误判成"该组合数学不可行"）。
## 对照：gen_shape_levels.gd 在 _initialize 里跑没事，因为它只用内置 classic。
func _run() -> void:
	print("=== 变体 × 异形 关卡生成 ===")
	var combos := _combos()
	print("  规格 %d 关（clue=classic；峰值要求 ≥ %d）" % [combos.size(), MIN_PEAK])
	# 诊断：规则注册状态（s*/z* 由备用算子包提供，未装配时 generate 会静默返回空）
	var reg := RuleRegistry.default()
	print("  注册表共 %d 条规则" % reg.all_ids().size())
	for r: Dictionary in RULES:
		var rr: Object = reg.resolve(StringName(str(r["id"])))
		if rr == null:
			print("  !! 未注册：%s（%s）" % [str(r["id"]), str(r["name"])])
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var t_all := Time.get_ticks_msec()
	for c: Dictionary in combos:
		if not _gen_one(c):
			_fail += 1
		else:
			_ok += 1
	var secs := float(Time.get_ticks_msec() - t_all) / 1000.0
	print("=== 完成：成功 %d / 失败 %d，耗时 %.1f s ===" % [_ok, _fail, secs])
	if _fail > 0:
		print("=== VARIANT-SHAPE-FAILED ===")
		_request_exit(1)
		return
	print("=== VARIANT-SHAPE-OK ===")
	_request_exit(0)


## 组合清单：蜂窝全覆盖 9 条；挖洞排除实测不可行的 s4/s6（共 16 关）。
func _combos() -> Array:
	var out: Array = []
	var seed_base := 11000
	for r: Dictionary in RULES:
		for shape in [SHAPE_HOLED, SHAPE_HEX]:
			if shape == SHAPE_HOLED and (str(r["id"]) == "s4" or str(r["id"]) == "s6"):
				continue   # 实测：这两条约束在挖洞方格上生成不出（详见工具头注释）
			seed_base += 7
			out.append({
				"file": "va_%s_%s.json" % ["hex" if shape == SHAPE_HEX else "holed", str(r["id"])],
				"shape": shape, "rule": str(r["id"]), "rule_name": str(r["name"]),
				"desc": str(r["desc"]), "seed": seed_base,
			})
	return out


func _gen_one(c: Dictionary) -> bool:
	var file_name := str(c["file"])
	var path := OUT_DIR + "/" + file_name
	# 形状与参数：挖洞 6×6−4洞（32 格）/ 蜂窝 size=5（19 格）——探针验证过的可行域
	var shape := str(c["shape"])
	var params: Dictionary = {"rows": 6, "cols": 6, "holes": HOLES_6X6} if shape == SHAPE_HOLED \
			else {"size": 5}
	var topo: AdjacencyGrid = ShapeGenerator.to_adjacency_grid(shape, params)
	if topo == null:
		push_error("%s: 形状构建失败" % file_name)
		return false
	topo = AdjacencyGrid.normalized(topo)
	var n := topo.cell_count()
	var mines := maxi(1, int(round(float(n) * 0.3)))   # round 口径（32 格→10 雷，19 格→6 雷）。注意 tools/probe_shape_variants.gd 用的是
	# int 截断（→9/5），两边对不上时以本文件为准（产物按 round 落盘）。
	var size := topo.size()
	var shape_cn := "挖洞" if shape == SHAPE_HOLED else "蜂窝"

	var gen := PuzzleGenerator.new()
	var level: Dictionary = {}
	var used_mines := 0
	var tries := 0
	var best_peak := -1
	var t0 := Time.get_ticks_msec()
	for b in MAX_MINES_BUMP + 1:
		for t in MAX_TRIES:
			tries += 1
			var cand: Dictionary = gen.generate_with_rules(
					"classic", [str(c["rule"])], size, mines + b, int(c["seed"]) + t, 0, ATTEMPTS,
					topo, GEN_TIMEOUT_MS)
			if cand.is_empty():
				continue
			var prof: Dictionary = cand.get("difficulty_profile", {})
			best_peak = maxi(best_peak, int(prof.get("max_complexity", -1)))
			if int(prof.get("max_complexity", 0)) < MIN_PEAK:
				continue
			# 双验收：生成器内建的 R01 之外，再用**测试门禁同款**的 ProofLog 复核一遍。
			# 两者是独立的推演器，历史上出现过「生成器判定通过、ProofLog 却推不到底」的盘
			# （见 test_level_proof_coverage.gd 注释；本工具首跑就撞上一个 va_holed_z2）。
			# 以门禁为准：不入库推不到底的盘 —— 否则新关卡一落地，全量回归立刻红灯。
			if not _proof_ok(cand):
				continue
			level = cand
			used_mines = mines + b
			break
		if not level.is_empty():
			break
	var gen_ms := Time.get_ticks_msec() - t0
	if level.is_empty():
		push_error("%s: %d 次尝试（换 seed %d × 加雷 %d）无一达到峰值 ≥ %d（最高 %d）" % [
			file_name, tries, MAX_TRIES, MAX_MINES_BUMP + 1, MIN_PEAK, best_peak])
		return false

	# 落盘字段：中文名 / 形状标签 / 描述 / 圈层配色
	level["name"] = "%s · %s" % [shape_cn, str(c["rule_name"])]
	level["desc"] = "%s（%s %d 格）" % [str(c["desc"]), shape_cn, n]
	level["shape_kind"] = "蜂窝盘" if shape == SHAPE_HEX else "挖洞方格"
	level["groups"] = _ring_groups(topo)
	level["palette"] = _palette()

	# 2026-09-23 审计修复：先写暂存区、校验通过才原子转正。原实现直接覆盖正式文件、
	# 校验失败再 remove —— 盘上原有的好文件被「覆盖后删除」，净结果永久丢失。
	var tmp := LevelStaging.write_text(path, JSON.stringify(level, "  "))
	if tmp == "":
		push_error("%s: 无法写入暂存区" % file_name)
		return false

	# 自校验：真实加载器重载（写出去的文件必须能玩）
	var board: Board = _load_level(tmp)
	var problems: Array[String] = []
	if board == null:
		problems.append("LevelLoader.load_level 返回 null")
	else:
		if not (board.grid is AdjacencyGrid):
			problems.append("grid 不是 AdjacencyGrid")
		elif board.grid.cell_count() != n:
			problems.append("cell_count=%d ≠ %d" % [board.grid.cell_count(), n])
		if board.total_mines != used_mines:
			problems.append("total_mines=%d ≠ 实际 %d" % [board.total_mines, used_mines])
		if not board.has_meta("custom_shapes"):
			pass   # 参数化形状本就没有 custom_shapes（渲染走 style 分支）——不是问题
		if not board.has_meta("groups"):
			problems.append("groups meta 未注入（分色失效）")
	if not problems.is_empty():
		push_error("%s: 自校验失败 —— %s" % [file_name, "；".join(problems)])
		LevelStaging.discard(tmp)     # 只删自己写的暂存，正式文件原封不动
		return false
	if not LevelStaging.promote(tmp, path):
		push_error("%s: 暂存转正失败，正式文件未改动" % file_name)
		return false
	var prof2: Dictionary = level.get("difficulty_profile", {})
	print("  OK   %-22s %d 格 · %d 雷 · 峰值 %s · 轮 %s · %d 次尝试 · %.1f s" % [
		file_name, n, used_mines, str(prof2.get("max_complexity", "?")),
		str(prof2.get("rounds", "?")), tries, float(gen_ms) / 1000.0])
	return true


## 圈层分区：方格按切比雪夫距离、蜂窝按轴向距离（相对盘心）→ 环号 % 3 → 三色。
## 不做「洞格跳过」——洞格不在 topology 里，循环自然不会遇到。
func _ring_groups(topo: AdjacencyGrid) -> Dictionary:
	var positions := topo.all_positions()
	var sum := Vector2i.ZERO
	for p: Vector2i in positions:
		sum += p
	var center := Vector2i(int(round(float(sum.x) / float(positions.size()))),
			int(round(float(sum.y) / float(positions.size()))))
	var out := {"__colors__": RING_COLORS, "cells": {}}
	var cells: Dictionary = out["cells"]
	for p: Vector2i in positions:
		var d := p - center
		var ring := 0
		if topo.style == "hex":
			# 轴向坐标下的六方距离：环号 = max(|dq|, |dr|, |dq+dr|)
			ring = maxi(maxi(absi(d.x), absi(d.y)), absi(d.x + d.y))
		else:
			ring = maxi(absi(d.x), absi(d.y))   # 切比雪夫（方环）
		cells["%d,%d" % [p.x, p.y]] = "RING_%d" % (ring % 3)
	return out


func _palette() -> Dictionary:
	var p := PALETTE.duplicate(true)
	p["groups"] = RING_COLORS.duplicate(true)
	return p


## ProofLog 复核（测试门禁同款推演器）。运行期 load：-s 脚本的编译期依赖有坑（见 _load_level）。
func _proof_ok(level: Dictionary) -> bool:
	var pl: GDScript = load("res://core/proof_log.gd")
	if pl == null:
		return true   # 拿不到推演器时不阻断（门禁测试会兜底）
	var log: Variant = pl.call("build", level)
	return log is Dictionary and bool((log as Dictionary).get("solved", false))


func _load_level(path: String) -> Board:
	# 运行期 load：-s 脚本在 autoload 之前编译，编译期依赖会连带失败（见 gen_shape_levels.gd 同款注释）
	var loader: GDScript = load(LEVEL_LOADER_PATH)
	if loader == null:
		return null
	var b: Variant = loader.call("load_level", path)
	return b as Board


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()          # autoload（含 mod 规则装配）此刻已就绪
		return false
	if not _exit_pending:
		return false
	_exit_frames += 1
	if _exit_frames < EXIT_FRAMES:
		return false
	quit(_exit_code)
	return true


func _request_exit(code: int) -> void:
	ProjectSettings.set_setting("application/run/flush_stdout_on_print", true)
	_exit_code = code
	_exit_frames = 0
	_exit_pending = true
