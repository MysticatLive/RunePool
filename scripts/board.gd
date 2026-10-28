extends Node2D
class_name Board

enum State { ACTIVE, PAUSED, VICTORY, LOSS }
var state: State = State.ACTIVE

signal board_ready
signal game_ended

const LEVEL_DATA: Resource = preload("res://scripts/levels.gd")
const CLUSTER_SCENE: PackedScene = preload("res://scenes/gem_cluster.tscn")
const GEM_SCENE: PackedScene = preload("res://scenes/gem.tscn")
const RUNE_SCENE: PackedScene = preload("res://scenes/rune.tscn")
const BRICK_SCENE: PackedScene = preload("res://scenes/brick.tscn")
const CHARACTER_SCENE: PackedScene = preload("res://scenes/character.tscn")
const RAINBOW_TEXT_SCENE = preload("uid://q5q1mlwi48lm")

const CELL_SIZE: int = 8
const BASE_GEM_COUNT: int = 16
const COMPLEX_PIECE_TURN_COUNT: int = 5
var debug_attack_enabled: bool = false
var width: int = 10
var height: int = 13
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var turn_number: int = 1
var player_id: int = 1
var character: Character
var enemy: Character
var incoming_gems_waiting: int = 0
var opponent_board: Board
var speed: float = 0.0
var difficulty: int = 0
var grid: Array[Array] = []
var colors: Array[String]
var runes_remaining: int = 0
var ghost_gem_alpha: float = 0.15
var time_before_first_cluster: float = 3.0
var time_between_rune_spawn: float = 0.05
var board_offset: Vector2 = Vector2(
	(1 * CELL_SIZE) + (CELL_SIZE / 2),
	(3 * CELL_SIZE) + (CELL_SIZE / 2)
)
var cell_rune_space: int = 6
var active_cluster: GemCluster
var next_cluster: GemCluster
var cluster_spawn_cell: Vector2i
var cluster_preview_offset: Vector2 = Vector2(
	(5 * CELL_SIZE) + (CELL_SIZE / 2),
	(1 * CELL_SIZE) + (CELL_SIZE / 2)
)
var ghost_layer: Node2D
var input: PlayerInput = PlayerInput.new()

func _ready() -> void:
	width = clamp(width, 2, 15)
	height = clamp(height, 5, 15)
	grid.resize(width)
	cluster_spawn_cell = Vector2i((width / 2) - 1, 0)
	for i in range(width):
		grid[i] = []
		grid[i].resize(height)
	ghost_layer = Node2D.new()
	add_child(ghost_layer)

func tick(delta: float) -> void:
	if state != State.ACTIVE:
		return
	_try_debug_attack()
	if active_cluster:
		active_cluster.handle_input(delta)
		active_cluster.tick(delta)
		next_cluster.tick(delta)
		#if input.rotate_left:
		#	_drop_enemy_gem()

func _try_debug_attack() -> void:
	if !debug_attack_enabled:
		return
	if Input.is_action_just_pressed("ui_accept"):
		character.check_combo({
			"gems": 8,
			"lines": 2
		})

func _on_game_end() -> void:
	game_ended.emit()
	if state == State.LOSS:
		if character:
			character.set_max_hp(1)
			character.take_damage(99)
		if opponent_board:
			opponent_board.state = State.VICTORY
			opponent_board._on_game_end()
	clear_ghosts()
	if enemy:
		enemy.queue_free()
	if active_cluster:
		active_cluster.queue_free()
	if next_cluster:
		next_cluster.queue_free()
	_load_next_room()

func _load_next_room() -> void:
	await(get_tree().create_timer(4.0)).timeout
	if Global.player_count > 1:
		Transition.change_scene("res://scenes/menus/battle_menu.tscn")
		return
	if Global.current_floor - 1 <= Global.story_mode_enemies.size():
		Transition.change_scene_loading(
			"res://scenes/game_room.tscn",
			"Descending to Floor " + str(Global.current_floor) + "/8",
			"",
			"slide_up",
		)
		return
	Transition.change_scene("res://scenes/menus/main_menu.tscn")

func set_speed(_speed: int) -> void:
	speed = _speed

func set_difficulty(_difficulty: int) -> void:
	difficulty = _difficulty

func set_player_id(_player_id: int) -> void:
	player_id = _player_id

