# variant_axes.gd —— 官方三轴席位清单的**唯一事实源**（GDD §4）。
#
# 为什么独立成 core 类：此前 `ui/variant_catalog.gd`（选关页）与 `tools/batch_all_variants.gd`
# （量产）各持一份同源副本，靠注释「两处必须一起改」约束——2026-09-18 已真实漂移过一次
#（量产侧组合目录名用 c_o1/g_s1，选关页目录用 o1/s1，差一个前缀导致关卡进库了点不到）。
# 抽到 core 后 UI 层与工具层都引用这里，物理上不可能再漂移。
#
# 约定：三个数组**只读**（const 共享引用，任何调用方不得 append/erase/改元素）。
class_name VariantAxes
extends RefCounted


## 观测轴（O1~O10）：每格一个数字的线索型算子。
const OBS := ["o1", "o2", "o3", "o4", "o5x", "o6", "o7", "o8", "o9", "o10"]
## 结构轴（S1~S7）：棋盘级形状/拓扑约束。
const STRUCT := ["s1", "s2", "s3", "s4", "s5", "s6", "s7"]
## 守恒轴（Z1~Z5）：棋盘级计数平衡约束（每关至多 1 个，GDD §5.1 硬限制 3）。
const CONSERVE := ["z1", "z2", "z3", "z4", "z5"]
