# import_shape_levels_to_lib.gd —— 异形关卡（res://levels/ 里带 topology.style 的关卡）
# → 正式关卡库（levels_lib/shape_holed/<size>/easy.json、levels_lib/shape_hex/<size>/easy.json）。
#
# 为什么需要它（接线任务）：形状关由 tools/gen_shape_levels.gd 产到 res://levels/，而选关页只认
# 关卡库（levels_lib/：catalog.json 索引 + 一集一文件 <mode>/<size>/<tier>.json）——这条通道
# 此前不存在 ⇒「形状关已产出」但**游戏里没有入口**，玩家找不到、玩不到这 11 关。
# 本工具是那座桥（与 tools/import_batch_to_lib.gd 同族：那个的源是 user://batch_all 批量目录，
# 本工具的源是 res://levels/ 一关一文件 + 带形状拓扑）。
#
# 用法： godot --headless --path . -s res://tools/import_shape_levels_to_lib.gd
#
# 行为（全自动、无参数）：
#   1) 扫 res://levels/*.json 中带 topology.style 的关卡（不硬编码文件名；矩形关原样不受影响）；
#   2) style → mode：holed_grid → shape_holed、hex → shape_hex；其他 style 打印后跳过；
#   3) 尺寸 = 棋盘包围盒最长边（方阵族须 rows==cols；新几何族允许条带形）；
#      产出侧白名单（源文件名前缀）+ 库尺寸窗（5~9）双重过滤，越界关不入库（留在手工异形页）；
#   4) 每个 (mode, size) 按峰值档位写集文件 <mode>/<size>/<tier>.json（levels 按难度升序；
#      覆盖写；tier = Difficulty.tier_of_profile，peak 落窗 easy/normal/hard，缺画像/超纲跳过）；
#   5) catalog.json 的**全部已登记 shape mode 的条目**全量重建（其余 mode 原值、外层结构与 schema 键不动）；
#   6) 逐关自校验：写盘后重读集文件，把每一关物化成临时文件交给 LevelLoader.load_level → Board
#      （且棋盘必须是 AdjacencyGrid）；不成立则整关剔除并计数（有剔除 → 退出码 1，不静默）；
#   7) 打印摘要表（mode × size × 关数 × 关卡名）与 === SHAPE-IMPORT-OK === 判据串。
#
# 幂等：覆盖写、无时间戳/随机；集内排序（难度 → seed → 文件名）确定 ⇒ 重复跑结果一致。
#
# 退出方式（同 tools/gen_shape_levels.gd，附实测理由）：本工程 -s 脚本「跑完不退出」，
# 而 tools/cli_shutdown.gd 的看门狗在本机（4.7.2 mono）会把**成功也变成退出码 1**
# （它在 quit() 前 OS.execute 起 `cmd /c ping … & taskkill /pid`，进程被看门狗强杀）。
# 故这里只借用它的策略：flush stdout、先打印成功标记，再延后 3 帧 quit(code)——
# 退出码如实反映成功/失败，看门狗不装。
extends SceneTree

const LEVELS_DIR := "res://levels"
const LIB_DIR := "res://levels_lib"
const CATALOG_PATH := LIB_DIR + "/catalog.json"
## 档位策略（2026-09-22 定稿）：**按峰值分档**，不走单一 easy——形状关的画像已经拉宽
## （iso_01 peak 5、ring_01 peak 7），硬塞进 easy 会把 normal/hard 的盘端进浅档
## （_check_level 的档位校验会剔除它们 → 玩家反而玩不到）。集文件按
## Difficulty.tier_of_profile 的三档口径落位，与 test_level_lib_contract 的档位复核同源；
## 无 difficulty_profile 画像 / peak 超纲（PEAK_OVER）的关不入库（留在手工异形页可玩）。
## style → 库内 mode id（= 选关页 MODES[].id；与 ui/variant_catalog.gd 的 shape 卡片一一对应）。
## 形状是**拓扑层**，不是规则轴：这里按 style 分组，而不是按 clue_rule/global_rules 推导。
## 注册表扩展（2026-09-22）：新几何族 + 不入库的风格/变体产物（见下列表）。
## - shape_holed / shape_hex：参数化形状（既有，test_shape_library 钉全尺寸契约）
## - shape_iso / shape_tri / shape_trihex / shape_t31212 / shape_ring：新几何族
##   （custom_shapes 多边形几何 + 圈层分色，尺寸 = 棋盘 bbox 边数，仅入库实际落盘的尺寸）
## - t488 / iso_cubes / tri_grid / trihex / t31212 / ring 的 sty_* / va_* 风格或变体关
##   （gen_style_shape_levels / gen_variant_shape_levels 产物）**不入库**——它们走
##   ui/level_select._shape_levels() 的"手工异形页"（按变体分组、直接点卡开局）；
##   登记它们会把少量风格关误灌进经典形状档。tri_grid/trihex/t31212/ring 只对
##   gen_geo_levels 产的纯 classic 关（文件名无 vg_ 前缀）入库。
const STYLE_TO_MODE := {
	"holed_grid": "shape_holed",
	"hex": "shape_hex",
	"iso_cubes": "shape_iso",
	"tri_grid": "shape_tri",
	"trihex": "shape_trihex",
	"t488": "shape_t488",
	"t31212": "shape_t31212",
	"ring": "shape_ring",
}
## 库内合法的档位名（catalog 重建时只认它们，与 tools/import_batch_to_lib.gd / LevelLibrary.TIER_ORDER 同口径）。
const TIERS: Array = ["easy", "normal", "hard"]

