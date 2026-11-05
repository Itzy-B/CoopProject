extends Node

signal friends_changed
signal my_profile_changed
signal overlay_changed(active: bool)

signal online_state_changed
signal steam_stopping
signal error_changed(message: String)

enum OnlineState {
	OFFLINE,
	STARTING,
	CONNECTING,
	ONLINE,
	STOPPING
}

const REFRESH_INTERVAL: float = 2.0
const CONNECTION_CHECK_INTERVAL: float = 1.0
const STARTUP_TIMEOUT_MS: int = 20000

const LOBBY_REQUEST_TIMEOUT_MS: int = 8000
const LOBBY_DATA_MAX_AGE_MS: int = 12000
const AVATAR_REQUEST_INTERVAL_MS: int = 10000
const AVATAR_CHANGED_FLAG: int = 64

const STATUS_NAMES: Dictionary = {
	0: "Offline",
	1: "Online",
	2: "Busy",
	3: "Away",
	4: "Snooze"
}

# Change this to your game's AppID.
# 480 is Steam's development test AppID.
@export var app_id: int = 480

var online_state: OnlineState = OnlineState.OFFLINE
var last_error: String = ""

var friends: Dictionary = {}
var party_profiles: Dictionary = {}

var overlay_active: bool = false
var my_steam_id: int = 0
var my_name: String = ""
var my_avatar: Texture2D

var _steam_initialized: bool = false
var _friends_menu_open: bool = false

var _refresh_elapsed: float = 0.0
var _connection_elapsed: float = 0.0
var _startup_deadline: int = 0

var _friend_refresh_queued: bool = false
var _session_generation: int = 0
var _observed_lobby_id: int = 0

var _requested_profiles: Dictionary = {}
var _avatar_requests: Dictionary = {}

const INITIALIZATION_RETRY_INTERVAL: float = 15.0
var _initialization_retry_elapsed: float = 0.0

# Lobby ID -> request and result information.
var _friend_lobby_checks: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	# These connections do not initialize Steam.
	Steam.persona_state_change.connect(_on_persona_state_change)
	Steam.avatar_loaded.connect(_on_avatar_loaded)
	Steam.overlay_toggled.connect(_on_overlay_toggled)
	Steam.lobby_data_update.connect(_on_friend_lobby_data_update)

	call_deferred("_connect_lobby_signals")
	call_deferred("start_online")

	# Stay offline until the user confirms Host Lobby.


func _connect_lobby_signals() -> void:
	LobbyManager.party_changed.connect(_on_party_changed)
	LobbyManager.invitations_changed.connect(_queue_friend_refresh)
	LobbyManager.privacy_changed.connect(_queue_friend_refresh)
	LobbyManager.operation_failed.connect(_on_lobby_operation_failed)
	LobbyManager.removed_from_party.connect(_on_removed_from_party)


func _process(delta: float) -> void:
	if not _steam_initialized:
		_initialization_retry_elapsed += delta

		if _initialization_retry_elapsed >= INITIALIZATION_RETRY_INTERVAL:
			_initialization_retry_elapsed = 0.0
			start_online()

		return

	Steam.run_callbacks()

	if not _steam_initialized:
		return

	_connection_elapsed += delta

	if _connection_elapsed >= CONNECTION_CHECK_INTERVAL:
		_connection_elapsed = 0.0
		_update_steam_connection()

	if not is_online() or not _friends_menu_open:
		return

	_refresh_elapsed += delta

	if _refresh_elapsed >= REFRESH_INTERVAL:
		_refresh_elapsed = 0.0
		refresh_friends()


func is_steam_initialized() -> bool:
	return _steam_initialized


func is_online() -> bool:
	return (
		_steam_initialized
		and online_state == OnlineState.ONLINE
	)


func is_busy() -> bool:
	return (
		online_state == OnlineState.STARTING
		or online_state == OnlineState.STOPPING
		or LobbyManager.is_busy()
	)


