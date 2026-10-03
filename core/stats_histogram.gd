# stats_histogram.gd —— 统计直方图（纯函数；缺口 #16 第一块）
#
# 为什么需要：统计面板要画「一关的数字分布 / 雷密度分布」，但面板宽度有限、样本数不可控。
# 本模块把"数组 → 分桶计数"收成**一个确定性纯函数**，面板只负责把 buckets 画成柱子。
#
# 【桶数为什么必须有硬上限】
#   · UI 一栏最宽约 640px：桶数 > 64 时每根柱子已不足 10px，画了也读不出，纯属浪费；
#   · 防呆/防炸：调用方（含 Mod / 未来面板）一旦传 10^6，无上限会瞬间分配百万长数组；
#   · 64 = 2^6，桶宽 = 区间/64 是整齐的等差数列，便于对齐刻度；
#   · 样本 < 64 时桶数再大也不会更细（每桶不足一个样本），上限不影响可用性。
#   注意：上限只**钳**桶数，绝不静默改变区间 —— 区间始终原样回显在 min/max。
#
# 【口径：有效样本 vs 被忽略样本】
#   落进桶里的样本 = "有效样本"，其计数记在 n；桶内计数总和**恒等于 n**（守恒，见单测）。
#   非数值 / 非有限 / 越界的样本一律**忽略**并记入 skipped，且在 reason 里说明 ——
#   绝不悄悄丢样本、也绝不把越界值硬塞进首尾桶（那会伪造尖峰）。
class_name StatsHistogram
extends RefCounted


## 桶数硬上限（见文件头依据）。任何请求都会被钳到这个值以内。
const MAX_BUCKETS := 64


## 核心入口：把 values 按 [min_v, max_v] 均匀分成 bucket_count 个桶。
## 返回 { buckets, min, max, n, reason }，另附若干自解释字段：
##   buckets           : Array[int]，长度 = 生效桶数
##   min / max         : float，原样回显的区间
##   n                 : int，**有效样本数**（== buckets 求和，守恒）
##   reason            : String，"" = 无问题；否则为可读说明（空数组 / 区间非法 / 被忽略样本 / 桶被钳）
##   bucket_count      : int，生效桶数
##   requested_buckets : int，调用方请求值
##   clamped           : bool，桶数是否被调整过
##   total / skipped   : int，输入总数 / 被忽略数（含非数值与越界）
## 纯函数、确定性：不引用引擎 / UI / autoload，不做随机。
static func histogram(values: Array, bucket_count: int, min_v: float, max_v: float) -> Dictionary:
	var notes: Array[String] = []

	# ---- ① 桶数钳位（先定形，保证任何早退路径也返回合法长度的 buckets）----
	var eff := bucket_count
	if eff < 1:
		notes.append("桶数 %d 非法（<1），已按 1 处理" % bucket_count)
		eff = 1
	elif eff > MAX_BUCKETS:
		notes.append("请求 %d 个桶超过上限 %d，已钳到上限" % [bucket_count, MAX_BUCKETS])
		eff = MAX_BUCKETS

	var buckets: Array = []
	buckets.resize(eff)
	for i in eff:
		buckets[i] = 0

	var out := {
		"buckets": buckets,
		"min": float(min_v),
		"max": float(max_v),
		"n": 0,
		"reason": "",
		"bucket_count": eff,
		"requested_buckets": bucket_count,
		"clamped": eff != bucket_count,
		"total": values.size(),
		"skipped": 0,
	}

	# ---- ② 空数组：可读 reason，返回空桶（形状仍合法，面板无需特判）----
	if values.is_empty():
		notes.append("空数组：没有可统计的样本")
		out["reason"] = "；".join(notes)
		return out

	# ---- ③ 区间非法：min 必须严格小于 max；非有限区间同样拒绝 ----
	if not is_finite(min_v) or not is_finite(max_v) or min_v >= max_v:
		notes.append("区间非法：min(%s) 必须小于 max(%s)" % [_num(min_v), _num(max_v)])
		out["reason"] = "；".join(notes)
		return out

	# ---- ④ 分桶（左闭右闭：[min, max]，max 归入最后一桶，保证不越界）----
	var span := max_v - min_v
	var n := 0
	var out_of_range := 0
	var non_numeric := 0
	for v in values:
		var t := typeof(v)
		if t != TYPE_INT and t != TYPE_FLOAT:
			non_numeric += 1
			continue
		var f := float(v)
		if not is_finite(f) or f < min_v or f > max_v:
			out_of_range += 1
			continue
		var idx := int(floor((f - min_v) / span * float(eff)))
		idx = clampi(idx, 0, eff - 1)
		buckets[idx] = int(buckets[idx]) + 1
		n += 1

	if non_numeric > 0:
		notes.append("有 %d 个非数值样本（已忽略）" % non_numeric)
	if out_of_range > 0:
		notes.append("有 %d 个样本超出区间 [%s, %s]（已忽略）" % [out_of_range, _num(min_v), _num(max_v)])
	out["n"] = n
	out["skipped"] = non_numeric + out_of_range
	out["reason"] = "；".join(notes)
	return out


