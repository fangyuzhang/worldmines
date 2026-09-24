# gen_variant_shape_levels.gd —— 「变体 × 异形」关卡生成工具（离线 CLI）
#
# 运行： godot --headless --path . -s res://tools/gen_variant_shape_levels.gd
# 产出： res://levels/va_<形状>_<规则>.json（va = variant × shape）
#
# ===== 定向档位模式（2026-09-23 新增；用户口径「每个变体 × 每个档位都要有较多异形关」）=====
# 既往模式（无参数）产 16 关固定表、只要求「峰值 ≥ MIN_PEAK」——峰值随机分布，于是异形页
# 出现缺口（s5 三档全空、s7/z2/z3 某档零关）。定向模式把「目标档位」变成一等工作负载：
# 只有落进目标窗口（core/difficulty.gd:PEAK_WINDOWS）的盘才收，收不到就如实失败。
# 用法：
#   godot --headless --path . -s res://tools/gen_variant_shape_levels.gd -- \
#       --tier=easy --rule=s5 --shape=hex --count=2
#   多档： --tier=easy,normal,hard   （同规则同形状一次补齐三档）
#   仅探不产（决策用）： --probe --rule=s5,s7 --shape=hex,holed --seeds=12
#     打印每个 seed 的峰值/档位与各档命中统计，不写任何文件——先看分布再决定跑什么。
# 定向模式验收 = Difficulty.tier_of_profile(prof) == 目标档（同时保留「内建 R01 + ProofLog
# 双验收」）。搜索顺序 = 雷数偏移序列（_bumps_for）× seed 递增，任一命中即落盘
# （seed/雷数写进产物，重跑确定性复现）。
# 命名： va_<形状>_<规则>_<档><序号>.json（**不覆盖**既往 va_<形状>_<规则>.json）。
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
const MAX_MINES_BUMP := 3
## 纹理徽记规则源（palette.texture：变体轴 / 形状族的唯一映射表）。
const TextureMarks := preload("res://tools/texture_marks.gd")
## 主题配色规则源（palette.theme）。2026-09-24 接入：本族是变体关，
## theme 缺失时整族退化成同一套灰紫底盘（这正是盘点时发现的缺口）。
const ThemeMarks := preload("res://tools/theme_marks.gd")

## 单关**累计**生成时间上限（看门狗）。2026-09-23 审计 #4 补齐，与 gen_shape_levels.gd 同口径。
## 理由：CP-SAT 的 max_time_in_seconds 只约束求解阶段，实测 >100 格 + 变体规则时 Solve()
## 长期不返回（CPU 近 0、无输出），从外部与死锁无法区分，只能手动杀进程、整批白跑。
## 局限（如实说明）：检查点在调用之间，单次 Solve() 自身卡住则打断不了（OR-Tools 无中止接口）。
const WATCHDOG_MS_PER_LEVEL := 240000
## 密度上界（2026-09-23 审计 #5 补齐）：mines + bump 不得超过 格数 × DENSITY_CAP。
## 超过说明该形状在此尺寸下数学上难出深推理——如实失败并在报告里列出，不无限加雷。
const DENSITY_CAP := 0.35     # 加雷轮数
const GEN_TIMEOUT_MS := 60000
## 峰值下限：只排除「一眼盘」（峰值 0 = 全是 0 值格）。**不设上限**——变体关（S/Z 轴）
## 的难度天然比纯 classic 形状关深，强行卡 easy 档会把这些组合全部拒之门外。
## 实测（2026-09-21）：37/40 格盘 + S/Z 约束几乎全空（生成不出序贯可解的盘），
## 19/32 格盘（本文件尺寸）稳定可出——尺寸是这批组合的可行域边界，不是难度调参。
const MIN_PEAK := 1

