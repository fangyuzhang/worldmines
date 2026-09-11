# level_artifact.gd —— 关卡产物（方案 D：seed + 结果成对落盘，可回放校验）
class_name LevelArtifact
extends RefCounted

var recipe: SeedRecipe = null    # 种子配方（可回放）
var level: Dictionary = {}       # 生成结果（关卡 JSON）
