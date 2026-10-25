# 箭头方向诊断：比对列车实际位移方向与 dirv 箭头朝向的点积。
extends SceneTree


func _initialize() -> void:
	var db = load("res://src/autoload/db.gd").new()
	root.add_child(db)
	var gt = load("res://src/autoload/game_time.gd").new()
	root.add_child(gt)
	gt.t = 43200.0  # 12:00
	var sim = load("res://src/autoload/simulation.gd").new()
	root.add_child(sim)
	sim._process(0.0)

	var n := 0
	var codes: Array = sim.states.keys()
	codes.sort()
	for code in codes:
		var st: Dictionary = sim.states[code]
		if st.get("status", "") != "run":
			continue
		if str(st.get("line", "")) != "huning_chengji" and str(st.get("line", "")) != "jinghu_hsr":
			continue
		var st2: Dictionary = sim.state_for(db.train_by_code[code], gt.t + 30.0)
		if st2.get("status", "") != "run":
			continue
		var move: Vector2 = st2["pos"] - st["pos"]
		if move.length() < 50.0:
			continue
		var dot: float = move.normalized().dot(st["dirv"])
		print("%s line=%s dir=%s dot=%.2f dx=%.0f dy=%.0f" % [
			code, st["line"], st["dir"], dot, move.x, move.y])
		n += 1
		if n >= 16:
			break
	quit()