## 定向档位模式的**每雷数档** seed 尝试次数（= 12）。
## 为什么不是更大：搜索是「雷数偏移 × seed」两层循环，看门狗 240s 是单关总预算——雷数档
## 必须全部能在被砍之前走到。实测 z3（四象限，偶数盘须雷数 ≡0 mod 4）在 45 格盘上的可行
## 雷数排在偏移序列的 −2 位（12 雷），24×7 的尝试量约 500s，根本走不到它就被看门狗砍掉；
## 12×7 = 84 次尝试的总时长在预算内，配合「命中即停」实测足够（z3 hard 命中率 ~1/8，
## 12 次期望 1.5 次命中）。
const TIER_TRIES := 12
## 定向模式的雷数下限密度（相对格数）：降雷能压低推理深度（产 easy 用），但不能无限降
## （雷太少则线索全空、生成器产不出序贯可解的盘）。上限沿用 DENSITY_CAP。
const TIER_DENSITY_FLOOR := 0.15
## 定向模式的起始 seed（--seed0 缺省值）：选在既往 16 关（11000~11147）之外的区间，
## 避免与既有产物的 seed 撞车（同 seed 同参数会产同一盘）。
const TIER_SEED0_DEFAULT := 20000
## 三档 id（判档窗口的唯一事实源是 core/difficulty.gd 的 PEAK_WINDOWS；这里只是 id 序，
## 供命令行参数校验与日志文本使用）。
const TIER_NAMES: Array = ["easy", "normal", "hard"]

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
## 7×7 − 中央 2×2 洞（45 格）：2026-09-23 定向模式新增的 **hard 档几何**。
## 为什么需要它：6×6 的密度上界 = 32×0.35 = 11 雷，hard 峰值在 10~11 雷下命中率极低
## （s5 实测 46 次尝试才 1 关）；且 z3 这类**整除规则**（四象限雷数相等 ⇒ 偶数盘雷数
## 须 ≡0 mod 4）在 6×6 上窗口内只能取 8 雷，峰值封顶 4 —— hard 结构性不可达。
## 7×7 是奇数盘（中轴 13 格吸收余数）、密度上界 15 雷、12 雷可用（z3 规则注释实测 7×7 可行）。
## 代价：45 格单次 CP-SAT 更慢 ⇒ 仅在定向 hard 档/整除规则使用（旧表不含）。
const HOLES_7X7: Array = [
	Vector2i(3, 3), Vector2i(4, 3), Vector2i(3, 4), Vector2i(4, 4)]

## 规格：规则 × 形状。name **必须逐字等于** `VariantCatalog.display_name(id)`
## （即变体 Mod 的 describe()["name"]，见 ui/variant_catalog.gd:153 与 demo/mods/*/entry.gd）。
##
## ⚠️ 这里曾经写的是**旧昵称**（不行/稳稳/散散/层层/连排/偶偶/块块/步步），而选关页的变体卡
## 显示官方名（局部禁形/重心/无环/洋葱/行列凸/度偶数/分量数 K/相邻行锁）——同一屏两套叫法，
## 玩家会以为「局部禁形」和「局部禁形」是两个东西。2026-09-24 交叉验证发现 83 处不一致后统一。
## 门禁：test/unit/test_level_naming_contract.gd 会校验关卡名后缀 == display_name。
const RULES: Array = [
	{"id": "s1", "name": "局部禁形", "desc": "S1「局部禁形」：禁止几种局部摆法"},
	{"id": "s2", "name": "重心", "desc": "S2「重心」：结构约束"},
	{"id": "s3", "name": "无环", "desc": "S3「无环」：结构约束"},
	{"id": "s4", "name": "洋葱", "desc": "S4「洋葱」：结构约束（仅蜂窝）"},
	{"id": "s5", "name": "行列凸", "desc": "S5「行列凸」：结构约束"},
	{"id": "s6", "name": "度偶数", "desc": "S6「度偶数」：结构约束（仅蜂窝）"},
	{"id": "s7", "name": "分量数 K", "desc": "S7「分量数 K」：结构约束"},
	{"id": "z2", "name": "相邻行锁", "desc": "Z2「相邻行锁」：逐行增减"},
	{"id": "z3", "name": "四象", "desc": "Z3「四象」：四象限雷数相等（偶数盘须雷数 ≡0 mod 4）"},
	{"id": "dt", "name": "骨牌边界", "desc": "骨牌：相邻成对"},
]
## 旧表（无参数模式）的规则序列：**不含 z3**——z3 于 2026-09-23 定向模式加入规则池
## （异形页的 z3 此前只有 ani_web 一关、三档缺口大）。把它放进旧表会改变「无参数 =
## 既往 16 关」的承诺（多产两关 + seed 序列整体位移），故旧表规则锁在这里。
const LEGACY_RULE_IDS: Array = ["s1", "s2", "s3", "s4", "s5", "s6", "s7", "z2", "dt"]
## ===== 形状候选表（定向模式；tag → 形状定义）=====
## kind 是 ShapeGenerator 的注册族名（holed_grid / hex），params 是族参数，cn 是中文标签
##（进关卡名）。**tag 只用于文件名与命令行**，与 kind 解耦（同一 kind 可有多档尺寸）。
## 默认形状序列（--shape 缺省）= ["holed", "hex"]；holed7 只显式指定时用（耗时更长）。
const SHAPES := {
	"holed": {"kind": "holed_grid", "params": {"rows": 6, "cols": 6, "holes": HOLES_6X6}, "cn": "挖洞"},
	"holed7": {"kind": "holed_grid", "params": {"rows": 7, "cols": 7, "holes": HOLES_7X7}, "cn": "大挖洞"},
	"hex": {"kind": "hex", "params": {"size": 5}, "cn": "蜂窝"},
	"hex7": {"kind": "hex", "params": {"size": 7}, "cn": "大蜂窝"},
}
## 旧表（无参数模式）的形状序列：holed(6×6) → tag "holed"、hex(19 格) → tag "hex"。
## **不含 holed7**——旧表 16 关逐字节复现的承诺。
const LEGACY_SHAPE_TAGS: Array = ["holed", "hex"]
## kind 名常量（s4/s6 只在蜂窝上可行的排除规则用）。
const SHAPE_HOLED := "holed_grid"
const SHAPE_HEX := "hex"

