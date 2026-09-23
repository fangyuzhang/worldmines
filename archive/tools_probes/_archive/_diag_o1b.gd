extends SceneTree

## O1 诊断 v2：对真解逐约束求值（GDScript 黑盒），精确定位为假的约束。
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod("res://demo/mods/o1_duichuan")
	var rule: Object = RuleRegistry.default().resolve(&"o1")
	var side := 5
	var mines_n := 10
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var mine_set := {}
	while mine_set.size() < mines_n:
		mine_set[Vector2i(rng.randi_range(0, side - 1), rng.randi_range(0, side - 1))] = true

	var asg := {}
	for r in side:
		for c in side:
			asg[CPIR.cell_key(r, c)] = 1 if mine_set.has(Vector2i(c, r)) else 0

	var bad_count := 0
	for r in range(1, side - 1):
		for c in range(1, side - 1):
			var pos := Vector2i(c, r)
			var val: int = int(rule.call("compute_clue", mine_set, pos, Vector2i(side, side)))
			var b := RuleBuilder.new(side, side, mines_n, 0)
			rule.call("build_clue_constraints", b, pos, val)
			# z 赋值：按轴过滤顺序（与 build 内一致）
			var zi := 0
			for ax in rule.AXES:
				var pa: Vector2i = pos + ax[0]
				var pb: Vector2i = pos + ax[1]
				if pa.x < 0 or pa.x >= side or pa.y < 0 or pa.y >= side \
						or pb.x < 0 or pb.x >= side or pb.y < 0 or pb.y >= side:
					continue
				asg[CPIR.aux_key(zi)] = 1 if (mine_set.has(pa) and mine_set.has(pb)) else 0
				zi += 1
			for ci in b.constraints.size():
				var con: Dictionary = b.constraints[ci]
				if not CPIR.eval_constraint(con, asg):
					bad_count += 1
					print("!! false: pos=%s value=%d zi=%d con=%s" % [str(pos), val, zi, JSON.stringify(con)])
	print("为假约束数: %d（0 = 编码自洽）" % bad_count)
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