func start_online() -> bool:
	# Already initialized: check connectivity instead of initializing again.
	if _steam_initialized:
		_update_steam_connection()
		return is_online()

	if online_state != OnlineState.OFFLINE:
		return false

	if app_id <= 0:
		_set_error("Assign your Steam AppID in SteamManager.")
		return false

	_initialization_retry_elapsed = 0.0
	_session_generation += 1

	_set_online_state(OnlineState.STARTING)

	var result: Dictionary = _initialize_steam()

	if int(result.get("status", -1)) != 0:
		_set_online_state(OnlineState.OFFLINE)
		_set_error("No access to online services.")
		return false

	_steam_initialized = true
	_connection_elapsed = 0.0
	_refresh_elapsed = 0.0

	_set_online_state(OnlineState.CONNECTING)
	_update_steam_connection()

	# Initializing Steam does not create a lobby.
	return is_online()

func _update_steam_connection() -> void:
	if not _steam_initialized:
		return

	if not Steam.loggedOn():
		if online_state != OnlineState.CONNECTING:
			_friend_lobby_checks.clear()
			_set_online_state(OnlineState.CONNECTING)
			friends_changed.emit()

		_set_error("No access to online services.")
		return

	if online_state == OnlineState.ONLINE:
		return

	if not LobbyManager.activate_online():
		return

	clear_error()
	_refresh_my_profile()

	_set_online_state(OnlineState.ONLINE)
	_queue_friend_refresh()

func _initialize_steam() -> Dictionary:
	# GodotSteam versions differ in initialization argument order.
	# Inspect the installed method instead of guessing.
	for method_info in Steam.get_method_list():
		if str(method_info.get("name", "")) != "steamInitEx":
			continue

		var arguments: Array = method_info.get("args", [])

		if arguments.size() < 2:
			return {
				"status": -1,
				"verbal": "This GodotSteam initialization signature is unsupported."
			}

		var first_argument: Dictionary = arguments[0]
		var first_type: int = int(first_argument.get("type", TYPE_NIL))

		if first_type == TYPE_BOOL:
			# Older versions: embed_callbacks, app_id.
			return Steam.call("steamInitEx", false, app_id)

		if first_type == TYPE_INT:
			# Newer versions: app_id, embed_callbacks.
			return Steam.call("steamInitEx", app_id, false)

		return {
			"status": -1,
			"verbal": "Could not identify the Steam initialization arguments."
		}

	return {
		"status": -1,
		"verbal": "GodotSteam does not expose steamInitEx."
	}


func stop_online() -> bool:
	if online_state == OnlineState.OFFLINE:
		return true

	if is_busy():
		_set_error("Wait until the current party operation finishes.")
		return false

	_shutdown_online()
	return true


func _shutdown_online(message: String = "") -> void:
	_set_online_state(OnlineState.STOPPING)

	# Invalidate deferred work from this online session.
	_session_generation += 1
	_friend_refresh_queued = false

	if _steam_initialized:
		# Voice must release the microphone before the Steam API shuts down.
		steam_stopping.emit()
		# Normal shutdown leaves the lobby before closing the API.
		# A timed-out operation may still be pending; shutting down
		# the API ends this client's session in that case.
		if not LobbyManager.is_busy():
			LobbyManager.deactivate_online()

		_steam_initialized = false
		Steam.steamShutdown()

	# This reset performs no Steam calls.
	LobbyManager.reset_online_state()

	_clear_online_cache()
	_set_online_state(OnlineState.OFFLINE)

	if not message.is_empty():
		_set_error(message)


func _clear_online_cache() -> void:
	friends.clear()
	party_profiles.clear()
	_requested_profiles.clear()
	_avatar_requests.clear()
	_friend_lobby_checks.clear()

	my_steam_id = 0
	my_name = ""
	my_avatar = null

	overlay_active = false
	_observed_lobby_id = 0
	_startup_deadline = 0
	_refresh_elapsed = 0.0
	_connection_elapsed = 0.0

	friends_changed.emit()
	my_profile_changed.emit()
	overlay_changed.emit(false)


func _set_online_state(value: OnlineState) -> void:
	if online_state == value:
		return

	online_state = value
	online_state_changed.emit()


func clear_error() -> void:
	_set_error("")


func _set_error(message: String) -> void:
	if last_error == message:
		return

	last_error = message
	error_changed.emit(message)


func _on_lobby_operation_failed(message: String) -> void:
	_set_error(message)

	if online_state == OnlineState.STARTING:
		var generation: int = _session_generation
		call_deferred("_finish_failed_startup", generation, message)


