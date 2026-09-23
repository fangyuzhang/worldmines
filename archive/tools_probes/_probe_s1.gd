extends SceneTree

## 诊断（临时）：s1「局部禁形」构造式无产出。
## 与内置等价规则 pf、以及产出正常的 o1/o2/o7 对照，分辨是「真产不出」还是「太慢/入口错」。
##
## 跑法：
##   & $GODOT --headless --path . -s tools/_probe_s1.gd -- 7 12
##   （参数：边长 雷数，默认 7 12）
const CliShutdown := preload("res://tools/cli_shutdown.gd")

const MOD_ENTRIES := {
	"s1": "res://demo/mods/s1_jinxing/entry.gd",
	"o1": "res://demo/mods/o1_duichuan/entry.gd",
	"o2": "res://demo/mods/o2_linxu/entry.gd",
	"o7": "res://demo/mods/o7_qixian/entry.gd",
	"z1": "res://demo/mods/z1_jingxiang/entry.gd",
}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var side := int(args[0]) if args.size() >= 1 else 7
	var mines := int(args[1]) if args.size() >= 2 else 12
	var size := Vector2i(side, side)

	# `-s` 没有 autoload → 手工装 mod 规则（同 test/_pre_run.gd 的做法）
	for id in MOD_ENTRIES:
		var gd: GDScript = load(MOD_ENTRIES[id])
		if gd == null:
			print("[probe] %s 载入失败" % id)
			continue
		gd.new().call("on_load")
	print("[probe] 注册表 %d 条规则" % RuleRegistry.default().all_ids().size())

	var gen := PuzzleGenerator.new()
	# 第 3 个参数可指定只跑某些 id（逗号分隔），便于聚焦最慢的对照项
	var only: PackedStringArray = str(args[2]).split(",") if args.size() >= 3 else PackedStringArray()
	var codes: Array = Array(only) if only.size() > 0 else ["s1", "pf", "o1", "o2", "o7", "z1"]
	for code in codes:
		var has_rule := RuleRegistry.default().resolve(StringName(code)) != null
		if not has_rule:
			print("[probe] %-5s 规则未注册，跳过" % code)
			continue
		var ok := 0
		var stats: Dictionary = {}
		var t0 := Time.get_ticks_msec()
		for k in 3:
			var r: Dictionary = gen.generate_constructive(code, size, mines, 1000 + k * 7)
			if not r.is_empty():
				ok += 1
			stats = gen.last_call_stats
		var ms := Time.get_ticks_msec() - t0
		print("[probe] %-5s %dx%d/%d → %d/3 产出   总耗时 %d ms" % [code, side, side, mines, ok, ms])
		print("[probe]       stats: %s" % JSON.stringify(stats))

	# s1 的布雷器单独验：绕过生成管线，直接看 place_mines 能不能出盘
	var s1: Object = RuleRegistry.default().resolve(&"s1")
	if s1 != null and s1.has_method("place_mines"):
		var rng := RandomNumberGenerator.new()
		rng.seed = 42
		var hit := 0
		var t1 := Time.get_ticks_msec()
		for k in 50:
			var arr: Variant = s1.call("place_mines", rng, side, side, mines)
			if arr is Array and (arr as Array).size() == mines:
				hit += 1
		print("[probe] s1.place_mines 直调 50 次 → %d 次出满盘（%d ms）" % [hit, Time.get_ticks_msec() - t1])

	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
