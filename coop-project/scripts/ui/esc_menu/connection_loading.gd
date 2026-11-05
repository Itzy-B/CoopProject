extends CanvasLayer

@export var spawn_timeout_seconds: float = 15.0

@onready var overlay: Control = $Overlay
@onready var status_label: Label = $Overlay/Center/Message/Status

var _loading: bool = false
var _animation_time: float = 0.0
var _spawn_deadline: int = 0
var _waiting_lobby: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("connection_loading_ui")
	overlay.hide()
	LobbyManager.invitations_changed.connect(_on_party_operation_changed)
	LobbyManager.party_changed.connect(_on_party_operation_changed)
	LobbyManager.operation_failed.connect(_on_operation_failed)
	LobbyManager.removed_from_party.connect(_on_operation_failed)
	NetworkManager.session_ready.connect(_on_party_operation_changed)
	NetworkManager.returned_to_solo.connect(_on_party_operation_changed)
	_on_party_operation_changed()


func is_loading() -> bool:
	return _loading


func _on_party_operation_changed() -> void:
	if _should_wait_for_join():
		_begin_loading()


func _begin_loading() -> void:
	if _loading:
		return
	_loading = true
	_animation_time = 0.0
	_spawn_deadline = 0
	_waiting_lobby = LobbyManager.lobby_id
	overlay.show()
	_set_menu_open(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_update_status()


func _should_wait_for_join() -> bool:
	if LobbyManager.is_joining_party() or NetworkManager.is_connecting():
		return true
	# Also recover if this UI entered the tree after the join signals fired.
	if (
		LobbyManager.lobby_id != 0
		and LobbyManager.owner_id != 0
		and LobbyManager.owner_id != SteamManager.my_steam_id
	):
		return not _gameplay_ready_for_current_party()
	return false


func _process(delta: float) -> void:
	# Signals show it immediately. This guard covers missed signals and rejoins.
	if _should_wait_for_join():
		_begin_loading()
	if not _loading:
		return

	_animation_time += delta
	_update_status()

	if _waiting_lobby != LobbyManager.lobby_id:
		_waiting_lobby = LobbyManager.lobby_id
		_spawn_deadline = 0

	# The previous session/player may still exist while Steam changes lobbies.
	# Never let that old character complete a different join operation.
	if LobbyManager.is_joining_party():
		_spawn_deadline = 0
		return

	if _session_matches_current_party():
		if _local_network_player_is_ready():
			_finish(false)
			return
		if _spawn_deadline == 0:
			_spawn_deadline = Time.get_ticks_msec() + int(
				maxf(spawn_timeout_seconds, 1.0) * 1000.0
			)
		elif Time.get_ticks_msec() >= _spawn_deadline:
			if not LobbyManager.is_busy():
				LobbyManager.leave_party()
			LobbyManager.operation_failed.emit("Your player could not be spawned. Please join again.")
		return

	_spawn_deadline = 0
	if LobbyManager.lobby_id == 0 and not NetworkManager.is_connecting():
		_finish(true)


func _session_matches_current_party() -> bool:
	return (
		LobbyManager.lobby_id != 0
		and not LobbyManager.is_joining_party()
		and LobbyManager.is_in_party(SteamManager.my_steam_id)
		and NetworkManager.get_session_lobby_id() == LobbyManager.lobby_id
		and NetworkManager.is_session_connected()
	)


func _gameplay_ready_for_current_party() -> bool:
	return _session_matches_current_party() and _local_network_player_is_ready()


func _local_network_player_is_ready() -> bool:
	for node in get_tree().get_nodes_in_group("local_session_player"):
		var player: SessionPlayerCharacter = node as SessionPlayerCharacter
		if (
			player != null
			and player.networked
			and player.is_local_player()
			and player.controlling_peer_id == multiplayer.get_unique_id()
		):
			return true
	return false


func _update_status() -> void:
	var message: String = "Preparing connection"
	if LobbyManager.is_searching_party_code():
		message = "Finding party"
	elif LobbyManager.is_joining_party():
		message = "Joining party"
	elif NetworkManager.state == NetworkManager.SessionState.WAITING_FOR_HOST:
		message = "Waiting for host"
	elif NetworkManager.state == NetworkManager.SessionState.CONNECTING:
		message = "Connecting to host"
	elif _session_matches_current_party():
		message = "Spawning your player"
	elif LobbyManager.lobby_id != 0:
		message = "Waiting for party admission"
	status_label.text = message + ".".repeat(int(_animation_time * 2.0) % 4)


func _on_operation_failed(_message: String) -> void:
	if _loading:
		_finish(true)


func _finish(open_menu: bool) -> void:
	_loading = false
	_spawn_deadline = 0
	_waiting_lobby = 0
	overlay.hide()
	_set_menu_open(open_menu)


func _set_menu_open(value: bool) -> void:
	var current_scene: Node = get_tree().current_scene
	if current_scene == null:
		return
	var menu: Node = current_scene.get_node_or_null("CanvasLayer/EscMenu")
	if menu != null and menu.has_method("set_menu_open"):
		menu.call("set_menu_open", value)