var _exit_code := 0
var _exit_pending := false
var _exit_frames := 0
var _fail := 0
var _ok := 0
var _started := false

## 定向档位模式的命令行参数（OS.get_cmdline_user_args，`--key=value` 形式）。
## 无参数 = 既往 16 关固定表（默认值全空/false 即走老路径）。
var _ARGS: Dictionary = {
	"tier": "", "rules": [], "shapes": [], "count": 1, "seed0": 0, "idx0": 1,
	"probe": false, "seeds": 12, "mines": -1, "isolate": false,
}


## ⚠️ 生成走**第一帧的 _process**，不是 _initialize（实测踩过的坑）：
## S/Z 轴规则（s1~s7 / z1~z5）以 **Mod 身份**提供（demo/mods/s*_*/entry.gd），由 autoload
## 在 _ready 时装进 RuleRegistry；而 SceneTree._initialize() 早于 autoload 就绪 ——
## 在那里跑只能看到 9 条内置规则 ⇒ generate_with_rules 解析规则失败、**静默返回空**
## （表现：48 次尝试全空、peak=-1，极易误判成"该组合数学不可行"）。
## 对照：gen_shape_levels.gd 在 _initialize 里跑没事，因为它只用内置 classic。
## ==== 进程隔离（2026-09-24）====
## 为什么需要：CP-SAT 的 max_time_in_seconds 只约束**求解**阶段，且 OR-Tools **不提供中止
## 接口**（求解线程无法被安全强制终止）。实测大网格 + 变体规则时单次 Solve() 会长期不返回
## —— 进程 CPU 近 0、无输出，从外部与死锁无法区分。
## 本工具原有的**看门狗只在两次调用之间**检查，对「单次 Solve 挂死」无能为力
## （实测 hard 档在 holed7 上就是这么挂住的，只能手动杀进程）。
## 隔离做法：每关起一个 headless 子进程生成，父进程轮询完成标记，超时直接 OS.kill。
##
## 取舍（如实说明）：子进程各自提交，放弃了原先「全批通过才统一提交」的**批次**原子性；
## 但每关仍是「暂存 → 自校验 → 原子转正」，**单关级别**依旧不会留半成品。
## 子进程崩溃/被杀时该关不落盘，父进程计入失败 —— 这正是我们要的（失败而非挂死）。
const CHILD_TIMEOUT_MS := 300000      # 单关子进程上限（5 分钟）
const CHILD_POLL_MS := 250
const CHILD_WORK_DIR := "user://_child_work"


func _run() -> void:
	_args_parse()
	print("=== 变体 × 异形 关卡生成 ===")
	# 诊断：规则注册状态（s*/z* 由备用算子包提供，未装配时 generate 会静默返回空）
	var reg := RuleRegistry.default()
	print("  注册表共 %d 条规则" % reg.all_ids().size())
	for r: Dictionary in RULES:
		var rr: Object = reg.resolve(StringName(str(r["id"])))
		if rr == null:
			print("  !! 未注册：%s（%s）" % [str(r["id"]), str(r["name"])])
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	if bool(_ARGS["probe"]):
		_probe(reg)
		_request_exit(0)   # probe 只是探测：成功失败都不产文件，退出码恒 0
		return
	var combos := _combos()
	if str(_ARGS["tier"]) == "":
		print("  规格 %d 关（clue=classic；峰值要求 ≥ %d）" % [combos.size(), MIN_PEAK])
	else:
		print("  定向档位模式：%d 关（目标档 %s；验收 = 峰值落窗口 %s）" % [
			combos.size(), str(_ARGS["tier"]), _windows_text()])
	var t_all := Time.get_ticks_msec()
	var isolate := bool(_ARGS["isolate"])
	if isolate:
		print("  ** 进程隔离已开启：每关独立子进程 + %d 秒强杀（防 CP-SAT 单次 Solve 挂死）**" % [
			CHILD_TIMEOUT_MS / 1000])
	for c: Dictionary in combos:
		var ok := false
		if isolate:
			var code := _run_isolated(c)
			ok = code == 0
			if code == 2:
				print("  !! %s：超时强杀（该组合在此规模下超出求解器可行域）" % str(c["file"]))
		else:
			ok = _gen_one(c)
		if not ok:
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


