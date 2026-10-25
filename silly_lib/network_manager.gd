extends Node

class LobbyData:
	var lobby_id: int
	var version: String
	var name: String = ""
	var members: int
	var max_members: int

class LobbyPlayer:
	var steam_id: int
	var persona_name: String

class PlayerSettings:
	var speed: float = 0.0
	var difficulty: float = 0.0
	var character_id: String = "tippi"
	
	func to_dictionary() -> Dictionary:
		return {
			"speed": speed,
			"difficulty": difficulty,
			"character_id": character_id,
		}
	
	static func from_dictionary(data: Dictionary) -> PlayerSettings:
		var player_settings: PlayerSettings = PlayerSettings.new()
		player_settings.speed = data.get("speed", 0.0)
		player_settings.difficulty = data.get("difficulty", 0.0)
		player_settings.character_id = data.get("character_id", "tippi")
		return player_settings

signal lobby_created()
signal lobby_list_updated(lobbies: Array[LobbyData])
signal lobby_members_updated(members: Array)
signal lobby_left()
signal server_peer_connected()
signal server_peer_disconnected()
signal server_connection_successful
signal server_connection_failed()
signal server_disconnected()
signal player_settings_updated(peer_id: int, player_settings: PlayerSettings)
signal slot_assignments_received(assignments: PackedInt64Array)
signal input_received(sender_id: int, frame: int, packet: Dictionary)
signal seed_received(board_seed: int)
signal level_updated(level_id: String)
signal is_opponent_button_ready(is_ready: bool)
signal opponent_ready()
signal start_match()

const LOBBY_TYPE: Steam.LobbyType = Steam.LobbyType.LOBBY_TYPE_PUBLIC
const MAX_MEMBERS: int = 4
const GAME_CODE: String = "sk_runepool"
const DEBUG_ADDRESS: String = "127.0.0.1"
const DEBUG_PORT: int = 24565
const DEBUG_LOBBY_ID: int = -1 #non-zero so the game treats the session as online

var local_peer_id: int = 1
var peer: SteamMultiplayerPeer
var debug_peer: ENetMultiplayerPeer
var current_lobby_id: int = 0
var lobby_seed: int = 0
var slot_assignments: PackedInt64Array
var is_connected_to_server: bool = false
var debug_max_lag_ms: int = 0
var debug_lag_rng: RandomNumberGenerator = RandomNumberGenerator.new()

