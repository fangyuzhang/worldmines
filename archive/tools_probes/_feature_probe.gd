extends SceneTree

## 盘特征采集：对 O1 跑 N 个 seed，记录「盘特征 vs 最终难度」——
## 用于接受率专项的关联分析（找「天生会难的盘」的特征 → 定向布雷依据）。
## 用法：godot --headless --path . -s res://tools/_feature_probe.gd -- [side] [count]
const CliShutdown := preload("res://tools/cli_shutdown.gd")

const NB8 := [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]
const AXES := [
	[Vector2i(-1, 0), Vector2i(1, 0)],
	[Vector2i(0, -1), Vector2i(0, 1)],
	[Vector2i(-1, -1), Vector2i(1, 1)],
	[Vector2i(1, -1), Vector2i(-1, 1)],
]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var side := int(args[0]) if args.size() >= 1 and str(args[0]) != "" else 7
	var count := int(args[1]) if args.size() >= 2 and str(args[1]) != "" else 60
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod("res://demo/mods/o1_duichuan")
	var mines_n: int = int(RuleFeasibility.resolve_mines("o1", [], side)["mines"])
	print("seed,axis_total,zero_clues,clustering,edge_mines,difficulty,clue_count")
	for seed in range(1, count + 1):
		var gen := PuzzleGenerator.new()
		var level: Dictionary = gen.generate_with_rules(
			"o1", [], Vector2i(side, side), mines_n, seed, 0, 50, null, side * side * 3000)
		if level.is_empty():
			print("%d,,,,,,-1,0" % seed)
			continue
		var ms := {}
		for m in level.get("mines", []):
			ms[Vector2i(int(m["c"]), int(m["r"]))] = true
		var axis_total := 0
		var zero_clues := 0
		var clustering := 0
		var edge_mines := 0
		for r in side:
			for c in side:
				var p := Vector2i(c, r)
				if ms.has(p):
					if c == 0 or r == 0 or c == side - 1 or r == side - 1:
						edge_mines += 1
					for d in NB8:
						var q: Vector2i = p + d
						if q.x >= 0 and q.x < side and q.y >= 0 and q.y < side and ms.has(q):
							clustering += 1
					continue
				var k := 0
				for ax in AXES:
					var pa: Vector2i = p + ax[0]
					var pb: Vector2i = p + ax[1]
					if pa.x < 0 or pa.x >= side or pa.y < 0 or pa.y >= side:
						continue
					if pb.x < 0 or pb.x >= side or pb.y < 0 or pb.y >= side:
						continue
					if ms.has(pa) and ms.has(pb):
						k += 1
				axis_total += k
				if k == 0:
					zero_clues += 1
		clustering = clustering / 2
		var dp: Dictionary = level.get("difficulty_profile", {})
		print("%d,%d,%d,%d,%d,%.3f,%d" % [
			seed, axis_total, zero_clues, clustering, edge_mines,
			float(dp.get("difficulty", 0.0)), int(dp.get("clue_count", 0))])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