func _finish_failed_startup(
	generation: int,
	message: String
) -> void:
	if generation != _session_generation:
		return

	if online_state == OnlineState.STARTING:
		_shutdown_online(message)


func _on_removed_from_party(reason: String) -> void:
	_set_error(reason)
	_queue_friend_refresh()


func _on_party_changed() -> void:
	var previous_lobby: int = _observed_lobby_id
	var current_lobby: int = LobbyManager.lobby_id

	_observed_lobby_id = current_lobby

	if previous_lobby != current_lobby:
		if previous_lobby != 0:
			_friend_lobby_checks.erase(previous_lobby)

		if current_lobby != 0:
			_friend_lobby_checks.erase(current_lobby)

	if (
		online_state == OnlineState.STARTING
		and current_lobby != 0
		and LobbyManager.is_owner()
		and LobbyManager.is_in_party(my_steam_id)
	):
		_startup_deadline = 0
		_set_online_state(OnlineState.ONLINE)

	# The previous lobby is now external after leaving.
	# Request its data immediately when the list is visible.
	if (
		is_online()
		and _friends_menu_open
		and previous_lobby != 0
		and previous_lobby != current_lobby
	):
		_request_friend_lobby(previous_lobby)

	if is_online():
		friends_changed.emit()
		_queue_friend_refresh()


func set_friends_menu_open(value: bool) -> void:
	if _friends_menu_open == value:
		return

	_friends_menu_open = value
	_refresh_elapsed = 0.0

	if _friends_menu_open and is_online():
		_queue_friend_refresh()


func _queue_friend_refresh() -> void:
	if not is_online() or not _friends_menu_open:
		return

	if _friend_refresh_queued:
		return

	_friend_refresh_queued = true

	call_deferred(
		"_run_queued_friend_refresh",
		_session_generation
	)


func _run_queued_friend_refresh(generation: int) -> void:
	if generation != _session_generation:
		return

	_friend_refresh_queued = false

	if not is_online() or not _friends_menu_open:
		return

	_refresh_elapsed = 0.0
	refresh_friends()


func _create_profile(steam_id: int) -> Dictionary:
	return {
		"steam_id": steam_id,
		"display_name": "",
		"state": -1,
		"status": "Unknown",
		"is_online": false,
		"is_in_game": false,
		"avatar": null,
		"lobby_id": 0
	}


func get_player_profile(steam_id: int) -> Dictionary:
	if steam_id <= 0:
		return {}

	if steam_id == my_steam_id:
		return {
			"steam_id": my_steam_id,
			"display_name": my_name,
			"state": 1,
			"status": "In Game",
			"is_online": is_online(),
			"is_in_game": true,
			"avatar": my_avatar,
			"lobby_id": LobbyManager.lobby_id
		}

	if friends.has(steam_id):
		return friends[steam_id]

	if not party_profiles.has(steam_id):
		party_profiles[steam_id] = _create_profile(steam_id)

	if (
		is_online()
		and _friends_menu_open
		and not _requested_profiles.has(steam_id)
	):
		_requested_profiles[steam_id] = true
		_update_profile(steam_id)
		Steam.requestUserInformation(steam_id, false)
		_request_avatar(steam_id)

	return party_profiles[steam_id]


func _get_cached_profile(steam_id: int) -> Dictionary:
	if friends.has(steam_id):
		return friends[steam_id]

	return party_profiles.get(steam_id, {})


func refresh_friends() -> void:
	if not is_online() or not _friends_menu_open:
		return

	if not Steam.loggedOn():
		return

	_refresh_my_profile()

	var flags: int = Steam.FRIEND_FLAG_IMMEDIATE
	var count: int = Steam.getFriendCount(flags)

	if count < 0:
		_set_error("Steam could not load your friends list.")
		return

	var current_ids: Dictionary = {}

	for index in range(count):
		var steam_id: int = Steam.getFriendByIndex(index, flags)
		current_ids[steam_id] = true

		if not friends.has(steam_id):
			friends[steam_id] = party_profiles.get(
				steam_id,
				_create_profile(steam_id)
			)

		_update_profile(steam_id)

		if friends[steam_id]["avatar"] == null:
			_request_avatar(steam_id)

	for steam_id in friends.keys():
		if not current_ids.has(steam_id):
			party_profiles[steam_id] = friends[steam_id]
			friends.erase(steam_id)

	# Refresh only current non-friend teammates.
	for steam_id in LobbyManager.members:
		if steam_id == my_steam_id or friends.has(steam_id):
			continue

		get_player_profile(steam_id)
		_update_profile(steam_id)

	_refresh_friend_lobbies()
	friends_changed.emit()


