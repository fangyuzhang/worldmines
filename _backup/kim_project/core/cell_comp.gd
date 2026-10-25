# cell_comp.gd —— CellComp 基类（文档 §2.2）
# 行为效果强制声明原则：任何会改变盘面状态的 onReveal/onFlag 必须提供 effectDecl。
# P0 空壳；P4 由 WASM 沙箱脚本落地。
class_name CellComp
extends RefCounted

var defName: String = ""


## 人话描述：这个 Comp 干什么。
func describe() -> String:
	return ""


## 若影响线索计算，声明聚合方式。
func clueDecl() -> Dictionary:
	return {}


## 若引入约束，声明约束。
func constraintDecl() -> Dictionary:
	return {}


## 若 onReveal/onFlag 会改变盘面状态，必须声明效果（P4 强制校验）。
func effectDecl() -> Dictionary:
	return {}


## 执行用脚本快径（P4 沙箱运行；不提供推理依据）。
func on_reveal(_cell: Cell, _board: Board) -> void:
	pass


func on_flag(_cell: Cell, _board: Board) -> void:
	pass