## 加载器/库的**运行期** load（与 gen_shape_levels.gd 同因）：
## `-s` 工具脚本在 autoload 注册**之前**编译，而 ui/level_loader.gd 直接引用 autoload 标识符
## ModAPI → 编译期连带失败（实测：SCRIPT ERROR "Identifier not found: ModAPI"）。
## 运行期 load（autoload 已就绪）+ GDScript.call 派发静态方法即可正常编译。
const LEVEL_LOADER_PATH := "res://ui/level_loader.gd"
const LEVEL_LIBRARY_PATH := "res://ui/level_library.gd"
## 自校验临时目录（每关物化一份，验完即删）。
## 2026-09-22：从 user:// 改到 res://levels_lib/.tmp_check —— user:// 落在 OS 的
## 应用数据目录，CI/沙箱环境可能整盘只读（实测：写不进时 17 个集被全部误剔除、
## catalog 被清空）；本工具开头已拦截导出运行时（res:// 只读场景），开发机/headless
## 下 res:// 必可写，而 levels_lib 本来就是本工具的写入目标，风险等价且受控。
const CHECK_DIR := "res://levels_lib/.tmp_check"

## 退出前等待的帧数（cli_shutdown.FRAMES_BEFORE_EXIT 同值：让 autoload 初始化完毕再退）。
const EXIT_FRAMES := 3

var _exit_code := 0
var _exit_pending := false
var _exit_frames := 0

## mode → size → Array[{level: Dictionary, src: String}]
var _bag: Dictionary = {}
var _scanned := 0                    # res://levels 下带 topology.style 的关卡数
var _skipped_style: Array = []       # 未登记的 style（打印后跳过）
var _skipped_shape: Array = []       # 形状数据本身不合法（非方形 / 尺寸非法）
var _skipped_scope: Array = []       # 不属于本工具入库范围（前缀白名单外 / 尺寸越界 5~9）
var _skipped_dup := 0                # 同 (mode,size) 内重复 seed
## 本次扫描到的源关卡 seed 集合（TM10：僵尸关报告——库内有、源已无的关）。
var _src_seeds: Dictionary = {}
var _removed := 0                    # 写后自校验不通过被剔除的关数
var _removed_why: Array = []         # 剔除原因（前 8 条进报告）
var _fatal := false
## catalog 里两个形状 mode 的**改动前**快照（报告用）。
var _cat_before: Dictionary = {}


func _initialize() -> void:
	# 导出后 res:// 只读：本工具全程写 res://levels_lib，在 pck 运行时里会静默失败。
	if OS.has_feature("template"):
		push_error("[shape-import] 当前运行在导出后的运行时里：res:// 只读，无法入库。请在开发机（编辑器 / headless 工具）运行本工具。")
		_request_exit(1)
		return
	print("[shape-import] 源=%s  目标=%s（shape mode %d 个，按峰值分档 easy/normal/hard）" % [
		LEVELS_DIR, LIB_DIR, STYLE_TO_MODE.size()])
	_cat_before = _snapshot_catalog_modes()
	_scan_levels()
	_write_sets()
	_rebuild_catalog()
	_verify_index()
	_report_zombies()
	_report()
	if _fatal or _removed > 0:
		_request_exit(1)
		return
	print("=== SHAPE-IMPORT-OK ===")
	_request_exit(0)


func _process(_delta: float) -> bool:
	if not _exit_pending:
		return false
	_exit_frames += 1
	if _exit_frames < EXIT_FRAMES:
		return false
	quit(_exit_code)
	return true


## 登记退出（不是立刻退）：等几帧让 autoload/引擎初始化完毕；先打印成功标记再退。
## flush_stdout_on_print 必须打开——stdout 重定向到文件时是全缓冲，日志可能丢尾（cli_shutdown 同款）。
func _request_exit(code: int) -> void:
	ProjectSettings.set_setting("application/run/flush_stdout_on_print", true)
	_exit_code = code
	_exit_frames = 0
	_exit_pending = true


# ==================== 1. 扫源 ====================

