extends Node3D

@export var player_scene: PackedScene

@onready var players: Node3D = $Players
@onready var spawner: MultiplayerSpawner = $PlayerSpawner

@onready var spawn_points: Array[Marker3D] = [
	$SpawnMarker3D1,
	$SpawnMarker3D2,
	$SpawnMarker3D3,
	$SpawnMarker3D4
]

var _spawn_slots: Dictionary = {}
var _request_elapsed: float = 0.0


func _ready() -> void:
	if player_scene == null:
		push_error("Test: assign Player Scene.")
		return

	spawner.spawn_path = spawner.get_path_to(players)
	spawner.spawn_limit = LobbyManager.MAX_PLAYERS
	spawner.clear_spawnable_scenes()
	spawner.spawn_function = _create_network_player

	NetworkManager.session_ready.connect(_on_session_ready)
	NetworkManager.returned_to_solo.connect(_on_returned_to_solo)
	NetworkManager.player_disconnected.connect(_on_player_disconnected)

	# Main may load this scene before or after a connection starts.
	if NetworkManager.is_session_connected():
		_on_session_ready()
	else:
		_spawn_solo_player(_spawn_transform(0))


func _process(delta: float) -> void:
	if player_scene == null:
		return

	if not NetworkManager.is_session_connected():
		return

	if NetworkManager.is_hosting():
		return

	# Retry readiness until our character arrives.
	var local_name: String = str(multiplayer.get_unique_id())

	if players.has_node(NodePath(local_name)):
		_request_elapsed = 0.0
		return

	_request_elapsed += delta

	if _request_elapsed >= 1.0:
		_request_elapsed = 0.0
		_request_player_spawn.rpc_id(1)


func _on_session_ready() -> void:
	var previous_transform: Transform3D = _local_player_transform()

	_clear_players()
	_spawn_slots.clear()
	_request_elapsed = 0.0

	if NetworkManager.is_hosting():
		_spawn_slots[1] = 0
		_spawn_network_player(1, previous_transform)
	else:
		# Defer until this callback has finished clearing the solo player.
		call_deferred("_announce_ready")


func _announce_ready() -> void:
	if (
		NetworkManager.is_session_connected()
		and not NetworkManager.is_hosting()
	):
		_request_player_spawn.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _request_player_spawn() -> void:
	if not NetworkManager.is_hosting():
		return

	var sender_id: int = multiplayer.get_remote_sender_id()

	if sender_id <= 1 or not multiplayer.get_peers().has(sender_id):
		return

	if players.has_node(NodePath(str(sender_id))):
		return

	# Verify the transport identity against admitted Steam party members.
	var steam_id: int = _steam_id_for_peer(sender_id)

	if steam_id <= 0 or not LobbyManager.is_in_party(steam_id):
		return

	var slot: int = _find_free_spawn_slot()

	if slot == -1:
		return

	_spawn_slots[sender_id] = slot
	_spawn_network_player(sender_id, _spawn_transform(slot))


func _steam_id_for_peer(peer_id: int) -> int:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer

	if peer == null:
		return 0

	if peer.has_method("get_steam_id_for_peer_id"):
		return int(peer.call("get_steam_id_for_peer_id", peer_id))

	if peer.has_method("get_steam64_from_peer_id"):
		return int(peer.call("get_steam64_from_peer_id", peer_id))

	push_error("The installed Steam peer has no supported Steam ID lookup.")
	return 0


func _spawn_network_player(
	peer_id: int,
	spawn_transform: Transform3D
) -> void:
	spawner.spawn({
		"peer_id": peer_id,
		"transform": spawn_transform
	})


# MultiplayerSpawner calls this on every computer.
# Return the character without adding it to the tree.
func _create_network_player(data: Variant) -> Node:
	var spawn_data: Dictionary = data
	var peer_id: int = int(spawn_data["peer_id"])

	var player: SessionPlayerCharacter = (
		player_scene.instantiate() as SessionPlayerCharacter
	)

	if player == null:
		push_error("Player Scene must use the updated player.gd.")
		return null

	player.name = str(peer_id)
	player.transform = spawn_data["transform"]
	if not player.prepare(peer_id, true):
		player.free()
		return null

	return player


func _spawn_solo_player(spawn_transform: Transform3D) -> void:
	var player: SessionPlayerCharacter = (
		player_scene.instantiate() as SessionPlayerCharacter
	)

	if player == null:
		push_error("Player Scene must use the updated player.gd.")
		return

	player.name = "SoloPlayer"
	player.transform = spawn_transform
	if not player.prepare(1, false):
		player.free()
		return
	players.add_child(player)


func _on_player_disconnected(peer_id: int) -> void:
	if not NetworkManager.is_hosting():
		return

	_spawn_slots.erase(peer_id)

	var player: Node = players.get_node_or_null(
		NodePath(str(peer_id))
	)

	if player != null:
		# Removing the host's tracked character replicates its removal.
		players.remove_child(player)
		player.queue_free()


func _on_returned_to_solo() -> void:
	var previous_transform: Transform3D = _local_player_transform()

	_clear_players()
	_spawn_slots.clear()
	_request_elapsed = 0.0
	_spawn_solo_player(previous_transform)


func _local_player_transform() -> Transform3D:
	# The MultiplayerAPI may already have reset its ID to 1. Use the character's
	# retained local identity, otherwise a leaving client can select the host.
	for child in players.get_children():
		var player: SessionPlayerCharacter = child as SessionPlayerCharacter
		if player != null and player.is_local_player():
			return player.transform
	return _spawn_transform(0)


func _spawn_transform(index: int) -> Transform3D:
	return (
		players.global_transform.affine_inverse()
		* spawn_points[index].global_transform
	)


func _find_free_spawn_slot() -> int:
	for index in range(spawn_points.size()):
		if not _spawn_slots.values().has(index):
			return index

	return -1


func _clear_players() -> void:
	for child in players.get_children():
		players.remove_child(child)
		child.queue_free()
