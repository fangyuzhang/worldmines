extends SceneTree
func _process(_d: float) -> bool:
	var api: Node = root.get_node_or_null("ModAPI")
	if api == null:
		print("ModAPI autoload 不可见")
		quit(1); return true
	var bundled: String = str(api.get("BUNDLED_MODS_DIR"))
	var mods_dir: String = str(api.get("MODS_DIR"))
	print("bundled=", bundled, " open=", DirAccess.open(bundled) != null)
	print("mods_dir=", mods_dir, " global=", ProjectSettings.globalize_path(mods_dir))
	print("mk recursive => ", DirAccess.make_dir_recursive_absolute(mods_dir), " (0=OK)")
	print("open mods_dir => ", DirAccess.open(mods_dir) != null)
	var d := DirAccess.open(bundled)
	if d != null:
		var dirs := d.get_directories()
		print("mod dirs = ", dirs.size())
		for i in mini(dirs.size(), 2):
			var name := str(dirs[i])
			var src := bundled.path_join(name)
			print("  ", name, " manifest=", FileAccess.file_exists(src.path_join("manifest.json")),
				" entry=", FileAccess.file_exists(src.path_join("entry.gd")))
			var dst := mods_dir.path_join(name)
			print("     mk dst => ", DirAccess.make_dir_recursive_absolute(dst))
			var f := FileAccess.open(dst.path_join("manifest.json"), FileAccess.WRITE)
			print("     open dst write => ", f != null, " err=", FileAccess.get_open_error())
			if f != null: f.close()
	print("bootstrap => ", api.call("bootstrap_bundled_mods"))
	print("registry = ", RuleRegistry.default().all_ids().size())
	quit(0)
	return true
