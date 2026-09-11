# capability.gd —— 能力令牌（文档 23 号 §2.2 / 21 号 R32）
# 最小权限模型：Mod 在 manifest 声明所需能力，加载时授予最小权限集。
# 未声明 = 无权限（API 层静默拒绝）；board.write_answer / rng.global 永不授予。
class_name Capability
extends RefCounted


# ==== 合法令牌全集 ====
const BOARD_READ := &"board.read"                # 读 PlayerView（默认授予）
const CLUE_REGISTER := &"clue.register"          # 注册 L1 线索插件
const CONSTRAINT_REGISTER := &"constraint.register"  # 注册 L1 约束插件
const TOPOLOGY_REGISTER := &"topology.register"  # 注册 L1 拓扑插件
const FLOOD_REGISTER := &"flood.register"        # 注册 L1 连锁插件
const SOLVER_REGISTER := &"solver.register"      # 注册 L1 求解器（需强制验证）
const GENERATOR_REGISTER := &"generator.register"  # 注册 L2 生成器（需强制验证）
const UI_INJECT := &"ui.inject"                  # 注入面板/菜单项/HUD
const RENDER_HOOK := &"render.hook"              # 棋盘绘制钩子
const DRAWING_BRUSH := &"drawing.brush"          # 自定义笔刷
const AUDIO_PLAY := &"audio.play"                # 播放/注册音效
const INPUT_MAP := &"input.map"                  # 键位与手势
const DATA_SLOT := &"data.slot"                  # 私有持久化分区
const RNG_STREAM := &"rng.stream"                # 独立随机流（默认授予）
const TIME_TICK := &"time.tick"                  # 每帧回调（频率上限）
const TIME_TIMER := &"time.timer"                # 定时器
const NET_WORKSHOP := &"net.workshop"            # 工坊网络（需二次确认）
const DEBUG_CMD := &"debug.cmd"                  # 调试命令（仅开发者模式）

# ==== 永不授予（L0） ====
const BOARD_WRITE_ANSWER := &"board.write_answer"  # L0-a 判负裁定权
const RNG_GLOBAL := &"rng.global"                  # L0-c 全局随机流

## 默认授予集（无需声明即可用）。
const DEFAULT_GRANTED: Array[StringName] = [BOARD_READ, RNG_STREAM]

## 永不授予集。
const NEVER_GRANTED: Array[StringName] = [BOARD_WRITE_ANSWER, RNG_GLOBAL]

## 合法令牌全集（不含永不授予，永不授予单独列出）。
const ALL_KNOWN: Array[StringName] = [
	BOARD_READ, CLUE_REGISTER, CONSTRAINT_REGISTER, TOPOLOGY_REGISTER, FLOOD_REGISTER,
	SOLVER_REGISTER, GENERATOR_REGISTER, UI_INJECT, RENDER_HOOK, DRAWING_BRUSH,
	AUDIO_PLAY, INPUT_MAP, DATA_SLOT, RNG_STREAM, TIME_TICK, TIME_TIMER,
	NET_WORKSHOP, DEBUG_CMD,
]


## 令牌是否合法（含永不授予集）。
static func is_known(token: StringName) -> bool:
	return ALL_KNOWN.has(token) or NEVER_GRANTED.has(token)


## 令牌是否永不授予。
static func is_never(token: StringName) -> bool:
	return NEVER_GRANTED.has(token)


## 令牌是否默认授予。
static func is_default(token: StringName) -> bool:
	return DEFAULT_GRANTED.has(token)


## 计算实际授予的能力集 = 默认授予 ∪（声明中合法的、非永不授予的）。
## declared: Array[StringName]，manifest.capabilities。
## 返回 { granted: Array[StringName], rejected: Array[StringName] }。
## rejected 记录被拒绝的非法/永不授予令牌（用于加载日志）。
static func resolve(declared: Array) -> Dictionary:
	var granted: Array[StringName] = []
	for t in DEFAULT_GRANTED:
		if not granted.has(t):
			granted.append(t)
	var rejected: Array[StringName] = []
	for t in declared:
		var token: StringName = StringName(str(t))
		if is_never(token) or not is_known(token):
			rejected.append(token)
		elif not granted.has(token):
			granted.append(token)
	return {"granted": granted, "rejected": rejected}


## 判断某令牌是否在授予集内。
static func has(granted: Array[StringName], token: StringName) -> bool:
	return granted.has(token)
