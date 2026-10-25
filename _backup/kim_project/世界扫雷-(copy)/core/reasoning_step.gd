# reasoning_step.gd —— 推理步骤（文档 §6.2 证明日志）
# 一步推理结论：由 sources（依据线索格）推出 pos 格为 state。
class_name ReasoningStep
extends RefCounted

var pos: Vector2i = Vector2i.ZERO   # 结论格（内部坐标 x=列, y=行）
var state: String = ""              # "safe" / "mine"
var method: String = "one_step"     # 推理方法：one_step / reduction / enumeration
var sources: Array[Vector2i] = []   # 依据的线索格
var rule: String = ""               # 规则标识（classic/clock/fr/...）
var proof: String = ""              # 推理文字描述


## 序列化为可展示/可存储的 dict。
func to_dict() -> Dictionary:
	var src: Array = []
	for p in sources:
		src.append([p.x, p.y])
	return {
		"pos": [pos.x, pos.y],
		"state": state,
		"method": method,
		"sources": src,
		"rule": rule,
		"proof": proof,
	}
