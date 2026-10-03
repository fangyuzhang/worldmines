# perf_ledger.gd —— 编辑器「全局性能记账 + 统一降级顺序」（纯逻辑，不依赖场景树 / 真实帧率）
#
# 【为什么有它】编辑器里四件「重活」各自单开都不卡，但 5000 格（`EditorDoc.MAX_CELL_BUDGET`）
# 全开时会叠加超载：
#   · verify   = `EditorVerify.verify_islands()`（ui/level_editor.gd:2646-2656 `_run_verify`）
#                唯一跑 CP-SAT 序贯演绎的重活；默认总预算 8s / 单次探测 1.5s（editor_verify.gd:36-37）。
#   · hotmap   = `HotMap.build()`（core/hotmap.gd）**猜点热力图**：先跑一次 verify，再逐格做
#                forced-cell 探测（hotmap.gd:58、:88-93），且每次编辑后都要重算。
#                ⚠ 诚实边界：热力图目前**尚未接进编辑器 UI**（只有 core + 用例），见文件末「集成点」。
#   · autosave = `ui/level_editor.gd:3177 _write_autosave()`：序列化整份 `doc.to_level_json()` 后
#                tmp→rename 原子写盘；由 `AUTOSAVE_IDLE_MS = 1200`（level_editor.gd:40）空闲去抖。
#   · stats    = 验证页那几行统计文字（ui/level_editor.gd:2654-2672：轮数 / 强制格 / 解数 / 毫秒，
#                数据直接读 verify 的 stats 字典）。纯 Label 赋值，无求解、无 IO。
#                ⚠ 诚实边界：本仓**没有独立的「统计面板」**；`core/stats_registry.gd` 是 Mod 统计
#                维度注册（文档 23 号 §14.11），与编辑器统计面板不是一回事，别混。
#
# 【降级顺序】文档「十.1 性能叠加」原文钦定，**不许自己发明**：
#   ① 关热力图 → ② 降校验频率 → ③ 延后自动保存（见 `DEGRADE_STEPS`）。
#   回爬一律走严格逆序（最后降的先恢复，见 `RESTORE_STEPS`）。
#
# 【不许抖动的稳定化机制】三件套：
#   1) 进入滞后 `enter_ms`（默认 500ms）：负载必须**持续**超载满 500ms 才降一档
#      —— 依据：编辑器交互窗口按 60fps 计，一帧 ≈16.7ms，500ms ≈ 30 帧；单帧/单次卡顿尖峰
#      （如一次手动保存、一次 GC）不构成降级理由。
#   2) 退出滞后 `exit_ms`（默认 3000ms）= 进入窗口的 6 倍：负载必须**持续**回落满 3s 才回爬
#      —— 依据：热力图/验证的耗时随盘面与规则波动大（同一盘不同规则差一个量级很正常），
#      若用同一个窗口，刚关掉热力图省下的那点额度会立刻把它拉回来 ⇒ 关-开-关死循环。
#      回爬门槛刻意远高于降级门槛（非对称滞后），保证"降得下、升得上但不来回蹦"。
#   3) 每档最小保持 `min_hold_ms`（默认 2000ms）：任何一档生效后 2s 内不允许再变档
#      —— 依据：比进入窗口更长，防止三档在几帧内被一次性降完（过降）；也让"降-稳-升"里
#      的"稳"是真实存在的状态，而不是过路状态。
#   稳定态判定：`tick()` 每次变档后把对应窗口计时器**重置为当前时刻** ⇒ 下一档要重新攒满窗口。
#   4) 负载余量 `RESTORE_MARGIN`（默认 0.8）：已降级状态下，光"不超预算"不算恢复，必须留出
#      ≥20% 余量（`budget_ok_for()`）—— 否则"关掉热力图后刚好压线"会在 3 秒后重开、又超、再关，
#      变成 3 秒级的**慢速抖动**（时间滞后只能限频，限不了这种边界振荡，余量阈值才能）。20% 是
#      **启发式起点**（≈ 一次典型单格编辑带来的负载波动量级），不是实测标定，故做成常量便于按真机数据调。
#
# 【预算归谁判】本模块**不猜**帧预算与盘面大小：`budget_ok` 由调用方给（它才掌握帧时间/格数），
# 也可用 `budget_ok_for(budget_ms)` 吃调用方 `report_ms()` 上报的实测耗时自动判。
# `cost` 只是**相对权重**（不是实测毫秒），`last_ms` 才是实测值。
#
# 【时钟可注入】`tick(now_ms, budget_ok)` 显式吃时间戳（无头单测里就是假时钟）；
# `configure()` 可改三个阈值。全模块无 `Time.get_ticks_msec()` 调用 ⇒ 单测不依赖真实帧率。
class_name PerfLedger
extends RefCounted