func set_character(character_id) -> void:
	character = CHARACTER_SCENE.instantiate()
	character.character_id = character_id
	character.board = self
	add_child(character)
	character.set_max_hp(-1)
	character.position = Vector2(
		(-6 * CELL_SIZE) + (CELL_SIZE / 2),
		(10 * CELL_SIZE) + (CELL_SIZE / 2) + 1
	)
	position.y += 1 * CELL_SIZE
	if Global.player_count == 2:
		if player_id == 1:
			position.x += 8 * CELL_SIZE
			return
		if player_id == 2:
			character.position.x += 17 * CELL_SIZE
			position.x += 9 * CELL_SIZE
			return
	if !enemy:
		position.x = 6 * CELL_SIZE
		return

func set_enemy(character_id) -> void:
	enemy = CHARACTER_SCENE.instantiate()
	enemy.character_id = character_id
	enemy.flipped_portrait = true
	enemy.board = self
	enemy.opponent = character
	character.opponent = enemy
	add_child(enemy)
	enemy.position = Vector2(
		((width + 1) * CELL_SIZE) + (CELL_SIZE / 2),
		(10 * CELL_SIZE) + (CELL_SIZE / 2) + 1
	)
	_center_board_enemy()

func _center_board_enemy() -> void:
	var center_x = get_viewport_rect().size.x / 2
	position.x = center_x - (((width + 2) * CELL_SIZE) / 2)

func _reset_board() -> void:
	for i in range(width):
		for j in range(height):
			var next: CellObject = grid[i][j]
			if next == null:
				continue
			next.destroy()

func set_seed(_seed: int) -> void:
	rng.seed = _seed

func load_level(level_id: String) -> void:
	_reset_board()
	if level_id == "random":
		level_id = LEVEL_DATA.get_random_level_name()
	var layout = LEVEL_DATA.LEVEL_LAYOUTS[level_id]
	if !layout:
		layout = LEVEL_DATA.LEVEL_LAYOUTS["classic"]
	for i in range(layout.size()):
		for j in range(layout[i].length()):
			var cell = layout[i][j]
			if cell != "#":
				continue
			_create_brick(Vector2i(j, i))
	_refresh_colors()
	var first_cluster: GemCluster = _create_cluster()
	first_cluster.z_index += 5
	clear_ghosts()
	var rune_pattern: Array[Array] = _generate_rune_pattern()
	var runes: Array[Rune] = await _apply_rune_pattern(rune_pattern)
	if get_tree():
		await get_tree().create_timer(time_before_first_cluster).timeout
	for rune in runes:
		if !rune or !rune.animated_sprite:
			continue
		rune.animated_sprite.play()
	board_ready.emit()
	_begin_next_cluster()

func _refresh_colors() -> void:
	colors = Global.COLORS.duplicate(true)
	colors.pop_at(rng.randi_range(0, colors.size() - 1))

func set_cell_rune_space(tiles: int) -> void:
	cell_rune_space = clamp(tiles, 1, height - 1)

