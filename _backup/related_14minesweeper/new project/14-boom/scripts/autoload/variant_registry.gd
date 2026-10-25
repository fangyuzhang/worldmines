extends Node
## 变体注册表（autoload 单例，节点名 VariantRegistry）
##
## 【模块化框架的核心】
## - 启动时自动扫描 res://scripts/variants/ 目录下所有 .gd 文件
## - 每个文件若继承 VariantBase 且 id 唯一，则注册为一个变体
## - 新增一个变体 = 在 variants/ 目录放一个 .gd 文件，无需改任何代码
## - 支持从额外路径加载（为将来 Steam 创意工坊 mod 目录预留）
##
## 用法：
##   VariantRegistry.get_variant("MX")
##   VariantRegistry.all_variants()
##   VariantRegistry.by_category(VariantBase.Category.GENERATION)

const DEFAULT_DIR := "res://scripts/variants"

var _variants: Dictionary = {}  # id -> VariantBase

func _ready() -> void:
	register_dir(DEFAULT_DIR)

## 扫描一个目录，加载其中的变体模块。可被 mod 系统重复调用。
func register_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_warning("VariantRegistry: 无法打开变体目录 %s" % dir_path)
		return
	for fname in dir.get_files():
		if not fname.ends_with(".gd"):
			continue
		var script := load(dir_path + "/" + fname)
		if script == null or not (script is GDScript):
			continue
		# 判断是否继承 VariantBase：实例化后检查
		if not script.can_instantiate():
			continue
		var instance = script.new()
		if not (instance is VariantBase):
			continue
		if instance.id.is_empty():
			push_warning("VariantRegistry: %s 缺少 id" % fname)
			continue
		if _variants.has(instance.id):
			push_warning("VariantRegistry: 变体 id '%s' 重复，跳过 %s" % [instance.id, fname])
			continue
		_variants[instance.id] = instance
		print("[VariantRegistry] 注册变体: %s (%s) [%s]" % [
			instance.id, instance.display_name,
			"生成层" if instance.category == VariantBase.Category.GENERATION else "数字规则"])

func get_variant(id: String) -> VariantBase:
	return _variants.get(id, null)

func all_variants() -> Array:
	return _variants.values()

func all_ids() -> Array:
	return _variants.keys()

func by_category(cat: VariantBase.Category) -> Array:
	var out: Array = []
	for v in _variants.values():
		if v.category == cat:
			out.append(v)
	return out

func generation_variants() -> Array:
	return by_category(VariantBase.Category.GENERATION)

func number_variants() -> Array:
	return by_category(VariantBase.Category.NUMBER_RULE)

func has_variant(id: String) -> bool:
	return _variants.has(id)

func variant_count() -> int:
	return _variants.size()