## 组合清单：无参数 = 既往 16 关固定表；带 --tier = 定向档位任务表。
func _combos() -> Array:
	if str(_ARGS["tier"]) == "":
		return _legacy_combos()
	return _tiered_combos()


## 既往 16 关固定表（蜂窝全覆盖 9 条；挖洞排除实测不可行的 s4/s6）。
## 保持逐字节复现：seed_base 递增顺序与旧版完全一致，勿动。
func _legacy_combos() -> Array:
	var out: Array = []
	var seed_base := 11000
	for id in LEGACY_RULE_IDS:
		var r := _rule_by_id(str(id))
		for tag in LEGACY_SHAPE_TAGS:
			var sh := str(tag)
			if _shape_kind(sh) == SHAPE_HOLED and (str(r["id"]) == "s4" or str(r["id"]) == "s6"):
				continue   # 实测：这两条约束在挖洞方格上生成不出（详见工具头注释）
			seed_base += 7
			out.append({
				"file": "va_%s_%s.json" % [sh, str(r["id"])],
				"shape": sh, "rule": str(r["id"]), "rule_name": str(r["name"]),
				"desc": str(r["desc"]), "seed": seed_base,
			})
	return out


## 定向档位任务表：tier × rule（默认全部）× shape（默认 holed+hex）× 序号（1..count）。
## 形状沿用既有实测排除（s4/s6 在挖洞上产不出）；seed 每任务递增错开，避免产重复盘。
func _tiered_combos() -> Array:
	var out: Array = []
	var tiers: Array = str(_ARGS["tier"]).split(",", false)
	var rules: Array = _ARGS["rules"] if not (_ARGS["rules"] as Array).is_empty() else _rule_ids()
	var shapes: Array = _ARGS["shapes"] if not (_ARGS["shapes"] as Array).is_empty() \
			else ["holed", "hex"]
	var count := int(_ARGS["count"])
	var seed_base := int(_ARGS["seed0"])
	var n_task := 0
	for t in tiers:
		var tier := str(t)
		if not TIER_NAMES.has(tier):
			print("  !! 未知档位：%s（合法：%s）" % [tier, ", ".join(TIER_NAMES)])
			continue
		for rule in rules:
			var rid := str(rule)
			var r := _rule_by_id(rid)
			if r.is_empty():
				print("  !! 未知规则：%s（合法：%s）" % [rid, ", ".join(_rule_ids())])
				continue
			for shape in shapes:
				var sh := str(shape)
				if _shape_spec(sh).is_empty():
					print("  !! 未知形状：%s（合法：%s）" % [sh, ", ".join(SHAPES.keys())])
					continue
				if _shape_kind(sh) == SHAPE_HOLED and (rid == "s4" or rid == "s6"):
					continue   # 实测：这两条约束在挖洞方格上生成不出（6×6 与 holed7 均实测全空）
				for i in count:
					n_task += 1
					var idx := int(_ARGS["idx0"]) + i
					out.append({
						"file": "va_%s_%s_%s%d.json" % [sh, rid, tier, idx],
						"shape": sh, "rule": rid, "rule_name": str(r["name"]),
						"desc": str(r["desc"]), "tier": tier, "idx": idx,
						# 每任务 seed 间隔 37（与旧表的 7 间隔错开 ⇒ 不与既有产物撞盘）
						"seed": seed_base + n_task * 37,
					})
	return out


## 规则 id 列表 / 按 id 取规则（RULES 只有 9 条，线性查足够）。
func _rule_ids() -> Array:
	var out: Array = []
	for r: Dictionary in RULES:
		out.append(str(r["id"]))
	return out


func _rule_by_id(id: String) -> Dictionary:
	for r: Dictionary in RULES:
		if str(r["id"]) == id:
			return r
	return {}


## 形状 tag → {kind, params, cn}（空 = 未知 tag）。
func _shape_spec(tag: String) -> Dictionary:
	return SHAPES.get(tag, {})


## 形状 tag → kind（空 = 未知 tag）。排除规则（s4/s6 仅蜂窝）按 kind 判。
func _shape_kind(tag: String) -> String:
	var s := _shape_spec(tag)
	return str(s.get("kind", "")) if not s.is_empty() else ""