## 扫 res://levels/*.json 中**带 topology.style** 的关卡（不硬编码文件名）。
## 判据 = topology 是字典且有 style：矩形关没有 topology 字段，天然不受影响。
func _scan_levels() -> void:
	var d := DirAccess.open(LEVELS_DIR)
	if d == null:
		push_error("[shape-import] 打不开源目录: %s" % LEVELS_DIR)
		_fatal = true
		return
	var names := d.get_files()
	names.sort()                       # 确定性：同盘同序（幂等的一部分）
	for fname in names:
		var fn := str(fname)
		if not fn.ends_with(".json"):
			continue
		var src := "%s/%s" % [LEVELS_DIR, fn]
		var lv := _read_json(src)
		var topo: Variant = lv.get("topology")
		if not (topo is Dictionary) or not (topo as Dictionary).has("style"):
			continue                   # 非形状关（无 topology）——本工具不管
		_scanned += 1
		_src_seeds[int(lv.get("seed", -1))] = true
		var style := str((topo as Dictionary)["style"])
		var mode := str(STYLE_TO_MODE.get(style, ""))
		if mode == "":
			# 审计修复（2026-09-21）：**形状关但 style 未登记** = 该关永远入不了库（内容静默缺失），
			# 原实现只汇总 print 且退出码 0。改为红灯：要么登记 STYLE_TO_MODE，要么改关卡数据。
			_skipped_style.append("%s(style=%s)" % [fn, style])
			push_error("[shape-import] 形状关 %s 的 style \"%s\" 未登记进 STYLE_TO_MODE —— 无法入库" % [fn, style])
			_fatal = true
			continue
		# 尺寸 = 棋盘包围盒的「最长边」（库尺寸键是单 int）。条带形新族（tri_grid 8x4、
		# ring 12x3、iso_cubes 9x3 等）rows != cols 是合法形态 —— 用 max(cols, rows) 归一。
		# 判据：style 是参数化方阵族（holed_grid/hex/t488）→ 必须 rows == cols；
		# 其余（custom_shapes 多边形几何族）→ 非方形允许。
		# 产出侧白名单（2026-09-22）：只收「纯 classic 形状关」——gen_shape_levels（holed_/hex_）、
		# gen_geo_levels（iso_/tri_/trihex_/t31212_/ring_）与 mask 图案关（art_）。
		# sty_*/va_*/vg_* 是风格/变体产物（带 clue_rule / global_rules），属于手工异形页的
		# 变体分组（ui/level_select._shape_levels 按 shape_kind/变体分组）；登记它们会把
		# 少量变体关误灌进「classic-only」的形状档（mode 语义 = 拓扑层 + 经典线索）。
		# 白名单外的带 style 文件记数跳过、不 fatal——它们由手工异形页直接供给，不是本工具的入库对象。
		var prefix_ok := false
		# 2026-09-23 审计：**art_ 显式移出白名单**（而非依赖尺寸窗的副作用）。art_ 三关已升级到
		# 17~21 格的高分辨率图案关，定位为选关页「异形棋盘」页的固定成品；留在白名单里，一旦
		# 有人放宽尺寸窗或把分辨率调回 ≤9，它们会静默回库。
		for pre in ["holed_", "hex_", "iso_", "tri_", "trihex_", "t31212_", "ring_"]:
			if fn.begins_with(str(pre)):
				prefix_ok = true
				break
		if not prefix_ok:
			_skipped_scope.append(fn)
			continue
		var size_d: Variant = lv.get("size")
		var rows := 0
		var cols := 0
		if size_d is Dictionary:
			rows = int((size_d as Dictionary).get("rows", 0))
			cols = int((size_d as Dictionary).get("cols", 0))
		if rows <= 0 or cols <= 0:
			_skipped_shape.append("%s(尺寸非法 %d×%d)" % [fn, cols, rows])
			push_error("[shape-import] 形状关 %s 尺寸非法（%d×%d）—— 无法入库" % [fn, cols, rows])
			_fatal = true
			continue
		if rows != cols and (style == "holed_grid" or style == "hex" or style == "t488"):
			_skipped_shape.append("%s(非方形 %d×%d，库尺寸键是单 int)" % [fn, cols, rows])
			push_error("[shape-import] 形状关 %s 非方形（%d×%d）—— 库尺寸键是单 int，无法入库" % [fn, cols, rows])
			_fatal = true
			continue
		var side := rows
		if cols > side:
			side = cols
		# 库尺寸窗（2026-09-22）：选关页弹窗只认 SIZES=[5,6,7,8,9]，越界席位（t31212 的
		# 37/51 宽 bbox、ring 的 12/18、tri_02 的 12、trihex_02 的 11、iso_02~05 的 12~15）
		# 进了库也永远显示不出来，还会触发 test_level_lib_contract 的孤儿席位红灯。
		# 记数跳过（非 fatal）——这些关仍在手工异形页可玩；扩窗后重跑导入即可收录。
		if side < 5 or side > 9:
			_skipped_scope.append("%s(side=%d 越界 5~9)" % [fn, side])
			continue
		_put(mode, side, lv, fn)