func _cell_is_valid(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.x >= width:
		return false
	if cell.y < 0 or cell.y >= height:
		return false
	return true

func cell_is_free(cell: Vector2i) -> bool:
	if !_cell_is_valid(cell):
		return false
	return grid[cell.x][cell.y] == null

func get_position_at_cell(cell: Vector2i) -> Vector2:
	if !_cell_is_valid(cell):
		return -Vector2.ONE
	return Vector2(cell.x * CELL_SIZE, cell.y * CELL_SIZE) + board_offset

func get_cell_at_object(cell_object: CellObject) -> Vector2i:
	if !cell_object:
		return -Vector2i.ONE
	return Vector2i(cell_object.target_position - board_offset) / CELL_SIZE

func tp_object_to_cell(cell_object: CellObject, cell: Vector2i) -> void:
	var cell_position: Vector2 = get_position_at_cell(cell)
	if cell_position == -Vector2.ONE:
		return
	var previous_position = get_cell_at_object(cell_object)
	if _cell_is_valid(previous_position):
		grid[previous_position.x][previous_position.y] = null
	cell_object.position = cell_position
	cell_object.target_position = cell_position
	grid[cell.x][cell.y] = cell_object

func set_object_destination_to_cell(cell_object: CellObject, cell: Vector2i) -> void:
	var cell_position: Vector2 = get_position_at_cell(cell)
	if cell_position == -Vector2.ONE:
		return
	var previous_position = get_cell_at_object(cell_object)
	if _cell_is_valid(previous_position):
		grid[previous_position.x][previous_position.y] = null
	cell_object.target_position = cell_position
	grid[cell.x][cell.y] = cell_object

func _generate_empty_pattern() -> Array[Array]:
	var pattern: Array[Array] = []
	pattern.resize(width)
	for i in range(width):
		pattern[i] = []
		pattern[i].resize(height)
	return pattern

func _generate_rune_pattern() -> Array[Array]:
	if colors.size() != 3:
		return []
	var pattern: Array[Array] = _generate_empty_pattern()
	var amount: int = Global.current_floor - 1 + BASE_GEM_COUNT + (2 * round(difficulty))
	var available_cells: Array[Vector2i] = _get_available_cells()
	for i in range(amount):
		var size: int = available_cells.size()
		var index: int = rng.randi_range(0, size - 1)
		var cell: Vector2i = available_cells.get(index)
		available_cells.pop_at(index)
		if !cell_is_free(cell):
			continue
		pattern[cell.x][cell.y] = colors[rng.randi_range(0, 2)]
	return pattern

func _apply_rune_pattern(rune_pattern: Array[Array]) -> Array[Rune]:
	if !rune_pattern:
		return []
	if rune_pattern.size() <= 0:
		return []
	var runes: Array[Rune] = []
	for i in range(rune_pattern.size()):
		for j in range(rune_pattern[i].size()):
			var cell_color = rune_pattern[i][j]
			if cell_color == null:
				continue
			runes.append(_create_rune(Vector2i(i, j), cell_color))
			if !get_tree():
				return runes
			await get_tree().create_timer(time_between_rune_spawn).timeout
	return runes

func _get_available_cells() -> Array[Vector2i]:
	var options: Array[Vector2i] = []
	for i in range(width):
		for j in range(height - cell_rune_space, height):
			var cell: Vector2i = Vector2i(i, j)
			if !cell_is_free(cell):
				continue
			options.append(cell)
	return options

func clear_ghosts() -> void:
	for child in ghost_layer.get_children():
		child.queue_free()

func update_ghost_cluster(cluster: GemCluster) -> void:
	if !cluster or !Settings.ghost_gems_enabled:
		return
	clear_ghosts()
	var simulated_cells = _simulate_cluster_drop(cluster)
	for i in range(simulated_cells.size()):
		var ghost = GEM_SCENE.instantiate()
		ghost.color = cluster.gems[i].color
		ghost.modulate = Color(1, 1, 1, ghost_gem_alpha)
		ghost.set_process(false)
		ghost.set_physics_process(false)
		ghost_layer.add_child(ghost)
		ghost.target_position = get_position_at_cell(simulated_cells[i])
		ghost.position = ghost.target_position

func _simulate_cluster_drop(cluster: GemCluster) -> Array[Vector2i]:
	var base: Vector2i = cluster.pivot_cell
	while true:
		var next := base + Vector2i.DOWN
		if !_cluster_can_move_to_shape(cluster, next):
			break
		base = next
	var result: Array[Vector2i] = []
	for offset in cluster.shape_cells:
		result.append(base + offset)
	return result

func _cluster_can_move_to_shape(cluster: GemCluster, pivot: Vector2i) -> bool:
	for offset in cluster.shape_cells:
		var cell := pivot + offset
		if !_cell_is_valid(cell):
			return false
		var cell_object = grid[cell.x][cell.y]
		if cell_object == null:
			continue
		if cell_object is Gem and cell_object.cluster_id == cluster.cluster_id:
			continue
		return false
	return true

func _create_preview_cluster() -> GemCluster:
	var cluster: GemCluster = CLUSTER_SCENE.instantiate()
	cluster.board = self
	cluster.pivot_cell = Vector2i.ZERO
	cluster.can_spawn_complex_piece = turn_number % COMPLEX_PIECE_TURN_COUNT == 0
	add_child(cluster)
	cluster.position = cluster_preview_offset
	cluster.target_position = cluster.position
	return cluster

func _begin_next_cluster() -> void:
	if active_cluster.begin_falling():
		return
	state = State.LOSS
	_on_game_end()

func _create_cluster() -> GemCluster:
	if active_cluster:
		active_cluster.queue_free()
	if !next_cluster:
		next_cluster = _create_preview_cluster()
	active_cluster = next_cluster
	active_cluster.pivot_cell = cluster_spawn_cell
	next_cluster = _create_preview_cluster()
	active_cluster.set_cluster_id(turn_number)
	return active_cluster

func _create_gem(cell: Vector2i, color: String) -> CellObject:
	if !cell_is_free(cell):
		return
	var gem: Gem = GEM_SCENE.instantiate()
	gem.color = color
	add_child(gem)
	tp_object_to_cell(gem, cell)
	return gem

func _create_rune(cell: Vector2i, color: String) -> CellObject:
	if !cell_is_free(cell):
		return
	var rune: Rune = RUNE_SCENE.instantiate()
	rune.color = color
	rune.board = self
	add_child(rune)
	tp_object_to_cell(rune, cell)
	runes_remaining += 1
	return rune

func _create_brick(cell: Vector2i) -> CellObject:
	if !cell_is_free(cell):
		return
	var brick = BRICK_SCENE.instantiate()
	add_child(brick)
	tp_object_to_cell(brick, cell)
	return brick

func _cell_can_fall(cell: Vector2i) -> bool:
	if !is_instance_valid(grid[cell.x][cell.y]):
		return false
	var cell_object: CellObject = grid[cell.x][cell.y]
	if cell_object == null:
		return false
	if !cell_object.has_gravity:
		return false
	if cell_object is Gem:
		var gem: Gem = cell_object as Gem
		if gem.cluster_id != -1:
			return false
	return true

func _cluster_can_fall(cluster_id: int) -> bool:
	for i in range(width):
		for j in range(height):
			if !is_instance_valid(grid[i][j]):
				continue
			var cell_object: CellObject = grid[i][j]
			if cell_object is not Gem:
				continue
			var gem: Gem = cell_object as Gem
			if gem.cluster_id != cluster_id:
				continue
			var cell_below: Vector2i = Vector2i(i, j + 1)
			if !_cell_is_valid(cell_below):
				return false
			if !is_instance_valid(grid[cell_below.x][cell_below.y]):
				continue
			var other: CellObject = grid[cell_below.x][cell_below.y]
			if other == null:
				continue
			if other is Gem and other.cluster_id == cluster_id:
				continue
			return false
	return true

func _apply_gravity() -> bool:
	var moved: bool = false
	var processed_clusters: Array[int] = []
	#move clusters
	for i in range(width):
		for j in range(height):
			if !is_instance_valid(grid[i][j]):
				continue
			var cell_object: CellObject = grid[i][j]
			if cell_object is not Gem:
				continue
			var gem: Gem = cell_object as Gem
			if gem.cluster_id == -1:
				continue
			if processed_clusters.has(gem.cluster_id):
				continue
			processed_clusters.append(gem.cluster_id)
			if _cluster_can_fall(gem.cluster_id):
				_move_cluster_down(gem.cluster_id)
				moved = true
	#move indiv
	for j in range(height - 2, -1, -1): #skip bottom row
		for i in range(width):
			var cell: Vector2i = Vector2i(i, j)
			if !_cell_can_fall(cell):
				continue
			var cell_below: Vector2i = cell + Vector2i.DOWN
			if !cell_is_free(cell_below):
				continue
			var cell_object: CellObject = grid[i][j]
			grid[i][j] = null
			grid[cell_below.x][cell_below.y] = cell_object
			set_object_destination_to_cell(cell_object, cell_below)
			moved = true
	return moved

func _move_cluster_down(cluster_id: int) -> void:
	var cells: Array[Vector2i] = []
	for i in range(width):
		for j in range(height):
			if !is_instance_valid(grid[i][j]):
				continue
			var gem := grid[i][j] as Gem
			if gem and gem.cluster_id == cluster_id:
				cells.append(Vector2i(i, j))
	cells.sort_custom(func(a, b): return a.y > b.y)
	for cell in cells:
		var gem: Gem = grid[cell.x][cell.y]
		set_object_destination_to_cell(gem, cell + Vector2i.DOWN)

func _destroy_cell(cell: Vector2i) -> void:
	if !is_instance_valid(grid[cell.x][cell.y]):
		return
	var cell_object: CellObject = grid[cell.x][cell.y]
	if !cell_object:
		return
	cell_object.destroy()
	grid[cell.x][cell.y] = null

func _get_breakable_lines() -> Array[Array]:
	var lines: Array[Array] = []
	lines.append_array(_scan_lines(true))
	lines.append_array(_scan_lines(false))
	return lines

func _scan_lines(vertical: bool) -> Array[Array]:
	var lines: Array[Array] = []
	var outer_limit = width if vertical else height
	var inner_limit = height if vertical else width
	for outer in range(outer_limit):
		var line_color: String = ""
		var line_cells: Array[Vector2i] = []
		for inner in range(inner_limit):
			var x = outer if vertical else inner
			var y = inner if vertical else outer
			if !is_instance_valid(grid[x][y]) or grid[x][y] is not Gem:
				if line_cells.size() >= 4:
					lines.append(line_cells.duplicate())
				line_cells.clear()
				line_color = ""
				continue
			var gem: Gem = grid[x][y]
			if gem.color == line_color:
				line_cells.append(Vector2i(x, y))
			else:
				if line_cells.size() >= 4:
					lines.append(line_cells.duplicate())
				line_color = gem.color
				line_cells = [Vector2i(x, y)]
		if line_cells.size() >= 4:
			lines.append(line_cells.duplicate())
	return lines

func _destroy_lines(lines: Array[Vector2i]) -> void:
	var affected_clusters: Array[int] = []
	for cell in lines:
		if !is_instance_valid(grid[cell.x][cell.y]):
			continue
		var gem: Gem = grid[cell.x][cell.y]
		if gem.cluster_id != -1 and !affected_clusters.has(gem.cluster_id):
			affected_clusters.append(gem.cluster_id)
		_destroy_cell(cell)
	for cluster_id in affected_clusters:
		_separate_clusters(cluster_id)

func _separate_clusters(cluster_id: int) -> void:
	for i in range(width):
		for j in range(height):
			if !is_instance_valid(grid[i][j]) or grid[i][j] is not Gem:
				continue
			var gem: Gem = grid[i][j] as Gem
			if gem.cluster_id != cluster_id:
				continue
			gem.cluster_id = -1
			gem.set_sprite("base")

func _drop_enemy_gem() -> void:
	if !enemy:
		return
	var options: Array[Vector2i] = []
	for i in range(width):
		var next_cell: Vector2i = Vector2i(i, 0)
		if !cell_is_free(next_cell):
			continue
		options.append(next_cell)
	if options.size() <= 0:
		return
	var cell: Vector2i = options[rng.randi_range(0, options.size() -1)]
	var color: String = colors[rng.randi_range(0, colors.size() -1)]
	var gem: Gem = _create_gem(cell, color)
	if !gem:
		return
	gem.position = enemy.position
	var tween: Tween = get_tree().create_tween()
	tween.tween_property(gem, "position", gem.target_position, 0.75)
	await tween.finished

func receive_attack(amount: int) -> void:
	incoming_gems_waiting += amount

func show_combo_text(gem_count: int) -> void:
	if !character:
		return
	var rainbow_text: RainbowText = RAINBOW_TEXT_SCENE.instantiate()
	character.add_child(rainbow_text)
	rainbow_text.update_combo_text(gem_count)

func resolve_board() -> void:
	var attempts: int = 100
	var gem_count: int = 0
	var line_count: int = 0
	#settle board loop
	while attempts > 0:
		attempts -= 1
		var lines = _get_breakable_lines()
		#check if board is settled
		if lines.size() <= 0:
			if incoming_gems_waiting > 0:
				while incoming_gems_waiting > 0:
					incoming_gems_waiting -= 1
					await _drop_enemy_gem()
		#finish board iteration
		line_count += lines.size()
		var cells_to_destroy: Array[Vector2i] = []
		for line in lines:
			gem_count += line.size()
			cells_to_destroy.append_array(line)
		_destroy_lines(cells_to_destroy)
		while _apply_gravity():
			if get_tree():
				await get_tree().create_timer(0.2).timeout
	#board is settled
	turn_number += 1
	show_combo_text(gem_count)
	if character:
		if enemy:
			enemy.check_launch_attack()
			character.check_combo({
				"gems": gem_count,
				"lines": line_count,
			})
		elif opponent_board:
			var attack_amount: int = max(ceili(float(gem_count) / 4.0), 1)
			opponent_board.receive_attack(attack_amount)
	_create_cluster()
	_begin_next_cluster()
	if runes_remaining > 0:
		return
	state = State.VICTORY
	_on_game_end()

func get_hash() -> int: #written by Cryptizism
	var state_values: Array = [state, rng.state, turn_number, runes_remaining, incoming_gems_waiting]
	if is_instance_valid(active_cluster):
		state_values.append_array([active_cluster.shape_id, active_cluster.pivot_cell, active_cluster.current_rotation])
	if is_instance_valid(character):
		state_values.append(character.hp)
	for column in grid:
		for cell_object in column:
			if !is_instance_valid(cell_object):
				state_values.append("")
			elif cell_object is Rune:
				state_values.append("R" + cell_object.color)
			elif cell_object is Gem:
				state_values.append("G" + cell_object.color)
			elif cell_object is Brick:
				state_values.append("B")
			else:
				state_values.append("?")
	return hash(state_values)
