# achievement_service.gd —— 成就接线层（把各系统的数据拼成判定上下文）
#
# 为什么单独一层（而不是塞进 game_session 或 registry）：
#   · registry 只认「纯上下文」，它的单元测试不该依赖存档 / 磁盘 / 关卡目录；
#   · 上下文要读四五个来源（ProgressStore / 教学进度 / 创作中心 / 关卡目录 / 错觉策展），
#     这些东西一旦写进 game_session，通关路径就会因为一次目录扫描而变慢或有副作用；
#   · 于是：**收集数据全在这里**，game_session 只调一行 `evaluate(...)`。
#
# ⚠️ 刻意不写 class_name（坑表 #26）。调用方：const Ach := preload("res://ui/achievement_service.gd")。
extends RefCounted


const RegistryScript := preload("res://core/achievement_registry.gd")
const Catalog := preload("res://core/achievement_catalog.gd")
const Tags := preload("res://core/level_tags.gd")
const Series := preload("res://core/illusion_series.gd")
const Radar := preload("res://core/mastery_radar.gd")
const TProg := preload("res://core/tutorial_progress.gd")
const Hub := preload("res://core/creator_hub.gd")

const LEVELS_DIR := "res://levels"


static func registry():
	return RegistryScript.shared()


static func unlocked_count() -> int:
	return registry().unlocked_count()


static func total_count() -> int:
	return registry().total_count()


## 本次通关（或失败）后的判定上下文。所有键都**保证存在**（缺省 0 / false），
## 于是目录里的 cond 不会因为「某个键偶尔没给」而静默判假。
static func build_context(level_key: String, won: bool, stars: int, hint_tier: int,
		elapsed: float) -> Dictionary:
	var levels := ProgressStore.levels()

	var cleared_count := 0
	var cleared_no_hint := 0
	var cleared_manual := 0
	var cleared_lib := 0
	var cleared_gen := 0
	var runs_total := 0
	var star_sum := 0
	var axis_counts := {}
	var illusion_cleared := 0
	var series_counts := {}
	for k in levels:
		var rec: Dictionary = levels[k]
		runs_total += int(rec.get("plays", 0))
		if not bool(rec.get("cleared", false)):
			continue
		cleared_count += 1
		var st := clampi(int(rec.get("best_stars", 0)), 0, 3)
		star_sum += st
		if st >= 3:
			cleared_no_hint += 1
		var key := str(k)
		if key.begins_with("lib://"):
			cleared_lib += 1
		elif key.begins_with("gen://"):
			cleared_gen += 1
		else:
			cleared_manual += 1
		for a in Tags.axes_of(key):
			axis_counts[a] = int(axis_counts.get(a, 0)) + 1
		var sid := Tags.series_of(key)
		if sid != "" and Series.is_illusion(key):
			illusion_cleared += 1
			series_counts[sid] = int(series_counts.get(sid, 0)) + 1

	var kinds := Tags.axis_kinds_of_levels(levels)
	var counts := Radar.counts_from_levels(levels)
	var hit := Tags.axes_of(level_key)
	var hit_obs := 0
	var hit_struct := 0
	var hit_cons := 0
	for a in hit:
		var kind := Tags.kind_of(level_key)
		if a.begins_with("o") or kind == Tags.KIND_OBS:
			hit_obs = 1
		if a.begins_with("s") or kind == Tags.KIND_STRUCT:
			hit_struct = 1
		if a.begins_with("z") or kind == Tags.KIND_CONSERVE:
			hit_cons = 1
	# 混合档（o1_s3）应同时点亮两条轴的「三星」成就 —— 上面按前缀逐个判定，这里不覆盖。

	var avg_x10 := 0
	if cleared_count > 0:
		avg_x10 = int(round(10.0 * float(star_sum) / float(cleared_count)))
	var hub := Hub.stats()

	return {
		"won": won,
		"stars": stars,
		"hint_tier": hint_tier,
		"elapsed": elapsed,
		"level_key": level_key,
		"level_plays": ProgressStore.plays(level_key),
		"cleared_count": cleared_count,
		"cleared_manual": cleared_manual,
		"cleared_lib": cleared_lib,
		"cleared_gen": cleared_gen,
		"cleared_no_hint": cleared_no_hint,
		"cleared_axis": axis_counts,
		"axis_kinds": int(kinds.get("all", 0)),
		"obs_kinds": int(kinds.get("obs", 0)),
		"struct_kinds": int(kinds.get("struct", 0)),
		"cons_kinds": int(kinds.get("cons", 0)),
		"obs_cleared": int(counts.get("observe", 0)),
		"struct_cleared": int(counts.get("structure", 0)),
		"cons_cleared": int(counts.get("conserve", 0)),
		"axes_hit_obs": hit_obs,
		"axes_hit_struct": hit_struct,
		"axes_hit_conserve": hit_cons,
		"illusion_cleared": illusion_cleared,
		"illusion_total": illusion_total(),
		"illusion_series_cleared": series_counts,
		"illusion_series_kinds": series_counts.size(),
		"runs_total": runs_total,
		"tutorials_seen": TProg.count(),
		"craft_mods": mod_count(),
		"craft_published": int(hub.get("versions", 0)),
		"craft_feedback": int(hub.get("feedback", 0)),
		"avg_stars_x10": avg_x10,
	}


## 判定 + 落盘。返回新解锁的成就 id。
static func evaluate(level_key: String, won: bool, stars: int, hint_tier: int, elapsed: float) -> Array[String]:
	return registry().check_and_save(build_context(level_key, won, stars, hint_tier, elapsed))


## 非对局触发点（读完一页教学 / 登记作品版本 / 导入反馈）用：
## 只按**累积指标**判定，不看本局结果（won=false / stars=0 / hint_tier=-1）。
## 为什么需要它：成就里有一组与"打了哪一关"无关（教学页数、Mod 数、作品版本数、反馈数），
## 如果只在通关时判定，玩家读完 30 页教学也要等到下一局才亮 —— 会读成"成就坏了"。
static func refresh() -> Array[String]:
	return registry().check_and_save(build_context("", false, 0, -1, 0.0))


## 成就 id 列表 → 显示名列表（用于 toast / 结算页）。
static func names_of(ids: Array) -> Array[String]:
	var out: Array[String] = []
	for raw in ids:
		var d := Catalog.by_id(str(raw))
		out.append(str(d.get("name", str(raw))))
	return out


## 新解锁提示（一步到位：调用方只给宿主与 id 列表）。
static func toast_new(host: Node, ids: Array) -> void:
	if ids.is_empty():
		return
	var names := names_of(ids)
	UiToast.popup(host, "新成就 · " + ", ".join(names), false, 4.0)


## 官方错觉策展关卡总数（成就墙 / 系列导览展示「x / y」用）。
static func illusion_total() -> int:
	var d := DirAccess.open(LEVELS_DIR)
	if d == null:
		return 0
	var n := 0
	for f in d.get_files():
		var name := str(f)
		if not name.ends_with(".json"):
			continue
		if Series.is_illusion(name):
			n += 1
	return n


## 本地已安装 Mod 数（user://mods 下的子目录）。
static func mod_count() -> int:
	var d := DirAccess.open("user://mods")
	if d == null:
		return 0
	var n := 0
	for sub in d.get_directories():
		if str(sub) != "":
			n += 1
	return n