func _gen_one(c: Dictionary) -> bool:
	var file_name := str(c["file"])
	var path := OUT_DIR + "/" + file_name
	# 形状与参数：tag → SHAPES 表（holed 32 格 / holed7 45 格 / hex 19 格）
	var tag := str(c["shape"])
	var spec := _shape_spec(tag)
	if spec.is_empty():
		push_error("%s: 未知形状 %s" % [file_name, tag])
		return false
	var topo: AdjacencyGrid = ShapeGenerator.to_adjacency_grid(str(spec["kind"]), spec["params"])
	if topo == null:
		push_error("%s: 形状构建失败" % file_name)
		return false
	topo = AdjacencyGrid.normalized(topo)
	var n := topo.cell_count()
	# 基准雷数：--mines=N 可覆盖（probe/定向调参用）；默认 n×0.3 的 round 口径
	# （32 格→10 雷，19 格→6 雷）。注意 tools/probe_shape_variants.gd 用的是 int 截断（→9/5），
	# 两边对不上时以本文件为准（产物按 round 落盘）。
	var mines := int(_ARGS["mines"]) if int(_ARGS["mines"]) > 0 else maxi(1, int(round(float(n) * 0.3)))
	var size := topo.size()
	var shape_cn := str(spec["cn"])
	var want_tier := str(c.get("tier", ""))

	var gen := PuzzleGenerator.new()
	var level: Dictionary = {}
	var used_mines := 0
	var tries := 0
	var best_peak := -1
	var t0 := Time.get_ticks_msec()
	# 密度上界（2026-09-23 审计 #5）：mines + bump 不得超过 格数 × DENSITY_CAP。
	var max_mines := int(floor(float(n) * DENSITY_CAP))
	if mines > max_mines:
		push_error("%s: 基准雷数 %d 已超密度上界 %d（格数 %d × %.2f）——规格本身不合低密度设计" % [
			file_name, mines, max_mines, n, DENSITY_CAP])
		return false
	# 密度下界（定向模式）：降雷能压低推理深度（产 easy 用），但不能无限降——雷太少则线索
	# 全空、生成器产不出序贯可解的盘。老路径（无 tier）不启用下限，保持逐字节复现。
	var min_mines := maxi(2, int(round(float(n) * TIER_DENSITY_FLOOR)))
	var bumps := _bumps_for(want_tier)
	var tries_cap := TIER_TRIES if want_tier != "" else MAX_TRIES
	# 看门狗（2026-09-23 审计 #4）：单关累计时间超限即放弃本关（失败而非挂死整批）。
	var level_t0 := Time.get_ticks_msec()
	for b in bumps:
		var m: int = mines + int(b)
		if m < min_mines or m > max_mines:
			continue
		for t in tries_cap:
			tries += 1
			if Time.get_ticks_msec() - level_t0 > WATCHDOG_MS_PER_LEVEL:
				push_error("%s: 单关累计生成超过 %d 秒（看门狗触发）——判定超出求解器可行域，放弃本关。已尝试 %d 次，最高 peak=%d" % [
					file_name, WATCHDOG_MS_PER_LEVEL / 1000, tries, best_peak])
				return false
			var cand: Dictionary = gen.generate_with_rules(
					"classic", [str(c["rule"])], size, m, int(c["seed"]) + t, 0, ATTEMPTS,
					topo, GEN_TIMEOUT_MS)
			if cand.is_empty():
				continue
			var prof: Dictionary = cand.get("difficulty_profile", {})
			var peak := int(prof.get("max_complexity", -1))
			best_peak = maxi(best_peak, peak)
			if want_tier != "":
				# 定向档位验收：必须**落进目标窗口**。不接受"接近"——档位错了这关白产，
				# 异形页对应档位的格子还是空的（用户口径要的是"每档都有"）。
				if _tier_of(prof) != want_tier:
					continue
			elif peak < MIN_PEAK:
				continue
			# 双验收：生成器内建的 R01 之外，再用**测试门禁同款**的 ProofLog 复核一遍。
			# 两者是独立的推演器，历史上出现过「生成器判定通过、ProofLog 却推不到底」的盘
			# （见 test_level_proof_coverage.gd 注释；本工具首跑就撞上一个 va_holed_z2）。
			# 以门禁为准：不入库推不到底的盘 —— 否则新关卡一落地，全量回归立刻红灯。
			if not _proof_ok(cand):
				continue
			level = cand
			used_mines = m
			break
		if not level.is_empty():
			break
	var gen_ms := Time.get_ticks_msec() - t0
	if level.is_empty():
		if want_tier != "":
			push_error("%s: %d 次尝试（雷数偏移 %d 档 × seed %d 个）无一落进目标档 %s（最高 peak=%d）" % [
				file_name, tries, bumps.size(), tries_cap, want_tier, best_peak])
		else:
			push_error("%s: %d 次尝试（换 seed %d × 加雷 %d）无一达到峰值 ≥ %d（最高 %d）" % [
				file_name, tries, MAX_TRIES, MAX_MINES_BUMP + 1, MIN_PEAK, best_peak])
		return false

	# 落盘字段：中文名 / 形状标签 / 描述 / 圈层配色
	# 名字带序号后缀（仅定向模式 count>1 时）：同变体同形状产多关时卡片标题要能区分。
	# **不把档位写进名字**——档位是画像的客观结论，由 UI 从 difficulty_profile 实时算
	# （写死进名字会在未来重算档位/调窗口时失真）。
	var idx := int(c.get("idx", 1))
	var name_suffix := "" if idx <= 1 else " #%d" % idx
	level["name"] = "%s · %s%s" % [shape_cn, str(c["rule_name"]), name_suffix]
	level["desc"] = "%s（%s %d 格）" % [str(c["desc"]), shape_cn, n]
	level["shape_kind"] = "蜂窝盘" if str(spec["kind"]) == SHAPE_HEX else "挖洞方格"
	level["groups"] = _ring_groups(topo)
	# 纹理徽记（2026-09-23 审计续）：变体关按变体轴解析（规则源 tools/texture_marks.gd）。
	var _tm_gl: Array = level.get("global_rules", [])
	var _tm_variant := str(_tm_gl[0]) if not _tm_gl.is_empty() else ""
	# 主题配色（2026-09-24）：本族是变体关，theme 尤其关键（没有它整族都是同一套灰紫）。
	# apply() 删掉七个手写基础键（否则 theme 被逐键短路）并保留 groups。
	level["palette"] = ThemeMarks.apply(_palette(), "", _tm_variant, "")
	var _tm := TextureMarks.resolve("", _tm_variant, "")
	if _tm != "":
		level["palette"]["texture"] = _tm

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
	print("  OK   %-26s %d 格 · %d 雷 · 峰值 %s%s · 轮 %s · %d 次尝试 · %.1f s" % [
		file_name, n, used_mines, str(prof2.get("max_complexity", "?")),
		("（%s）" % _tier_of(prof2)) if want_tier != "" else "",
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


## ===== 定向档位模式：参数解析 / 判档 / probe =====

## 参数解析（`--key=value`；未知键打印警告不中断——防御手误，别让一次拼错白跑一批）。
func _args_parse() -> void:
	var rules: Array = []
	var shapes: Array = []
	for raw in OS.get_cmdline_user_args():
		var a := str(raw)
		if not a.begins_with("--"):
			continue
		var body := a.substr(2)
		var eq := body.find("=")
		var k := body if eq < 0 else body.substr(0, eq)
		var v := "" if eq < 0 else body.substr(eq + 1)
		match k:
			"tier":
				_ARGS["tier"] = v
			"rule":
				rules = v.split(",", false)
			"shape":
				shapes = v.split(",", false)
			"count":
				_ARGS["count"] = maxi(1, int(v))
			"seed0":
				_ARGS["seed0"] = int(v)
			"idx0":
				# 补跑时用（避免与既有 va_<形状>_<规则>_<档>1.json 撞名覆盖——
				# 实测踩过：count=1 的两轮补跑同名，后一轮的落盘把前一轮整个删了）
				_ARGS["idx0"] = maxi(1, int(v))
			"probe":
				_ARGS["probe"] = true
			"isolate":
				# 进程隔离：每关起独立子进程生成，超时强杀（防 CP-SAT 单次 Solve 挂死）
				_ARGS["isolate"] = true
			"seeds":
				_ARGS["seeds"] = maxi(1, int(v))
			"mines":
				_ARGS["mines"] = int(v)
			_:
				print("  !! 未知参数（忽略）：%s" % a)
	_ARGS["rules"] = rules
	_ARGS["shapes"] = shapes
	if int(_ARGS["seed0"]) <= 0:
		_ARGS["seed0"] = TIER_SEED0_DEFAULT


## 进程隔离：把**一关**放进独立子进程生成，父进程轮询完成标记，超时强杀。
## 返回 0=成功 / 1=生成失败 / 2=超时被杀。
## 规格通过 JSON 文件传递（不靠命令行重放 --tier 等参数：子进程的参数表与父进程不同源，
## 重放会拿到不一样的 combos —— 实测踩过这类"父说 A 子做 B"的坑）。
func _run_isolated(c: Dictionary) -> int:
	var file := str(c["file"])
	DirAccess.make_dir_recursive_absolute(CHILD_WORK_DIR)
	var spec_path := "%s/%s.spec.json" % [CHILD_WORK_DIR, file]
	var marker := "%s/%s.done" % [CHILD_WORK_DIR, file]
	var sf := FileAccess.open(spec_path, FileAccess.WRITE)
	if sf == null:
		push_error("%s: 无法写子进程规格 %s" % [file, spec_path])
		return 1
	sf.store_string(JSON.stringify(c))
	sf.close()
	if FileAccess.file_exists(marker):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(marker))
	var pid := OS.create_process(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"-s", "res://tools/gen_variant_shape_levels.gd",
		"--", "child", spec_path, marker,
	]))
	if pid <= 0:
		push_error("%s: 子进程启动失败" % file)
		return 1
	var waited := 0
	while waited < CHILD_TIMEOUT_MS:
		OS.delay_msec(CHILD_POLL_MS)
		waited += CHILD_POLL_MS
		if FileAccess.file_exists(marker):
			var f := FileAccess.open(marker, FileAccess.READ)
			var code := 1
			if f != null:
				code = int(str(f.get_as_text()).strip_edges())
				f.close()
			return code
	if OS.is_process_running(pid):
		OS.kill(pid)
	push_error("%s: 子进程超过 %d 秒未完成 —— 已强杀（CP-SAT 单次 Solve 无中止接口）" % [
		file, CHILD_TIMEOUT_MS / 1000])
	return 2


