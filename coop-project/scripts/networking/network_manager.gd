extends Node

signal session_ready
signal returned_to_solo
signal player_connected(peer_id: int)
signal player_disconnected(peer_id: int)

enum SessionState {
	SOLO,
	WAITING_FOR_HOST,
	CONNECTING,
	HOSTING,
	CONNECTED
}

const VIRTUAL_PORT: int = 0
const HOST_READY_KEY: String = "network_host_steam_id"
const CONNECTION_TIMEOUT_MS: int = 20000
const CHECK_INTERVAL: float = 0.25

var state: SessionState = SessionState.SOLO

var _peer: SteamMultiplayerPeer
var _session_lobby_id: int = 0
var _host_steam_id: int = 0
var _deadline: int = 0
var _check_elapsed: float = 0.0

var _failed_lobby_id: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _process(delta: float) -> void:
	_check_elapsed += delta

	if _check_elapsed < CHECK_INTERVAL:
		return

	_check_elapsed = 0.0
	_update_session()


func is_hosting() -> bool:
	return state == SessionState.HOSTING


func is_session_connected() -> bool:
	if state != SessionState.HOSTING and state != SessionState.CONNECTED:
		return false
	if _peer == null or multiplayer.multiplayer_peer != _peer:
		return false
	return _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func get_session_lobby_id() -> int:
	# Gameplay session identity, which can briefly differ from Steam party state.
	return _session_lobby_id


func is_connecting() -> bool:
	return (
		state == SessionState.WAITING_FOR_HOST
		or state == SessionState.CONNECTING
	)


func get_local_peer_id() -> int:
	return multiplayer.get_unique_id()


func _update_session() -> void:
	var current_lobby: int = LobbyManager.lobby_id

	# Leaving or switching lobbies closes the previous connection.
	if (
		_session_lobby_id != 0
		and current_lobby != _session_lobby_id
	):
		_close_session()

	if current_lobby == 0:
		_failed_lobby_id = 0
		return

	# A failed lobby must not automatically restart the connection.
	if current_lobby == _failed_lobby_id:
		return

	# Don't treat a temporary Steam service outage as a
	# gameplay disconnect. The peer reports connection loss.
	if not SteamManager.is_online():
		if (
			is_connecting()
			and Time.get_ticks_msec() >= _deadline
		):
			_fail_session("Could not connect to the party.")
		return

	if _session_lobby_id == 0:
		# LobbyManager must finish admitting us first.
		if LobbyManager.is_busy():
			return

		if not LobbyManager.is_in_party(SteamManager.my_steam_id):
			return

		_begin_session(current_lobby)
		return

	if is_connecting() and Time.get_ticks_msec() >= _deadline:
		_fail_session("Connecting to the party timed out.")
		return

	# Steam changing lobby owner does not migrate the game host.
	if (
		LobbyManager.owner_id != 0
		and LobbyManager.owner_id != _host_steam_id
	):
		_fail_session("The host left. You are now playing solo.")
		return

	if state == SessionState.WAITING_FOR_HOST:
		_try_connect_to_host()


func _begin_session(target_lobby: int) -> void:
	_session_lobby_id = target_lobby
	_host_steam_id = LobbyManager.owner_id
	_deadline = Time.get_ticks_msec() + CONNECTION_TIMEOUT_MS

	if _host_steam_id <= 0:
		_fail_session("Could not identify the party host.")
		return

	if _host_steam_id == SteamManager.my_steam_id:
		_start_host()
	else:
		state = SessionState.WAITING_FOR_HOST
		print("NETWORK | Waiting for the host's gameplay connection.")
		_try_connect_to_host()


func _start_host() -> void:
	_peer = SteamMultiplayerPeer.new()
	var result: int = _peer.create_host(VIRTUAL_PORT)

	if result != OK:
		_fail_session(
			"Could not start gameplay hosting: %s" % error_string(result)
		)
		return

	_configure_gameplay_peer()
	multiplayer.multiplayer_peer = _peer
	state = SessionState.HOSTING
	_deadline = 0

	# Clients wait for this metadata before connecting.
	if not Steam.setLobbyData(
		_session_lobby_id,
		HOST_READY_KEY,
		str(SteamManager.my_steam_id)
	):
		_fail_session("Steam could not publish the gameplay host.")
		return

	print(
		"NETWORK | Hosting gameplay. Peer ID: ",
		multiplayer.get_unique_id()
	)

	session_ready.emit()


func _try_connect_to_host() -> void:
	if state != SessionState.WAITING_FOR_HOST:
		return

	var published_host: int = Steam.getLobbyData(
		_session_lobby_id,
		HOST_READY_KEY
	).to_int()

	if published_host != _host_steam_id:
		return

	_peer = SteamMultiplayerPeer.new()

	var result: int = _peer.create_client(
		_host_steam_id,
		VIRTUAL_PORT
	)

	if result != OK:
		_fail_session(
			"Could not start the gameplay connection: %s"
			% error_string(result)
		)
		return

	_configure_gameplay_peer()
	state = SessionState.CONNECTING
	multiplayer.multiplayer_peer = _peer

	print(
		"NETWORK [", Time.get_ticks_msec(),
		" ms] | Starting connection to Steam host: ",
		_host_steam_id
	)


func _configure_gameplay_peer() -> void:
	# Apply identically on host and client, after creation and before assignment.
	if _peer.has_method("set_no_nagle"):
		_peer.call("set_no_nagle", true)
		if _peer.has_method("get_no_nagle"):
			print("NETWORK | no_nagle=", _peer.call("get_no_nagle"))
	else:
		push_warning("Steam peer does not expose set_no_nagle.")


func _on_connected_to_server() -> void:
	if state != SessionState.CONNECTING:
		return

	state = SessionState.CONNECTED
	_deadline = 0

	print(
		"NETWORK [", Time.get_ticks_msec(),
		" ms] | Connected to gameplay host. My peer ID: ",
		multiplayer.get_unique_id()
	)

	session_ready.emit()


func _on_connection_failed() -> void:
	if state == SessionState.SOLO:
		return

	_fail_session("Could not connect to the party's gameplay host.")


func _on_server_disconnected() -> void:
	if state == SessionState.SOLO:
		return

	_fail_session("The gameplay host disconnected. You are now playing solo.")


func _on_peer_connected(peer_id: int) -> void:
	print("NETWORK | Peer connected: ", peer_id)
	player_connected.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	print("NETWORK | Peer disconnected: ", peer_id)
	player_disconnected.emit(peer_id)


func _fail_session(message: String) -> void:
	_failed_lobby_id = _session_lobby_id
	_close_session()

	# Leave the Steam party too, so the UI matches solo gameplay.
	if LobbyManager.lobby_id != 0 and not LobbyManager.is_busy():
		LobbyManager.leave_party()

	# SteamManager already forwards this signal to the menu's error UI.
	LobbyManager.operation_failed.emit(message)
	push_warning(message)


func _close_session() -> void:
	var had_session: bool = (
		_session_lobby_id != 0
		or state != SessionState.SOLO
	)

	var old_peer: SteamMultiplayerPeer = _peer

	# Clear state before closing to avoid processing stale callbacks.
	state = SessionState.SOLO
	_peer = null
	_session_lobby_id = 0
	_host_steam_id = 0
	_deadline = 0

	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

	if old_peer != null:
		old_peer.close()

	if had_session:
		print("NETWORK | Returned to solo.")
		returned_to_solo.emit()


func _exit_tree() -> void:
	if _peer != null:
		_peer.close()