## 收一关进 _bag（同 (mode,size) 内按 seed 去重——重复导入同一批不会产生重复关卡）。
func _put(mode: String, size: int, lv: Dictionary, src_name: String) -> void:
	# 峰值画像缺失 / peak 超纲（tier_of_profile == ""）= 无档可归，不入库（记数跳过，非 fatal）。
	# 与 _write_sets 的按档分组、_check_level 的档位闸门同口径（三处都判 tier == ""，双保险）。
	if Difficulty.tier_of_profile(lv.get("difficulty_profile", {})) == "":
		_skipped_scope.append("%s(无峰值画像/超纲)" % src_name)
		return
	var by_size: Dictionary = _bag.get(mode, {})
	var arr: Array = by_size.get(size, [])
	var seed_v := int(lv.get("seed", -1))
	for item in arr:
		if int(((item as Dictionary)["level"] as Dictionary).get("seed", -2)) == seed_v:
			_skipped_dup += 1
			# M7（2026-09-21 审计修复）：同 (mode,size) 内**两个源文件同 seed** 是数据问题
			# （spec 的 base_seed 区间重叠 / 手工复制了关卡文件）。静默跳过会让库少一关、
			# 源与库的计数不符。红灯：请改 spec 的 base_seed（或删掉重复文件）。
			# 注：本工具每轮都重建 _bag，重复导入同一批**不会**触发这里（每个文件只扫一次）。
			push_error("[shape-import] seed 重复（%d）：%s —— 同 (mode,size) 内已有同 seed 关卡，请改 spec 的 base_seed" % [
				seed_v, src_name])
			_fatal = true
			return
	arr.append({"level": lv, "src": src_name})
	by_size[size] = arr
	_bag[mode] = by_size


# ==================== 2. 写集文件 + 3. 逐关自校验 ====================

## 每个 (mode, size, tier) 写一个集文件 <mode>/<size>/<tier>.json（覆盖写，幂等）。
## tier 由逐关的峰值画像决定（Difficulty.tier_of_profile），同 (mode,size) 可落多个档；
## 写盘后逐关自校验（重读集文件 → 物化 → LevelLoader.load_level）：坏关整关剔除并计数，
## 剔除后重写集文件；一关不剩则删集文件（不让空集进库、更不让 catalog 记空席）。
func _write_sets() -> void:
	var modes: Array = _bag.keys()
	modes.sort()
	for mode in modes:
		var by_size: Dictionary = _bag[mode]
		var sizes: Array = by_size.keys()
		sizes.sort()
		for size in sizes:
			# 按峰值档位分组（每关 tier = tier_of_profile；_put 时已把无画像关挡在 _bag 外）
			var by_tier: Dictionary = {}
			for item: Dictionary in by_size[size]:
				var lv: Dictionary = item["level"]
				var tier := Difficulty.tier_of_profile(lv.get("difficulty_profile", {}))
				if tier == "":
					continue
				var arr: Array = by_tier.get(tier, [])
				arr.append(item)
				by_tier[tier] = arr
			var tier_keys: Array = by_tier.keys()
			tier_keys.sort()
			for tier_s in tier_keys:
				var items: Array = by_tier[tier_s]
				# 集内按难度升序（与库既有集同口径：选关页按序推进）；同值按 seed、再按文件名（确定性）
				items.sort_custom(_item_less)
				var rel := "%s/%d/%s.json" % [str(mode), int(size), str(tier_s)]
				var dst := "%s/%s" % [LIB_DIR, rel]
				_write_set(dst, str(mode), int(size), _levels_of(items), rel)


func _levels_of(items: Array) -> Array:
	var out: Array = []
	for item in items:
		out.append((item as Dictionary)["level"])
	return out


## 排序判据（升序）：difficulty → seed → 源文件名。三项都定死 ⇒ 重复跑逐字节一致。
func _item_less(a: Variant, b: Variant) -> bool:
	var la: Dictionary = (a as Dictionary)["level"]
	var lb: Dictionary = (b as Dictionary)["level"]
	var da := _difficulty_of(la)
	var db := _difficulty_of(lb)
	if da != db:
		return da < db
	var sa := int(la.get("seed", -1))
	var sb := int(lb.get("seed", -1))
	if sa != sb:
		return sa < sb
	return str((a as Dictionary)["src"]) < str((b as Dictionary)["src"])


func _difficulty_of(lv: Dictionary) -> float:
	var prof: Dictionary = lv.get("difficulty_profile", {})
	return float(prof.get("difficulty", 0.0))