## 子进程模式：`-- child <spec.json> <marker>` —— 只生成规格里的那一关，把退出码写进 marker。
func _run_child_mode() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 3:
		push_error("child 模式用法：-- child <spec.json> <marker>")
		_request_exit(2)
		return
	var spec_file := FileAccess.open(str(a[1]), FileAccess.READ)
	if spec_file == null:
		push_error("child: 读不到规格 %s" % str(a[1]))
		_request_exit(2)
		return
	var parsed: Variant = JSON.parse_string(spec_file.get_as_text())
	spec_file.close()
	var code := 1
	if parsed is Dictionary:
		var c: Dictionary = parsed
		code = 0 if _gen_one(c) else 1
	else:
		push_error("child: 规格不是字典 %s" % str(a[1]))
	var mf := FileAccess.open(str(a[2]), FileAccess.WRITE)
	if mf != null:
		mf.store_string(str(code))
		mf.close()
	_request_exit(code)


## 只探不产（决策用）：对（规则 × 形状）在固定雷数下扫 seed，打印每个 seed 的峰值与各档
## 命中统计。**不写任何文件**。用途：给定向档位选形状/雷数提供数据——先看某组合的峰值
## 分布能否覆盖目标档，再决定跑不跑（避免盲目跑几十轮才发现该组合不可行）。
## 参数：--rule=a,b --shape=holed_grid,hex --seeds=12 [--mines=N]
func _probe(_reg: Object) -> void:
	var rules: Array = _ARGS["rules"] if not (_ARGS["rules"] as Array).is_empty() else _rule_ids()
	var shapes: Array = _ARGS["shapes"] if not (_ARGS["shapes"] as Array).is_empty() \
			else ["holed", "hex"]
	var seeds := int(_ARGS["seeds"])
	var seed_base := int(_ARGS["seed0"])
	print("=== 定向档位 probe（只探不产；每组合 %d 个 seed，seed0=%d）===" % [seeds, seed_base])
	print("  判档窗口：%s" % _windows_text())
	for rule in rules:
		var rid := str(rule)
		if _rule_by_id(rid).is_empty():
			print("  !! 未知规则：%s" % rid)
			continue
		for shape in shapes:
			var sh := str(shape)
			var spec := _shape_spec(sh)
			if spec.is_empty():
				print("  !! 未知形状：%s（合法：%s）" % [sh, ", ".join(SHAPES.keys())])
				continue
			if _shape_kind(sh) == SHAPE_HOLED and (rid == "s4" or rid == "s6"):
				continue   # 既有实测排除（6×6 与 holed7 均全空）
			var topo: AdjacencyGrid = ShapeGenerator.to_adjacency_grid(str(spec["kind"]), spec["params"])
			if topo == null:
				print("  !! %s × %s：形状构建失败" % [rid, sh])
				continue
			topo = AdjacencyGrid.normalized(topo)
			var n := topo.cell_count()
			var mines := int(_ARGS["mines"]) if int(_ARGS["mines"]) > 0 \
					else maxi(1, int(round(float(n) * 0.3)))
			var gen := PuzzleGenerator.new()
			var hist := {"easy": 0, "normal": 0, "hard": 0, "": 0}
			var peaks: Array = []
			var t0 := Time.get_ticks_msec()
			for s in seeds:
				var cand: Dictionary = gen.generate_with_rules(
						"classic", [rid], topo.size(), mines, seed_base + s, 0, ATTEMPTS,
						topo, GEN_TIMEOUT_MS)
				if cand.is_empty():
					peaks.append(-1)
					continue
				var prof: Dictionary = cand.get("difficulty_profile", {})
				peaks.append(int(prof.get("max_complexity", -1)))
				var tt := _tier_of(prof)
				hist[tt] = int(hist[tt]) + 1
			var secs := float(Time.get_ticks_msec() - t0) / 1000.0
			print("  %s × %s：%d 格 · %d 雷 · %.1f s" % [rid, sh, n, mines, secs])
			print("    峰值序列：%s" % str(peaks))
			print("    命中：easy=%d normal=%d hard=%d 不入档=%d" % [
				int(hist["easy"]), int(hist["normal"]), int(hist["hard"]), int(hist[""])])


