extends SceneTree

func _init() -> void:
	var level := PuzzleGenerator.new().generate("classic", Vector2i(5, 5), 7, 1)
	print("empty=", level.is_empty())
	if level.is_empty():
		quit()
		return
	print("revealed.size=", int(level["revealed"].size()))
	for rv in level["revealed"]:
		print("  rv=", rv)
	quit()
