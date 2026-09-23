export HOME=/root
cd /root/minesweeper
echo '=== mods dir ==='
ls demo/mods/
echo '=== o5x mod files ==='
ls demo/mods/o5_xiemai/ 2>&1
echo '=== md5 of local-copy vs server ==='
md5sum demo/mods/o5_xiemai/entry.gd
cat > /tmp/verify_one.gd << 'EOF'
extends SceneTree

func _initialize() -> void:
	var sc: Variant = load("res://demo/mods/o5_xiemai/entry.gd")
	if sc == null:
		print("LOAD FAIL")
		quit(1)
		return
	sc.new().call("on_load")
	print("registered=", RuleRegistry.default().resolve(&"o5x") != null)
	for name in ["easy_01", "easy_18", "intro_01"]:
		var f := FileAccess.open("user://batch_o5x/x_o5x/8x8/%s.json" % name, FileAccess.READ)
		if f == null:
			print(name, " READ FAIL")
			continue
		var level: Dictionary = JSON.parse_string(f.get_as_text())
		f.close()
		var log: Dictionary = ProofLog.build(level)
		print("%s: solved=%s rounds=%s reason=%s" % [name, str(log.get("solved")), str(log.get("rounds")), str(log.get("reason"))])
	quit(0)
EOF
timeout 400 /opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64 --headless --path . -s /tmp/verify_one.gd 2>&1 | grep -v -E 'WARNING|at:|Godot Engine|Godot_v|root/superuser|GODOT_SILENCE|game_helper' | head -20
echo ONE_DONE
