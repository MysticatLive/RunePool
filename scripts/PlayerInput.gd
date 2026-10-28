class_name PlayerInput

var move_up: bool = false
var move_down: bool = false
var move_left: bool = false
var move_right: bool = false
var rotate_left: bool = false
var rotate_right: bool = false
var accept: bool = false
var back: bool = false

func clear_one_shots() -> void:
	rotate_left = false
	rotate_right = false
	accept = false
	back = false

func update_local(player_id: int) -> void:
	if ![0, 1].has(player_id):
		return
	move_up = Input.is_action_pressed("move_up_" + str(player_id))
	move_down = Input.is_action_pressed("move_down_" + str(player_id))
	move_left = Input.is_action_pressed("move_left_" + str(player_id))
	move_right = Input.is_action_pressed("move_right_" + str(player_id))
	rotate_left = rotate_left or Input.is_action_just_pressed("rotate_left_" + str(player_id))
	rotate_right = rotate_right or Input.is_action_just_pressed("rotate_right_" + str(player_id))
	accept = accept or Input.is_action_just_pressed("accept_" + str(player_id))
	back = back or Input.is_action_just_pressed("back_" + str(player_id))

func update_network(packet: Dictionary) -> void:
	move_up = packet.get("move_up", false)
	move_down = packet.get("move_down", false)
	move_left = packet.get("move_left", false)
	move_right = packet.get("move_right", false)
	rotate_left = packet.get("rotate_left", false)
	rotate_right = packet.get("rotate_right", false)
	accept = packet.get("accept", false)
	back = packet.get("back", false)

func get_neutral_input() -> Dictionary:
	return {
		"move_up": false,
		"move_down": false,
		"move_left": false,
		"move_right": false,
		"rotate_left": false,
		"rotate_right": false,
		"accept": false,
		"back": false,
	}

func clear() -> void:
	move_up = false
	move_down = false
	move_left = false
	move_right = false
	rotate_left = false
	rotate_right = false
	accept = false
	back = false

func to_packet() -> Dictionary:
	return {
		"move_up": move_up,
		"move_down": move_down,
		"move_left": move_left,
		"move_right": move_right,
		"rotate_left": rotate_left,
		"rotate_right": rotate_right,
		"accept": accept,
		"back": back,
	}
