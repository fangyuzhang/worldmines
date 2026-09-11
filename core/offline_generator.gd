# offline_generator.gd —— 离线批量生成（方案 D）
# 只做「批量调度」，生成逻辑复用 LevelGenerator（不复制），与回放校验共享同一份管道。
class_name OfflineGenerator
extends RefCounted


## 批量生成，返回 Array[LevelArtifact]。
func batch(recipes: Array) -> Array:
	var out: Array = []
	var gen := LevelGenerator.new()
	for r in recipes:
		if r is SeedRecipe:
			var art := LevelArtifact.new()
			art.recipe = r
			art.level = gen.generate(r)
			out.append(art)
	return out