# ==================== 活名（对应上文真实功能，不造词） ====================

const JOB_VERIFY := "verify"
const JOB_HOTMAP := "hotmap"
const JOB_AUTOSAVE := "autosave"
const JOB_STATS := "stats"

# 相对开销权重（1.0 = verify 的一个典型运行；**非实测毫秒**，实测走 report_ms/last_ms）：
#   · verify   1.0  —— 基准。CP-SAT 序贯演绎，编辑器里最重的一次计算。
#   · hotmap   1.6  —— 单次 `HotMap.build()` = 1 次 verify + 逐格 forced-cell 探测 ⇒ 单次就 ≥ verify；
#                      且它是"每次编辑都重算"的常客 ⇒ 单位时间摊销更贵，故排第一降级。
#   · autosave 0.35 —— 整份 JSON 序列化 + 写盘（IO），1200ms 去抖后每串编辑只发生 1 次。
#   · stats    0.05 —— 只是把已有 stats 字典拼成几行文本，接近零成本。
const DEFAULT_COSTS := {
	JOB_VERIFY: 1.0,
	JOB_HOTMAP: 1.6,
	JOB_AUTOSAVE: 0.35,
	JOB_STATS: 0.05,
}

# ==================== 动作 id（降级 / 回爬） ====================

const ACT_DISABLE_HOTMAP := "disable_hotmap"
const ACT_REDUCE_VERIFY := "reduce_verify"
const ACT_DELAY_AUTOSAVE := "delay_autosave"
const ACT_RESTORE_AUTOSAVE := "restore_autosave"
const ACT_RESTORE_VERIFY := "restore_verify"
const ACT_RESTORE_HOTMAP := "restore_hotmap"

## 降级顺序表（文档「十.1」钦定顺序，下标 = 目标档位 - 1）。**不要重排**。
const DEGRADE_STEPS: Array[String] = [ACT_DISABLE_HOTMAP, ACT_REDUCE_VERIFY, ACT_DELAY_AUTOSAVE]
## 回爬顺序 = 降级顺序的严格逆序（最后降的最先恢复）。
const RESTORE_STEPS: Array[String] = [ACT_RESTORE_AUTOSAVE, ACT_RESTORE_VERIFY, ACT_RESTORE_HOTMAP]
## 全部合法动作（`apply_action` 的白名单；不在表内的一律兜底拒绝）。
const ALL_ACTIONS: Array[String] = [
	ACT_DISABLE_HOTMAP, ACT_REDUCE_VERIFY, ACT_DELAY_AUTOSAVE,
	ACT_RESTORE_AUTOSAVE, ACT_RESTORE_VERIFY, ACT_RESTORE_HOTMAP,
]

## 「降校验频率」的摊销系数：单位时间内验证跑的遍数约减半（去抖窗口拉长）。
const REDUCED_VERIFY_RATE := 0.5
## 「延后自动保存」的摊销系数：落盘推迟 ⇒ 单位时间内的写盘开销压到约 1/4。
const DELAYED_AUTOSAVE_RATE := 0.25

# ==================== 稳定化阈值默认值（可 configure 覆盖） ====================

const DEFAULT_ENTER_MS := 500
const DEFAULT_EXIT_MS := 3_000
const DEFAULT_MIN_HOLD_MS := 2_000
## 回爬所需的负载余量系数（见文件头「稳定化机制」第 4 条；1.0 = 不留余量）。
const RESTORE_MARGIN := 0.8

# ==================== 内部状态 ====================

var _costs: Dictionary = {}      ## name -> float（相对权重）
var _enabled: Dictionary = {}    ## name -> bool（**用户/降级后**的实际开关）
var _rate: Dictionary = {}       ## name -> float（频率系数，1.0 = 原频率）
var _last_ms: Dictionary = {}    ## name -> float（调用方上报的实测耗时；-1 = 尚未上报）
var _level: int = 0              ## 当前降级档：0 全开 / 1 关热力图 / 2 +降校验 / 3 +延后保存
var _now_ms: int = 0
var _over_since_ms: int = -1     ## 连续超载起点（-1 = 当前不在超载态）
var _ok_since_ms: int = -1       ## 连续达标起点（-1 = 当前不在达标态）
var _last_change_ms: int = -1    ## 上次变档时刻（-1 = 从未变档）
var _applied: Dictionary = {}    ## action -> int（累计应用次数，供幂等自证）
var _enter_ms: int = DEFAULT_ENTER_MS
var _exit_ms: int = DEFAULT_EXIT_MS
var _min_hold_ms: int = DEFAULT_MIN_HOLD_MS


