extends RefCounted
class_name Player

var slot_number: int
var peer_id: int
var input: PlayerInput
var sim_input: PlayerInput = PlayerInput.new()
var board: Board

func _init(_slot_number: int) -> void:
	slot_number = _slot_number
	input = PlayerInput.new()

func is_local() -> bool:
	if NetworkManager.current_lobby_id == 0:
		return true
	return peer_id == NetworkManager.local_peer_id
