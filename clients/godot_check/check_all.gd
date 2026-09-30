extends SceneTree

# Loads every script in the generated addon, which compiles it. A generator
# fault (a type that does not exist, a statically wrong expression) fails
# here rather than in a game's editor.

func _init() -> void:
	var failed := 0
	var total := 0
	var stack := ["res://addons/gamend"]
	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		var dir := DirAccess.open(dir_path)
		for sub in dir.get_directories():
			stack.append(dir_path.path_join(sub))
		for file in dir.get_files():
			if not file.ends_with(".gd"):
				continue
			total += 1
			var path := dir_path.path_join(file)
			var script: GDScript = load(path)
			if script == null or not script.can_instantiate():
				failed += 1
				print("FAILED: ", path)
	print("checked=", total, " failed=", failed)
	quit(1 if failed > 0 else 0)