func _init() -> void:
	for n in DEFAULT_COSTS:
		register_job(String(n), float(DEFAULT_COSTS[n]))


# ==================== 登记 / 查询 ====================

## 登记一个重活（同名重复登记只改 cost，不动开关与频率）。
## 允许登记**自定义**活名（便于未来接别的重活）；空名或负开销拒绝，返回 false。
func register_job(name: String, cost: float, enabled: bool = true) -> bool:
	if name == "" or cost < 0.0:
		return false
	_costs[name] = cost
	if not _enabled.has(name):
		_enabled[name] = enabled
	if not _rate.has(name):
		_rate[name] = 1.0
	if not _last_ms.has(name):
		_last_ms[name] = -1.0
	return true


## 手动开关（用户点 UI 的开关走这里）。未知活名**兜底不崩**：返回 false。
## 注意：手动开关**不改降级档**（档位只由 tick 的负载判定驱动），二者互不装作一致。
## ⚠ 已知边界：降级期间的回爬（`restore_*`）会**无条件**重新打开对应的活 ⇒ 会覆盖用户手动
## 关掉的开关。UI 集成时请把"用户开关"与"降级档"分开呈现（或只在用户没手动关过时才由本模块
## 接管该活的开关），别指望这里记住用户意图 —— 本模块不替用户做决定，也不假装做过。
func set_enabled(name: String, on: bool) -> bool:
	if not _enabled.has(name):
		return false
	_enabled[name] = on
	return true


func is_enabled(name: String) -> bool:
	return bool(_enabled.get(name, false))


## 全部活的开关快照（副本，改它不影响内部）。
func enabled() -> Dictionary:
	return _enabled.duplicate()


func cost_of(name: String) -> float:
	return float(_costs.get(name, 0.0))


## 当前频率系数（1.0 = 原频率；未知活名返回 1.0，即"不做任何降频"）。
func rate_of(name: String) -> float:
	return float(_rate.get(name, 1.0))


## 上报实测耗时（毫秒）。未知活名**兜底不崩**：返回 false。负值按 0 记。
func report_ms(name: String, ms: float) -> bool:
	if not _last_ms.has(name):
		return false
	_last_ms[name] = maxf(0.0, ms)
	return true


## 某活最近一次上报的耗时；从未上报返回 -1（**不假装是 0**）。
func last_ms(name: String) -> float:
	return float(_last_ms.get(name, -1.0))


## 已上报耗时的合计（只统计**已上报且当前开启**的活）。
## ⚠ 未上报的活按 0 计 —— 调用方若要靠它判预算，应保证所有开启的活都上报过一次。
func measured_ms() -> float:
	var sum := 0.0
	for n in _last_ms:
		if is_enabled(String(n)) and float(_last_ms[n]) >= 0.0:
			sum += float(_last_ms[n])
	return sum


## 相对负载（= Σ cost × rate，只算开启的活）。用于排序/展示，不参与预算判定（见文件头）。
func effective_load() -> float:
	var sum := 0.0
	for n in _costs:
		if is_enabled(String(n)):
			sum += float(_costs[n]) * rate_of(String(n))
	return sum


## 用上报的实测耗时判预算（**推荐入口**：余量阈值已内置，调用方不必自己算滞后）。
## 全开时：不超预算即达标；已降级时：需 `measured ≤ budget × RESTORE_MARGIN`（留余量，防边界抖动）。
## 没上报过 = 0ms ⇒ 视为达标（调用方应保证开启的活都上报过一次，否则预算判定失真）。
func budget_ok_for(budget_ms: float) -> bool:
	var m := measured_ms()
	if _level == 0:
		return m <= budget_ms
	return m <= budget_ms * RESTORE_MARGIN


func level() -> int:
	return _level


func max_level() -> int:
	return DEGRADE_STEPS.size()


## 当前档位下该执行的动作（降级档位未满时非空）；满档 / 全开时为 ""。
func pending_action() -> String:
	if _level < DEGRADE_STEPS.size():
		return DEGRADE_STEPS[_level]
	if _level > 0:
		return RESTORE_STEPS[DEGRADE_STEPS.size() - _level]
	return ""


# ==================== 降级计划（纯查询，不改状态） ====================

