# replay_verifier.gd —— 回放校验（方案 D）
# 用 artifact.recipe 重跑 LevelGenerator，比对落盘结果是否一致（防篡改/防漂移）。
class_name ReplayVerifier
extends RefCounted


func verify(artifact: LevelArtifact) -> bool:
	if artifact == null or artifact.recipe == null:
		return false
	var gen := LevelGenerator.new()
	var regenerated := gen.generate(artifact.recipe)
	return str(regenerated) == str(artifact.level)
