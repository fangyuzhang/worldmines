# _probe_modes.gd —— 打印选关页真实 MODES id 全表（核对导入白名单口径）
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	# 与游戏同口径：注册表由 pre_run 之外的裸跑可能为空 —— 这里先加载内置规则（game 里由 autoload 完成）
	var mods := ["legacy_rules"]
	print("[modes] 开始（不加载 mod，只取内置）")
	var modes: Array = VariantCatalog.build_modes(Vector2i(5, 5), 5)
	var ids: Array = []
	var kinds := {}
	for m in modes:
		ids.append(str(m["id"]))
		kinds[str(m["id"])] = str(m.get("kind", "?"))
	print("[modes] 总数: %d" % ids.size())
	print("[modes] ids: %s" % ", ".join(ids))
	print("[modes] 含 dt: %s" % ids.has("dt"))
	print("[modes] 含 classic: %s" % ids.has("classic"))
	print("[modes] 含 mx/rl/qd/pf/clock/loopruns/total_mines（应为 False）: %s" % [
		ids.has("mx") or ids.has("rl") or ids.has("qd") or ids.has("pf")
		or ids.has("clock") or ids.has("loopruns") or ids.has("total_mines")])
	CliShutdown.request_exit(0)