## 超载时给出**尚未执行的**降级动作序列（严格按文档顺序 ①→③）；达标时给空数组。
## 返回的是动作 id（机器可执行）；人话原因用 `action_reason()` / `plan_explained()` 取。
## ⚠ 这是"完整剩余序列"（给 UI 预告"接下来会关什么"）；**执行**请交给 `tick()` —— 它每次窗口
## 只推一档（防过降），不要拿本函数的返回值一次性全执行。
func degrade_plan(budget_ok: bool) -> Array[String]:
	var out: Array[String] = []
	if budget_ok:
		return out
	var i := _level
	while i < DEGRADE_STEPS.size():
		out.append(DEGRADE_STEPS[i])
		i += 1
	return out


## 同 `degrade_plan`，但每步带人话原因：`[{action, reason}, ...]`。
func plan_explained(budget_ok: bool) -> Array:
	var out: Array = []
	for a in degrade_plan(budget_ok):
		out.append({"action": a, "reason": action_reason(a)})
	return out


static func action_reason(action: String) -> String:
	match action:
		ACT_DISABLE_HOTMAP:
			return "热力图最贵又只是给作者看的参考色（每次编辑都要重算：先跑一次 verify 再逐格探测）；先关它，编辑本身不受影响。"
		ACT_REDUCE_VERIFY:
			return "验证是唯一跑 CP-SAT 的重活（默认总预算 8 秒）；拉长去抖窗口降频，结论照给但少跑几遍。"
		ACT_DELAY_AUTOSAVE:
			return "自动保存要序列化整份 JSON 并写盘；延后它只推迟一次落盘，内存里的文档还在，不会丢数据。"
		ACT_RESTORE_AUTOSAVE:
			return "负载已持续回落：把自动保存的落盘节奏恢复正常。"
		ACT_RESTORE_VERIFY:
			return "负载已持续回落：恢复验证的原频率（重新给出即时结论）。"
		ACT_RESTORE_HOTMAP:
			return "负载已持续回落：重新打开热力图（它是最先关、最后开的那个）。"
		_:
			return "未知动作（%s）：不做任何事。" % action


# ==================== 状态机 ====================

## 注入时钟 + 驱动状态机。`budget_ok = true` 表示本次采样负载达标。
## 返回**本次实际执行**的动作 id（通常 0 或 1 个）；无变档返回空数组。
## 变档必须同时满足：窗口攒满（enter/exit）+ 距上次变档 ≥ min_hold；变档后窗口计时器归零。
func tick(now_ms: int, budget_ok: bool) -> Array[String]:
	var out: Array[String] = []
	if now_ms < _now_ms:
		# 时钟回拨 / 单测重启计时：当作"窗口作废"，绝不据此误判（返回空 = 本帧不动）。
		_now_ms = now_ms
		_over_since_ms = -1
		_ok_since_ms = -1
		return out
	_now_ms = now_ms
	if budget_ok:
		_over_since_ms = -1
		if _ok_since_ms < 0:
			_ok_since_ms = now_ms
		if _level > 0 and now_ms - _ok_since_ms >= _exit_ms and _hold_elapsed(now_ms):
			_level -= 1
			var act := RESTORE_STEPS[DEGRADE_STEPS.size() - 1 - _level]
			_apply(act)
			out.append(act)
			_last_change_ms = now_ms
			_ok_since_ms = now_ms      # 下一档要重新攒满退出窗口 ⇒ 回爬也是一档一档来
	else:
		_ok_since_ms = -1
		if _over_since_ms < 0:
			_over_since_ms = now_ms
		if _level < DEGRADE_STEPS.size() and now_ms - _over_since_ms >= _enter_ms and _hold_elapsed(now_ms):
			var act := DEGRADE_STEPS[_level]
			_level += 1
			_apply(act)
			out.append(act)
			_last_change_ms = now_ms
			_over_since_ms = now_ms    # 下一档要重新攒满进入窗口 ⇒ 不会一帧降到底
	return out


## 便捷入口：吃**实测耗时预算**（而不是调用方自己的布尔结论），余量阈值由 `budget_ok_for` 统一处理。
## 返回同 `tick`：本次实际执行的动作。
func tick_measured(now_ms: int, budget_ms: float) -> Array[String]:
	return tick(now_ms, budget_ok_for(budget_ms))


## 执行一个动作（`tick` 内部用它，也公开给"按计划执行"的集成方）。未知动作返回 false，不崩。
func apply_action(action: String) -> bool:
	if not ALL_ACTIONS.has(action):
		return false
	_apply(action)
	return true