## 写一个集文件（先写、再重读校验、必要时剔除重写）。返回实写关数（0 = 未入库/被清空）。
func _write_set(dst: String, mode: String, size: int, levels: Array, rel: String) -> int:
	if DirAccess.make_dir_recursive_absolute(dst.get_base_dir()) != OK:
		push_error("[shape-import] 建目录失败: %s" % dst.get_base_dir())
		_fatal = true
		return 0
	if not _store(dst, mode, size, levels):
		_fatal = true
		return 0
	# 自校验：重读**盘上那一份**（不是内存里的），逐关物化给真实加载器
	var on_disk := _read_json(dst)
	var disk_levels: Array = on_disk.get("levels", [])
	var good: Array = []
	for i in disk_levels.size():
		var lv: Dictionary = disk_levels[i] if disk_levels[i] is Dictionary else {}
		var why := _check_level(mode, size, i, lv)
		if why == "":
			good.append(lv)
		else:
			_removed += 1
			if _removed_why.size() < 8:
				_removed_why.append("%s[%d] %s: %s" % [rel, i, str(lv.get("name", "?")), why])
			push_warning("[shape-import] 剔除 %s[%d]（%s）: %s" % [rel, i, str(lv.get("name", "?")), why])
	if good.size() == disk_levels.size():
		print("[shape-import]   %s + %d 关（自校验 %d/%d 通过）" % [rel, good.size(), good.size(), disk_levels.size()])
		return good.size()
	if good.is_empty():
		push_warning("[shape-import] %s：全部关卡未通过自校验，集文件已删除（不入库、不记 catalog）" % rel)
		if FileAccess.file_exists(dst):
			DirAccess.remove_absolute(dst)
		return 0
	print("[shape-import]   %s + %d 关（自校验剔除 %d 关后重写）" % [
		rel, good.size(), disk_levels.size() - good.size()])
	if not _store(dst, mode, size, good):
		_fatal = true
		return 0
	return good.size()


## 落盘一份集文件（schema 与 levels_lib 既有集一致：count/levels/mode/size/tier）。
func _store(dst: String, mode: String, size: int, levels: Array) -> bool:
	# TM2（2026-09-21 审计修复）：levels 过 int 归一 —— JSON.parse_string 把整数读成 float，
	# 原样重写会让库内 "total_mines": 10 变成 10.0（与 catalog 的 int 化口径自相矛盾，
	# 也与 import_batch_to_lib 的产物不一致）。
	var doc := {"mode": mode, "size": size, "tier": dst.get_file().get_basename(),
			"count": levels.size(), "levels": _int_value_normalized(levels)}
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		push_error("[shape-import] 写不了: %s" % dst)
		return false
	f.store_string(JSON.stringify(doc, "  "))
	f.close()
	return true


## 单关自校验（写盘后口径）：物化到临时文件 → LevelLoader.load_level → Board（且须是异形棋盘）。
## 返回 "" = 通过；否则返回失败原因（进报告，不静默）。
func _check_level(mode: String, size: int, idx: int, lv: Dictionary) -> String:
	if lv.is_empty():
		return "集内该条不是字典"
	# 几何指纹复核用的 style 从关卡数据自取（函数签名不收 style，防调用点漏传）。
	var topo_c: Dictionary = lv.get("topology", {})
	var style := str(topo_c.get("style", ""))
	if DirAccess.make_dir_recursive_absolute(CHECK_DIR) != OK:
		return "临时目录建不出来: %s" % CHECK_DIR
	var tmp := "%s/%s_%d_%d.json" % [CHECK_DIR, mode, size, idx]
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return "临时文件写不了: %s" % tmp
	f.store_string(JSON.stringify(lv, "  "))
	f.close()
	var board := _load_level(tmp)
	var why := ""
	if board == null:
		why = "LevelLoader.load_level 返回 null"
	elif not (board.grid is AdjacencyGrid):
		why = "board.grid 不是 AdjacencyGrid（实际 %s）" % str(board.grid)
	elif Difficulty.tier_of_profile(lv.get("difficulty_profile", {})) == "":
		# 峰值画像缺失 / peak 超纲（PEAK_OVER）= 无档可归——不入库（留在手工异形页可玩）。
		# 与 v4.1 三档窗口同源（core/difficulty.gd）：easy [2,3] / normal [4,5] / hard [6,20]。
		why = "无档可归（峰值画像缺失或 peak 超纲）"
	elif board.total_mines != int(lv.get("total_mines", -1)):
		why = "board.total_mines=%d ≠ JSON %d" % [board.total_mines, int(lv.get("total_mines", -1))]
	else:
		# M12（2026-09-21 审计修复）：按 style 复核**几何指纹**，防"手写拓扑 + 错标 style"混入库。
		# 判据取度数上限（必要非充分）：holed_grid ≤ 8（Moore）、hex ≤ 6（HEX6）、t488 ≤ 8、
		# tri_grid ≤ 3、trihex ≤ 6、t31212 ≤ 12、ring ≤ 6、iso_cubes ≤ 4（共边反推的几何上限）。
		# 足以拦住"把 8 邻方格盘标成蜂窝"这类错标。
			var deg_cap: int = int({"holed_grid": 8, "hex": 6, "t488": 8, "tri_grid": 3, "trihex": 6, "t31212": 12, "ring": 6, "iso_cubes": 4}.get(style, 0))
			if deg_cap > 0:
				for p in board.grid.all_positions():
					if board.grid.get_neighbors(p).size() > deg_cap:
						why = "style=%s 的格 (%d,%d) 度 %d > 上限 %d（几何指纹不符，疑似错标 style）" % [
							style, p.x, p.y, board.grid.get_neighbors(p).size(), deg_cap]
						break
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)
	return why