func _update_profile(steam_id: int) -> bool:
	if not _steam_initialized:
		return false

	var profile: Dictionary = _get_cached_profile(steam_id)

	if profile.is_empty():
		return false

	var display_name: String = Steam.getFriendPersonaName(steam_id)
	var state: int = Steam.getFriendPersonaState(steam_id)
	var game_info: Dictionary = Steam.getFriendGamePlayed(steam_id)

	var is_in_game: bool = (
		not game_info.is_empty()
		and int(game_info.get("id", 0)) == Steam.getAppID()
	)

	var friend_lobby_id: int = 0

	if is_in_game:
		friend_lobby_id = int(game_info.get("lobby", 0))

	var changed: bool = (
		profile["display_name"] != display_name
		or profile["state"] != state
		or bool(profile.get("is_in_game", false)) != is_in_game
		or int(profile.get("lobby_id", 0)) != friend_lobby_id
	)

	profile["display_name"] = display_name
	profile["state"] = state
	profile["is_in_game"] = is_in_game
	profile["is_online"] = state != Steam.PERSONA_STATE_OFFLINE
	profile["lobby_id"] = friend_lobby_id

	profile["status"] = (
		"In Game"
		if is_in_game
		else STATUS_NAMES.get(state, "Unknown")
	)

	return changed


func _refresh_my_profile() -> void:
	if not _steam_initialized:
		return

	my_steam_id = Steam.getSteamID()
	my_name = Steam.getPersonaName()

	if my_avatar == null:
		_request_avatar(my_steam_id)

	my_profile_changed.emit()


func _request_avatar(steam_id: int) -> void:
	if not _steam_initialized or steam_id <= 0:
		return

	var now: int = Time.get_ticks_msec()
	var previous: int = int(_avatar_requests.get(steam_id, -10000))

	if now - previous < AVATAR_REQUEST_INTERVAL_MS:
		return

	_avatar_requests[steam_id] = now
	Steam.getPlayerAvatar(2, steam_id)


func _on_persona_state_change(steam_id: int, flags: int) -> void:
	if not _steam_initialized:
		return

	if steam_id == my_steam_id:
		if (flags & AVATAR_CHANGED_FLAG) != 0:
			my_avatar = null
			_avatar_requests.erase(steam_id)

		if _friends_menu_open:
			_refresh_my_profile()

		return

	var profile: Dictionary = _get_cached_profile(steam_id)

	if not profile.is_empty():
		if (flags & AVATAR_CHANGED_FLAG) != 0:
			profile["avatar"] = null
			_avatar_requests.erase(steam_id)

	# Rebuild the list even if this is a newly added friend
	# who doesn't have a cached profile yet.
	_queue_friend_refresh()


func _on_avatar_loaded(
	steam_id: int,
	avatar_size: int,
	avatar_data: PackedByteArray
) -> void:
	if not _steam_initialized:
		return

	if (
		steam_id != my_steam_id
		and not friends.has(steam_id)
		and not party_profiles.has(steam_id)
	):
		return

	if avatar_size <= 0:
		return

	if avatar_data.size() != avatar_size * avatar_size * 4:
		return

	var image: Image = Image.create_from_data(
		avatar_size,
		avatar_size,
		false,
		Image.FORMAT_RGBA8,
		avatar_data
	)

	var texture: ImageTexture = ImageTexture.create_from_image(image)

	if steam_id == my_steam_id:
		my_avatar = texture
		my_profile_changed.emit()
	else:
		var profile: Dictionary = _get_cached_profile(steam_id)
		profile["avatar"] = texture
		friends_changed.emit()