## 回到全开：所有活打开、频率系数回 1.0、档位回 0、稳定化计时器与幂等计数清零。
func restore() -> void:
	for n in _enabled:
		_enabled[n] = true
		_rate[n] = 1.0
	_level = 0
	_over_since_ms = -1
	_ok_since_ms = -1
	_last_change_ms = -1
	_applied.clear()


## 覆盖稳定化阈值（秒表单位毫秒）。非法值拒绝并返回 false。
func configure(enter_ms: int, exit_ms: int, min_hold_ms: int) -> bool:
	if enter_ms <= 0 or exit_ms <= 0 or min_hold_ms < 0:
		return false
	_enter_ms = enter_ms
	_exit_ms = exit_ms
	_min_hold_ms = min_hold_ms
	return true


## 某动作累计应用次数（幂等自证：同一动作不会因连续超载重复施加）。
func applied_count(action: String) -> int:
	return int(_applied.get(action, 0))


## 给 UI 的一览（全是副本，改它不影响内部）。
func status() -> Dictionary:
	return {
		"level": _level,
		"max_level": max_level(),
		"enabled": enabled(),
		"rates": _rate.duplicate(),
		"costs": _costs.duplicate(),
		"last_ms": _last_ms.duplicate(),
		"effective_load": effective_load(),
		"measured_ms": measured_ms(),
		"applied": _applied.duplicate(),
		"enter_ms": _enter_ms,
		"exit_ms": _exit_ms,
		"min_hold_ms": _min_hold_ms,
	}


# ==================== 内部 ====================

func _hold_elapsed(now_ms: int) -> bool:
	return _last_change_ms < 0 or now_ms - _last_change_ms >= _min_hold_ms


func _apply(action: String) -> void:
	_applied[action] = int(_applied.get(action, 0)) + 1
	match action:
		ACT_DISABLE_HOTMAP:
			set_enabled(JOB_HOTMAP, false)
		ACT_REDUCE_VERIFY:
			_rate[JOB_VERIFY] = REDUCED_VERIFY_RATE
		ACT_DELAY_AUTOSAVE:
			_rate[JOB_AUTOSAVE] = DELAYED_AUTOSAVE_RATE
		ACT_RESTORE_AUTOSAVE:
			_rate[JOB_AUTOSAVE] = 1.0
		ACT_RESTORE_VERIFY:
			_rate[JOB_VERIFY] = 1.0
		ACT_RESTORE_HOTMAP:
			set_enabled(JOB_HOTMAP, true)
		_:
			pass    # 未知动作：不崩、不装作做过


# ==================== 集成点（本模块刻意不改 ui/，这里是"接进编辑器还差什么"） ====================
#
# 【本模块已就绪】降级序列、稳定化、幂等、兜底全部可用且有 8 条用例钉住；下面 5 步是**调用侧**的事：
#   1) 持有：`ui/level_editor.gd` 里加一个 `var _perf := PerfLedger.new()`（每编辑器一个实例）。
#   2) 上报（关键，不做则预算判定失真）：verify 跑到哪就 `report_ms("verify", 毫秒)`（`_run_verify`）、
#      `_write_autosave()` 同理 `report_ms("autosave", …)`；热力图接好 `HotMap.build()` 后同报；
#      验证页统计行刷新的耗时报 `report_ms("stats", …)`（这几处都只是**加一行计时**，不改现有逻辑）。
#   3) 落地开关：热力图显隐读 `is_enabled("hotmap")`；`_run_verify` 的去抖窗口 × `rate_of("verify")`；
#      `AUTOSAVE_IDLE_MS`（现在写死 1200，level_editor.gd:40）÷ `rate_of("autosave")` = "延后自动保存"。
#   4) 驱动：`_process()` 里 `_perf.tick_measured(Time.get_ticks_msec(), 帧预算毫秒)`；**帧预算要真机标定**
#      （本模块不猜，`budget_ok_for` 的 `RESTORE_MARGIN` 也留成常量待调）。
#   5) 提示：要用"即将降级"的人话时读 `plan_explained(false)`；要整盘状态读 `status()`。
#
# 【现存缺口（本模块修不了，但集成方必须知道）】
#   · 热力图 / 推理链回放**尚无 UI 挂点**（W2「作弊信息统一状态机」、W10「回放 UI」还是"待勘察"），
#     所以 `hotmap` 这一档目前只是**预留**：真接上之前，关它 = 空动作。
#   · `stats` 对应的是验证页那几行文本，不是独立"统计面板"（本仓没有）；若未来真做面板，成本权重要重估。
#   · `last_ms` 的"真实耗时"全靠调用方上报；本模块只负责存与合计，**不自己测**（无头单测里也没法测）。