# ==================== 4. catalog 重建（只动已登记的 shape mode） ====================

## catalog.json 的**全部已登记 shape mode 的条目**全量重建：
##   · 其余 mode 原值、外层结构（{"schema":…, "catalog":{…}}）与 schema 键都不动；
##   · 条目来源 = 扫盘上这些 mode 的集文件（而不是「本轮想写的」）——
##     剔除过坏关的集、或人手补进来的档位都能被如实索引（catalog 与盘上内容永远一致）；
##   · 某 mode 一关都不剩 → 从索引里**移除**该键（选关页据此不显示空形状卡，见 variant_catalog）。
func _rebuild_catalog() -> void:
	var doc: Dictionary = {}
	if FileAccess.file_exists(CATALOG_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
		if not (parsed is Dictionary):
			# 审计修复（2026-09-21）：**绝不从零重建**。catalog 被截断/写坏时若静默从 {} 起步，
			# 本次写盘会把其余 10 个 mode 的索引与 schema 全抹掉（不可逆），而工具还报 OK。
			push_error("[shape-import] catalog.json 解析失败（非字典）：%s —— 拒绝重建；\n"
					% CATALOG_PATH + "请先人工修复或删除该文件后重跑（其它 mode 的索引不能靠猜重建）")
			_fatal = true
			return
		doc = parsed
	# Godot 的 JSON.parse_string 把**所有数字都读成 float** ⇒ 直接回写会把其他 mode 的计数
	# 从 "47" 变成 "47.0"（外加 schema 4 → 4.0），整份 catalog 逐行翻新、审查时看不出真改了什么。
	# 先做一次整数值还原（非整数值如难度原样保留），让「保留其他 mode 原值」在**文本上**也成立。
	doc = _int_value_normalized(doc)
	var cat: Dictionary = {}
	var c: Variant = doc.get("catalog")
	if c is Dictionary:
		cat = c
	for style in STYLE_TO_MODE:
		var mode := str(STYLE_TO_MODE[style])
		var entry := _scan_mode_dir(mode)
		if entry.is_empty():
			cat.erase(mode)
		else:
			cat[mode] = entry
	doc["catalog"] = cat
	var f := FileAccess.open(CATALOG_PATH, FileAccess.WRITE)
	if f == null:
		push_error("[shape-import] catalog 写不了: %s" % CATALOG_PATH)
		_fatal = true
		return
	f.store_string(JSON.stringify(doc, "  "))
	f.close()
	print("[shape-import] catalog 已更新（shape mode %d 键；其他 %d 个 mode 原值未动）" % [_shape_mode_count(cat), cat.size() - _shape_mode_count(cat)])


## 扫 levels_lib/<mode>/<size>/<tier>.json → {"<size>": {"<tier>": count}}（空 = 该 mode 无内容）。
func _scan_mode_dir(mode: String) -> Dictionary:
	var entry: Dictionary = {}
	var mode_dir := "%s/%s" % [LIB_DIR, mode]
	var sd := DirAccess.open(mode_dir)
	if sd == null:
		return entry
	var size_dirs: Array = sd.get_directories()
	size_dirs.sort()   # L3（2026-09-21）：显式排序——catalog 键序不能依赖文件系统返回序（跨机幂等）
	for size_dir in size_dirs:
		var side := str(size_dir).to_int()
		if str(size_dir) != str(side) or side <= 0:
			continue                     # 尺寸目录名必须是纯整数（与 LevelLibrary 的键同口径）
		var td := DirAccess.open("%s/%s" % [mode_dir, size_dir])
		if td == null:
			continue
		var fnames: Array = td.get_files()
		fnames.sort()   # L3（2026-09-21）：同上（同机幂等的一部分）
		for fname in fnames:
			var fn := str(fname)
			if not fn.ends_with(".json"):
				continue
			var tier := fn.get_basename()
			if not TIERS.has(tier):
				continue                 # 只认三档名（其余命名一概不索引）
			# 审计修复（2026-09-21）：计数**以 levels 数组长度为准**，而不是文件里的 count 字段——
			# 原来 count 与索引同源（都读 count）⇒ `count ≠ levels.size()` 的坏集文件永远测不出来
			# （选关页会露出读不出的空席位）。count 字段与长度不符 → 红灯。
			var set_doc: Dictionary = _read_json("%s/%s/%s" % [mode_dir, size_dir, fn])
			var lv_arr: Array = set_doc.get("levels", [])
			var n := lv_arr.size()
			if set_doc.has("count") and int(set_doc["count"]) != n:
				push_error("[shape-import] 集文件 count 字段(%d) ≠ levels 长度(%d)：%s/%s/%s" % [
					int(set_doc["count"]), n, mode_dir, size_dir, fn])
				_fatal = true
			if n <= 0:
				continue
			var by_tier: Dictionary = entry.get(str(side), {})
			by_tier[tier] = n
			entry[str(side)] = by_tier
	return entry


## 索引一致性核对：LevelLibrary.count(mode, size, tier)（**读 catalog**）必须等于集文件里实际写下的关数
## （**读盘**）。不一致 = 索引与盘上内容脱钩（选关页会显示不存在的关，或漏掉已入库的关）→ 红灯，不静默。
## TM10（2026-09-21 审计修复）：僵尸关报告——库里存在、但 res://levels/ 源已不存在（spec 被删/改名）
## 的关卡。它们会一直留在集文件与 catalog 里（选关页能玩到"已下架"的盘），且无自动清除机制。
## 只报告不自动清理（可能有人手工补关）：数量与样例进日志，便于人工决定是否清库重导。
## 不置 _fatal —— 僵尸关不影响玩家体验，只提示维护动作。
func _report_zombies() -> int:
	var zombies := 0
	var samples: Array = []
	for style in STYLE_TO_MODE:
		var mode := str(STYLE_TO_MODE[style])
		var mode_dir := "%s/%s" % [LIB_DIR, mode]
		var sd := DirAccess.open(mode_dir)
		if sd == null:
			continue
		var size_dirs: Array = sd.get_directories()
		size_dirs.sort()
		for size_dir in size_dirs:
			var td := DirAccess.open("%s/%s" % [mode_dir, size_dir])
			if td == null:
				continue
			var fnames: Array = td.get_files()
			fnames.sort()
			for fname in fnames:
				var fn := str(fname)
				if not fn.ends_with(".json"):
					continue
				var lvs: Array = _read_json("%s/%s/%s" % [mode_dir, size_dir, fn]).get("levels", [])
				for lv: Dictionary in lvs:
					if not _src_seeds.has(int(lv.get("seed", -1))):
						zombies += 1
						if samples.size() < 5:
							samples.append("%s/%s/%s: %s（seed=%s）" % [
								mode, size_dir, fn, str(lv.get("name", "?")), str(lv.get("seed", "?"))])
	if zombies > 0:
		print("[shape-import] ⚠ 僵尸关（库内有、源已无）：%d 关 —— 若为误删/改名请重跑生成后重导，或人工从集文件移除" % zombies)
		for smp in samples:
			print("[shape-import]    %s" % str(smp))
	return zombies


func _verify_index() -> void:
	for style in STYLE_TO_MODE:
		var mode := str(STYLE_TO_MODE[style])
		var entry := _scan_mode_dir(mode)
		var sets := 0
		var total := 0
		for size_s in entry:
			var side := int(str(size_s))
			for tier in entry[size_s]:
				var disk_n := int(entry[size_s][tier])
				var idx_n := _lib_count(mode, side, str(tier))
				sets += 1
				total += disk_n
				if idx_n != disk_n:
					push_error("[shape-import] 索引不一致：LevelLibrary.count(%s, %d, %s)=%d ≠ 集文件实写 %d" % [
						mode, side, str(tier), idx_n, disk_n])
					_fatal = true
		if sets > 0:
			print("[shape-import] 核对 %s：%d 个集 / %d 关（catalog 计数 == 集文件实写数）" % [mode, sets, total])


func _shape_mode_count(cat: Dictionary) -> int:
	var n := 0
	for style in STYLE_TO_MODE:
		if cat.has(str(STYLE_TO_MODE[style])):
			n += 1
	return n


## catalog 里两个形状 mode 的当前快照（报告用；改动前/后对比）。
func _snapshot_catalog_modes() -> Dictionary:
	var cat: Dictionary = _read_json(CATALOG_PATH).get("catalog", {})
	var out: Dictionary = {}
	for style in STYLE_TO_MODE:
		var mode := str(STYLE_TO_MODE[style])
		out[mode] = cat.get(mode, {})
	return out


# ==================== 5. 报告 ====================

func _report() -> void:
	var sets := 0
	var levels := 0
	for style in STYLE_TO_MODE:
		var mode := str(STYLE_TO_MODE[style])
		var entry := _scan_mode_dir(mode)
		if entry.is_empty():
			print("[shape-import] %-12s —— 库内无内容（catalog 中无此键）" % mode)
			continue
		var sizes: Array = entry.keys()
		sizes.sort()
		print("[shape-import] %s：" % mode)
		for size_s in sizes:
			var side := int(str(size_s))
			for tier in entry[size_s]:
				var arr := _lib_levels(mode, side, str(tier))
				var names: Array[String] = []
				for lv in arr:
					names.append(str((lv as Dictionary).get("name", "?")))
				sets += 1
				levels += arr.size()
				print("[shape-import]   %-12s %d×%d  %-5s %2d 关：%s" % [
					mode, side, side, str(tier), arr.size(), ", ".join(names)])
	print("[shape-import] 本次入库 %d 个集 / %d 关；形状关扫描 %d 关，未知 style 跳过 %d，形状非法跳过 %d，不入库范围（前缀/尺寸）%d，seed 重复 %d，自校验剔除 %d" % [
		sets, levels, _scanned, _skipped_style.size(), _skipped_shape.size(), _skipped_scope.size(), _skipped_dup, _removed])
	if not _skipped_style.is_empty():
		print("[shape-import]   未知 style（未登记 STYLE_TO_MODE）: %s" % ", ".join(_skipped_style))
	if not _skipped_shape.is_empty():
		print("[shape-import]   形状非法跳过: %s" % ", ".join(_skipped_shape))
	if not _skipped_scope.is_empty():
		print("[shape-import]   不入库范围（前缀白名单外 / 尺寸越界，留在手工异形页）: %s" % ", ".join(_skipped_scope))
	if not _removed_why.is_empty():
		print("[shape-import]   剔除原因（前 %d）: %s" % [_removed_why.size(), "；".join(_removed_why)])
	_report_catalog_diff()


## catalog 变更前后对比（只对比两个形状 mode —— 其他 mode 本工具不碰）。
func _report_catalog_diff() -> void:
	for style in STYLE_TO_MODE:
		var mode := str(STYLE_TO_MODE[style])
		var before: Dictionary = _cat_before.get(mode, {})
		var after: Dictionary = _scan_mode_dir(mode)
		print("[shape-import] catalog[%s]: %s → %s" % [
			mode, _cat_str(before), _cat_str(after)])


func _cat_str(entry: Dictionary) -> String:
	if entry.is_empty():
		return "（无）"
	var size_keys: Array = entry.keys()
	size_keys.sort()
	var parts: Array[String] = []
	for k in size_keys:
		var tiers: Dictionary = entry[k]
		var tier_keys: Array = tiers.keys()
		tier_keys.sort()
		var tp: Array[String] = []
		for t in tier_keys:
			tp.append("%s=%d" % [str(t), int(tiers[t])])
		parts.append("%s{%s}" % [str(k), ",".join(tp)])
	return " ".join(parts)


# ==================== 运行时取库资料（避免编译期依赖 autoload） ====================

## LevelLoader.load_level 的运行期包装（见 LEVEL_LOADER_PATH 注释）。null = 加载/校验失败。
func _load_level(path: String) -> Board:
	var script: Variant = load(LEVEL_LOADER_PATH)
	if script == null:
		push_error("[shape-import] 无法加载 %s" % LEVEL_LOADER_PATH)
		return null
	return script.call("load_level", path) as Board


## LevelLibrary.levels 的运行期包装（打印摘要用；与游戏侧同一份读取逻辑）。
func _lib_levels(mode: String, size: int, tier: String) -> Array:
	var script: Variant = load(LEVEL_LIBRARY_PATH)
	if script == null:
		return []
	return script.call("levels", mode, size, tier) as Array


## LevelLibrary.count 的运行期包装：**读 catalog** —— 用于核对「索引与实写数一致」。
func _lib_count(mode: String, size: int, tier: String) -> int:
	var script: Variant = load(LEVEL_LIBRARY_PATH)
	if script == null:
		return -1
	return int(script.call("count", mode, size, tier))


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## 递归把「整数值的 float」还原成 int（JSON 往返的浮点化噪声只出现在这里；见 `_rebuild_catalog`）。
## 非整数值（真小数）原样保留；只处理数字/字典/数组，其余原样返回。
func _int_value_normalized(v: Variant) -> Variant:
	var t := typeof(v)
	if t == TYPE_FLOAT:
		var f := float(v)
		return int(f) if is_equal_approx(f, roundf(f)) else f
	if t == TYPE_DICTIONARY:
		var out: Dictionary = {}
		for k in (v as Dictionary):
			out[k] = _int_value_normalized((v as Dictionary)[k])
		return out
	if t == TYPE_ARRAY:
		var arr: Array = []
		for e in (v as Array):
			arr.append(_int_value_normalized(e))
		return arr
	return v