## 供 UI 显示的一行说明（确定性字符串）。reason 非空时附在末尾。
static func describe(hist: Dictionary) -> String:
	var buckets: Array = hist.get("buckets", [])
	var s := "直方图：%d 个样本，%d 桶，区间 [%s, %s] → %s" % [
		int(hist.get("n", 0)),
		int(hist.get("bucket_count", buckets.size())),
		_num(float(hist.get("min", 0.0))),
		_num(float(hist.get("max", 0.0))),
		str(buckets),
	]
	var reason := str(hist.get("reason", ""))
	if reason != "":
		s += "（注：%s）" % reason
	return s


## 便捷入口：一批关卡 → 每关雷密度 → 直方图（区间固定 [0,1]）。
## **只读**关卡字典里已有的 `size{rows,cols}` / `mines` / `total_mines` 字段（LevelFormat 口径），
## 不改动任何既有模块；非法关卡数据被跳过并在 reason 里报数。
static func density_histogram(levels: Array, bucket_count: int = 8) -> Dictionary:
	var densities: Array = []
	var bad := 0
	for lv in levels:
		var d := mine_density(lv)
		if d < 0.0:
			bad += 1
			continue
		densities.append(d)
	var h := histogram(densities, bucket_count, 0.0, 1.0)
	if bad > 0:
		var prefix := "%d 个关卡数据不合法（缺 size/mines 或格数为 0），已跳过" % bad
		var r := str(h.get("reason", ""))
		h["reason"] = prefix if r == "" else prefix + "；" + r
	return h


## 便捷入口：一批关卡 → 所有**非雷格**的经典 8 邻数字（0..8）→ 直方图（0..8 各一桶）。
## 只读 `size` / `mines`（LevelFormat 口径）自算邻域计数，自包含、确定性；不初始化 Board、不碰引擎状态。
static func numbers_histogram(levels: Array) -> Dictionary:
	var nums: Array = []
	var bad := 0
	for lv in levels:
		if mine_density(lv) < 0.0:
			bad += 1
			continue
		nums.append_array(classic_numbers(lv))
	var h := histogram(nums, 9, -0.5, 8.5)
	if bad > 0:
		var prefix := "%d 个关卡数据不合法，已跳过" % bad
		var r := str(h.get("reason", ""))
		h["reason"] = prefix if r == "" else prefix + "；" + r
	return h


## 单关雷密度 = 雷数 / 格数；非法数据返回 -1.0（调用方据此跳过）。
static func mine_density(level: Variant) -> float:
	if not (level is Dictionary):
		return -1.0
	var d: Dictionary = level
	var rows := 0
	var cols := 0
	var sz: Variant = d.get("size", {})
	if sz is Dictionary:
		rows = int((sz as Dictionary).get("rows", 0))
		cols = int((sz as Dictionary).get("cols", 0))
	if rows <= 0 or cols <= 0:
		rows = int(d.get("rows", 0))
		cols = int(d.get("cols", 0))
	var cells := rows * cols
	if cells <= 0:
		return -1.0
	var mines: Variant = d.get("mines", null)
	var m := -1
	if mines is Array:
		m = (mines as Array).size()
	elif d.has("total_mines"):
		m = int(d.get("total_mines", -1))
	if m < 0:
		return -1.0
	return clampf(float(m) / float(cells), 0.0, 1.0)


## 单关：所有非雷格的经典 8 邻雷计数（0..8），按 r 行优先、c 列优先的确定顺序。
## 非法输入返回空数组。
static func classic_numbers(level: Variant) -> Array:
	var out: Array = []
	if not (level is Dictionary):
		return out
	var d: Dictionary = level
	var rows := 0
	var cols := 0
	var sz: Variant = d.get("size", {})
	if sz is Dictionary:
		rows = int((sz as Dictionary).get("rows", 0))
		cols = int((sz as Dictionary).get("cols", 0))
	if rows <= 0 or cols <= 0:
		rows = int(d.get("rows", 0))
		cols = int(d.get("cols", 0))
	if rows <= 0 or cols <= 0:
		return out
	var mines: Variant = d.get("mines", [])
	if not (mines is Array):
		return out
	var mine_set := {}
	for m in (mines as Array):
		var rc := _rc_of(m)
		if rc.x >= 0:
			mine_set["%d,%d" % [rc.y, rc.x]] = true
	for r in rows:
		for c in cols:
			if mine_set.has("%d,%d" % [r, c]):
				continue
			var cnt := 0
			for dr in range(-1, 2):
				for dc in range(-1, 2):
					if dr == 0 and dc == 0:
						continue
					if mine_set.has("%d,%d" % [r + dr, c + dc]):
						cnt += 1
			out.append(cnt)
	return out


# ---- 内部 ----

## 位置三种历史写法都收：Vector2i / {r,c} / [r,c]；非法返回 (-1,-1)。
static func _rc_of(v: Variant) -> Vector2i:
	if v is Vector2i:
		return v as Vector2i
	if v is Dictionary:
		var d: Dictionary = v
		return Vector2i(int(d.get("c", -1)), int(d.get("r", -1)))
	if v is Array and (v as Array).size() >= 2:
		var a: Array = v
		return Vector2i(int(a[1]), int(a[0]))
	return Vector2i(-1, -1)


## 数值 → 紧凑可读串（整数不带小数点，小数两位）。
static func _num(v: float) -> String:
	if is_finite(v) and is_equal_approx(v, roundf(v)):
		return str(int(roundf(v)))
	return "%.2f" % v