## 读画像定档（唯一事实源 core/difficulty.gd；运行期 load——`-s` 脚本编译期早于 autoload，
## 静态引用全局类有坑，与 _proof_ok 同策略）。拿不到脚本时返回 ""——定向模式会因
## 「判不了档」而失败，好过按错误档位落盘（宁可红灯也不留错档产物）。
func _tier_of(prof: Dictionary) -> String:
	var d := _difficulty()
	if d == null:
		return ""
	var v: Variant = d.call("tier_of_profile", prof)
	return "" if v == null else str(v)


func _tier_range(tier: String) -> Vector2i:
	var d := _difficulty()
	if d == null:
		return Vector2i.ZERO
	var v: Variant = d.call("tier_range", tier)
	return v if v is Vector2i else Vector2i.ZERO


func _windows_text() -> String:
	var parts: Array = []
	for t in TIER_NAMES:
		var rg := _tier_range(str(t))
		parts.append("%s[%d,%d]" % [str(t), rg.x, rg.y])
	return " ".join(parts)


var _difficulty_cache: GDScript = null


func _difficulty() -> GDScript:
	if _difficulty_cache == null:
		_difficulty_cache = load("res://core/difficulty.gd")
	return _difficulty_cache


## 定向模式的雷数偏移序列（基准 = --mines 或 n×0.3 的 round）。
## easy 先往**低**走（降雷 = 降推理深度），hard 先往**高**走（升雷 = 升深度），
## normal 双向交替；每档都保留 0（基准）居首以尽量少动密度。
## hard 额外保留 −2/−4：有些规则自带**整除要求**（如 z3 四象限雷数相等 ⇒ 偶数盘雷数
## ≡0 mod 4），基准 10 雷这类值对它们永远不可行——只往加雷扫会把整档扫空。
## 偏移生效前还要过 min/max 两道密度闸（超界的档直接跳过）——故这里可以列得比可行域宽。
func _bumps_for(tier: String) -> Array:
	match tier:
		"easy":
			return [0, -1, -2, -3, -4, 1, 2]
		"normal":
			return [0, 1, -1, 2, -2, 3, -3]
		"hard":
			return [0, 1, 2, 3, 4, -2, -4]
	return range(MAX_MINES_BUMP + 1)


## ProofLog 复核（测试门禁同款推演器）。运行期 load：-s 脚本的编译期依赖有坑（见 _load_level）。
func _proof_ok(level: Dictionary) -> bool:
	var pl: GDScript = load("res://core/proof_log.gd")
	if pl == null:
		# 推演器拿不到时**按失败处理**（fail-fast，2026-09-25）：proof 复核是产线
		# 最后一道闸，闸坏了还放行 = 产出**未验证**的盘——而「门禁兜底」要等全量回归
		# 才能发现，跑批时未必在跑回归。load 失败只发生在文件缺失/编译错误，
		# 那说明环境已坏：宁可停产，也不产未验证的盘。
		push_error("proof_log.gd 加载失败——无法复核序贯可解，按失败处理（检查仓库完整性）")
		return false
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
		# autoload（含 mod 规则装配）此刻已就绪。
		# child 模式 = 进程隔离的**子进程侧**：命令行形如 `-- child <spec.json> <marker>`，
		# 只生成一关、写完成标记、退出。首参数不是 child 就走正常批次流程。
		var ca := OS.get_cmdline_user_args()
		if ca.size() >= 1 and str(ca[0]) == "child":
			_run_child_mode()
		else:
			_run()
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