func _refresh_friend_lobbies() -> void:
	var relevant_lobbies: Dictionary = {}

	for steam_id in friends:
		var target_lobby: int = int(
			friends[steam_id].get("lobby_id", 0)
		)

		if target_lobby == 0:
			continue

		# Steam already supplies updates for our current lobby.
		if target_lobby == LobbyManager.lobby_id:
			continue

		if relevant_lobbies.has(target_lobby):
			continue

		relevant_lobbies[target_lobby] = true
		_request_friend_lobby(target_lobby)

	for target_lobby in _friend_lobby_checks.keys():
		if not relevant_lobbies.has(target_lobby):
			_friend_lobby_checks.erase(target_lobby)


func _request_friend_lobby(target_lobby: int) -> void:
	if not is_online() or not _friends_menu_open:
		return

	if target_lobby <= 0 or target_lobby == LobbyManager.lobby_id:
		return

	var now: int = Time.get_ticks_msec()
	var check: Dictionary = _friend_lobby_checks.get(target_lobby, {})

	if bool(check.get("pending", false)):
		var sent_at: int = int(check.get("sent_at", 0))

		if now - sent_at < LOBBY_REQUEST_TIMEOUT_MS:
			return

	check["pending"] = true
	check["sent_at"] = now
	_friend_lobby_checks[target_lobby] = check

	if not Steam.requestLobbyData(target_lobby):
		check["pending"] = false
		check["available"] = false
		check["checked_at"] = now


func _on_friend_lobby_data_update(
	success: int,
	changed_lobby: int,
	member_id: int
) -> void:
	if not is_online():
		return

	if not _friend_lobby_checks.has(changed_lobby):
		return

	# Ignore changes to an individual member's metadata.
	if success != 0 and member_id != changed_lobby:
		return

	var check: Dictionary = _friend_lobby_checks[changed_lobby]

	check["pending"] = false
	check["checked_at"] = Time.get_ticks_msec()
	check["available"] = success != 0

	if success != 0:
		check["privacy"] = Steam.getLobbyData(
			changed_lobby,
			"party_invite_only"
		)

		check["access"] = Steam.getLobbyData(
			changed_lobby,
			"party_access_" + str(my_steam_id)
		)

	friends_changed.emit()


func get_friend_lobby_id(steam_id: int) -> int:
	if not is_online():
		return 0

	var game_info: Dictionary = Steam.getFriendGamePlayed(steam_id)

	if game_info.is_empty():
		return 0

	if int(game_info.get("id", 0)) != Steam.getAppID():
		return 0

	return int(game_info.get("lobby", 0))


func get_friend_join_status(steam_id: int) -> String:
	if not is_online():
		return "offline"

	if LobbyManager.is_in_party(steam_id):
		return "in_party"

	# Use the same profile data the friend row displays.
	var profile: Dictionary = friends.get(steam_id, {})

	if profile.is_empty():
		return "unavailable"

	if not bool(profile.get("is_in_game", false)):
		return "not_in_game"

	var target_lobby: int = int(profile.get("lobby_id", 0))

	if target_lobby == 0:
		return "no_lobby"

	if target_lobby == LobbyManager.lobby_id:
		return "in_party"

	var check: Dictionary = _friend_lobby_checks.get(target_lobby, {})

	if check.is_empty() or not check.has("checked_at"):
		return "checking"

	var age: int = (
		Time.get_ticks_msec() - int(check["checked_at"])
	)

	if age > LOBBY_DATA_MAX_AGE_MS:
		return "checking"

	if not bool(check.get("available", false)):
		return "unavailable"

	var privacy: String = str(check.get("privacy", ""))

	if privacy.is_empty():
		return "unavailable"

	if privacy != "0":
		return "invite_only"

	var access: String = str(check.get("access", ""))

	if access == "kicked" or access == "cancelled":
		return "blocked"

	return "available"


func can_join_friend(steam_id: int) -> bool:
	return get_friend_join_status(steam_id) == "available"


func _on_overlay_toggled(
	active: bool,
	_user_initiated: bool,
	_app_id: int
) -> void:
	if not _steam_initialized:
		return

	overlay_active = active
	overlay_changed.emit(active)


func open_friends_overlay() -> void:
	if not is_online():
		return

	Steam.activateGameOverlay("friends")