func _ready() -> void:
	Steam.initRelayNetworkAccess()
	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	Steam.lobby_match_list.connect(_on_lobby_match_list)
	Steam.join_requested.connect(_on_join_requested)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_server_connected)
	multiplayer.connection_failed.connect(_on_server_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_check_debug_args.call_deferred()

func _process(_delta: float) -> void:
	Steam.run_callbacks()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		leave_lobby()

func is_host() -> bool:
	return multiplayer.is_server()

func host_lobby() -> void:
	leave_lobby()
	Steam.createLobby(LOBBY_TYPE, MAX_MEMBERS)

func refresh_lobby_list() -> void:
	Steam.addRequestLobbyListStringFilter(
		"version",
		ProjectSettings.get_setting("application/config/version"),
		Steam.LOBBY_COMPARISON_EQUAL
	)
	Steam.addRequestLobbyListStringFilter(
		"game",
		GAME_CODE,
		Steam.LOBBY_COMPARISON_EQUAL
	)
	Steam.requestLobbyList()

func join_lobby(_lobby_id: int) -> void:
	leave_lobby()
	Steam.joinLobby(_lobby_id)

func leave_lobby() -> void:
	if current_lobby_id != 0:
		if current_lobby_id != DEBUG_LOBBY_ID:
			Steam.leaveLobby(current_lobby_id)
		current_lobby_id = 0
	multiplayer.multiplayer_peer = null
	if peer:
		peer.close()
	peer = null
	if debug_peer:
		debug_peer.close()
	debug_peer = null
	slot_assignments.clear()
	lobby_left.emit()

#region Debug ENet loopback (run two instances with "-- --host" / "-- --join", optionally "--lag=150")
func _check_debug_args() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--lag="):
			debug_max_lag_ms = arg.trim_prefix("--lag=").to_int()
	if args.has("--host"):
		debug_host()
	elif args.has("--join"):
		debug_join()

func debug_host() -> void:
	leave_lobby()
	debug_peer = ENetMultiplayerPeer.new()
	if debug_peer.create_server(DEBUG_PORT, 1) != OK:
		push_warning("Failed to create debug ENet host.")
		return
	current_lobby_id = DEBUG_LOBBY_ID
	is_connected_to_server = true
	multiplayer.multiplayer_peer = debug_peer
	update_peer_id()
	print("Debug host listening on port %d." % DEBUG_PORT)
	await server_peer_connected
	_start_debug_match()

func debug_join() -> void:
	#host instance may not be up yet, keep retrying until connected
	while true:
		leave_lobby()
		debug_peer = ENetMultiplayerPeer.new()
		if debug_peer.create_client(DEBUG_ADDRESS, DEBUG_PORT) != OK:
			push_warning("Failed to create debug ENet client.")
			return
		current_lobby_id = DEBUG_LOBBY_ID
		multiplayer.multiplayer_peer = debug_peer
		while debug_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
			await get_tree().process_frame
		if debug_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			break
		await get_tree().create_timer(0.5).timeout
	update_peer_id()
	_start_debug_match()

func _start_debug_match() -> void:
	Global.player_count = 2
	Transition.change_scene("res://scenes/game_room.tscn")
#endregion

func _on_lobby_created(_result: int, _lobby_id: int) -> void:
	if _result != Steam.RESULT_OK:
		push_warning("Failed to create Steam lobby.")
		return
	current_lobby_id = _lobby_id
	_set_lobby_data(_lobby_id)
	peer = SteamMultiplayerPeer.new()
	peer.server_relay = true
	if peer.create_host() != OK:
		leave_lobby()
		push_warning("Failed to create Steam host.")
		return
	Steam.setLobbyJoinable(_lobby_id, true)
	is_connected_to_server = true
	multiplayer.multiplayer_peer = peer
	update_peer_id()
	lobby_created.emit()
	_update_lobby_members()

func _on_lobby_match_list(_lobbies: Array) -> void:
	var results: Array[LobbyData] = []
	for lobby_id in _lobbies:
		var version: String = Steam.getLobbyData(lobby_id, "version")
		if version != ProjectSettings.get_setting("application/config/version"):
			continue
		var lobby: LobbyData = LobbyData.new()
		lobby.lobby_id = lobby_id
		lobby.name = Steam.getLobbyData(lobby_id, "name")
		lobby.version = Steam.getLobbyData(lobby_id, "version")
		lobby.members = Steam.getNumLobbyMembers(lobby_id)
		lobby.max_members = Steam.getLobbyMemberLimit(lobby_id)
		results.append(lobby)
	lobby_list_updated.emit(results)

func _on_lobby_joined(_lobby_id: int, _permissions: int, _locked: bool, _response: int) -> void:
	if _response != Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		push_warning("Failed to join lobby %d" % _response)
		server_connection_failed.emit()
		return
	var lobby_owner_id: int = Steam.getLobbyOwner(_lobby_id)
	if lobby_owner_id == Steam.getSteamID():
		return
	peer = SteamMultiplayerPeer.new()
	peer.server_relay = true
	if peer.create_client(lobby_owner_id) != OK:
		push_warning("Failed to create Steam client.")
		return
	current_lobby_id = _lobby_id
	multiplayer.multiplayer_peer = peer
	update_peer_id()
	_update_lobby_members()

func _on_join_requested(_lobby_id: int, _peer_id: int) -> void:
	Steam.joinLobby(_lobby_id)

func _update_lobby_members() -> void:
	var members: Array[LobbyPlayer] = get_lobby_members()
	lobby_members_updated.emit(members)

func update_peer_id() -> void:
	if multiplayer and multiplayer.has_multiplayer_peer():
		local_peer_id = multiplayer.get_unique_id()

func _on_peer_connected(id: int) -> void:
	print("Peer %d connected." % id)
	server_peer_connected.emit()
	_update_lobby_members()

func _on_peer_disconnected(id: int) -> void:
	print("Peer %d disconnected." % id)
	server_peer_disconnected.emit()
	_update_lobby_members()

func _on_server_connected() -> void:
	print("Connection successful.")
	is_connected_to_server = true
	server_connection_successful.emit()

func _on_server_connection_failed() -> void:
	print("Connection failed.")
	is_connected_to_server = false
	server_connection_failed.emit()

func _on_server_disconnected() -> void:
	print("Server disconnected.")
	is_connected_to_server = false
	server_disconnected.emit()

func wait_for_server_connection() -> void:
	if is_connected_to_server:
		return
	await server_connection_successful

func _set_lobby_data(_lobby_id: int) -> void:
	Steam.setLobbyData(_lobby_id, "name", "%s" % Steam.getPersonaName())
	Steam.setLobbyData(_lobby_id, "game", GAME_CODE)
	Steam.setLobbyData(_lobby_id, "version", ProjectSettings.get_setting("application/config/version"))
	Steam.setLobbyData(_lobby_id, "has_password", "0")

func get_lobby_size() -> int:
	return Steam.getNumLobbyMembers(NetworkManager.current_lobby_id)

func get_lobby_members() -> Array[LobbyPlayer]:
	var members: Array[LobbyPlayer] = []
	for i in range(Steam.getNumLobbyMembers(current_lobby_id)):
		var steam_id: int = Steam.getLobbyMemberByIndex(current_lobby_id, i)
		var player := LobbyPlayer.new()
		player.steam_id = steam_id
		player.persona_name = Steam.getFriendPersonaName(steam_id)
		members.append(player)
	return members

func get_steam_id_from_peer_id(peer_id: int) -> int:
	var steam_peer: SteamMultiplayerPeer = multiplayer.multiplayer_peer as SteamMultiplayerPeer
	if !steam_peer:
		return -1
	return steam_peer.get_steam_id_for_peer_id(peer_id)

func send_slot_assignments(assignments: PackedInt64Array) -> void:
	receive_slot_assignments.rpc(assignments)

@rpc("any_peer", "reliable")
func receive_slot_assignments(assignments: PackedInt64Array) -> void:
	slot_assignments = assignments
	slot_assignments_received.emit(assignments)

func send_input(peer_id: int, frame: int, packet: Dictionary) -> void:
	if debug_max_lag_ms > 0:
		await get_tree().create_timer(debug_lag_rng.randf_range(0, debug_max_lag_ms) / 1000.0).timeout
	receive_input.rpc_id(peer_id, frame, packet)

@rpc("any_peer", "reliable")
func receive_input(frame: int, packet: Dictionary) -> void:
	var sender_id: int = multiplayer.get_remote_sender_id()
	if multiplayer.get_unique_id() == sender_id:
		return
	input_received.emit(sender_id, frame, packet)

func send_seed(generated_seed: int) -> void:
	lobby_seed = generated_seed
	receive_seed.rpc(generated_seed)

@rpc("any_peer", "reliable")
func receive_seed(generated_seed: int) -> void:
	lobby_seed = generated_seed
	seed_received.emit(generated_seed)

func send_opponent_ready() -> void:
	receive_opponent_ready.rpc()

@rpc("any_peer", "reliable")
func receive_opponent_ready() -> void:
	opponent_ready.emit()

func send_start_match() -> void:
	receive_start_match.rpc()

@rpc("any_peer", "reliable")
func receive_start_match() -> void:
	start_match.emit()

func send_player_settings(player_settings: PlayerSettings) -> void:
	receive_player_settings.rpc_id(0, player_settings.to_dictionary()) #0 = all except self

@rpc("any_peer", "reliable")
func receive_player_settings(data: Dictionary) -> void:
	player_settings_updated.emit(multiplayer.get_remote_sender_id(), PlayerSettings.from_dictionary(data))

func send_level_id(level_id: String) -> void:
	receive_level_id.rpc_id(0, level_id)

@rpc("any_peer", "reliable")
func receive_level_id(level_id: String) -> void:
	level_updated.emit(level_id)

func send_opponent_ready_button(is_ready: bool) -> void:
	receive_opponent_ready_button.rpc_id(0, is_ready)

@rpc("any_peer", "reliable")
func receive_opponent_ready_button(is_ready: bool) -> void:
	is_opponent_button_ready.emit(is_ready)
