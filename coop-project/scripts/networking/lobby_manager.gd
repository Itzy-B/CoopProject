extends Node

signal party_changed
signal invitations_changed
signal privacy_changed
signal operation_failed(message: String)
signal removed_from_party(reason: String)

const MAX_PLAYERS: int = 4
const ACCESS_PREFIX: String = "party_access_"
const PRIVACY_KEY: String = "party_invite_only"

const PARTY_APP_KEY: String = "party_app_id"
const PARTY_GAME_KEY: String = "party_game"
const PARTY_CODE_KEY: String = "party_code"

# Keep identical in every build used by your players.
# Separates this project from other games using test AppID 480.
const GAME_IDENTIFIER: String = "itzy_party_20261017_v1"

const CODE_LENGTH: int = 5
const CODE_ALPHABET: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const CODE_LOOKUP_TIMEOUT_MS: int = 15000
const ADMISSION_GRACE_MS: int = 5000

var lobby_id: int = 0
var owner_id: int = 0
var members: Array[int] = []
var pending_invites: Dictionary = {}
var invite_only: bool = true

var _online_active: bool = false
var _creating: bool = false
var _joining: bool = false
var _join_target: int = 0

var _party_code: String = ""
var _search_code: String = ""
var _searching_code: bool = false
var _code_lookup_deadline: int = 0

var _admission_deadline: int = 0
var _refresh_elapsed: float = 0.0
var _code_rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_code_rng.randomize()

	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	Steam.lobby_chat_update.connect(_on_lobby_chat_update)
	Steam.lobby_data_update.connect(_on_lobby_data_update)
	Steam.lobby_match_list.connect(_on_lobby_match_list)
	Steam.join_requested.connect(_on_join_requested)


func _process(delta: float) -> void:
	if not _online_active:
		return

	if _searching_code:
		if not Steam.loggedOn():
			_finish_code_search()
			_fail("No access to online services.")
		elif Time.get_ticks_msec() >= _code_lookup_deadline:
			_finish_code_search()
			_fail("Party search timed out. Please try again.")

	if lobby_id == 0 or not Steam.loggedOn():
		return

	_refresh_elapsed += delta

	if _refresh_elapsed >= 0.5:
		_refresh_elapsed = 0.0
		_refresh_members()


func activate_online() -> bool:
	if not Steam.loggedOn():
		_fail("Steam is not connected.")
		return false

	_online_active = true
	return true


func deactivate_online() -> bool:
	if not _online_active:
		return true

	if is_busy():
		_fail("Wait until the party operation has finished.")
		return false

	leave_party()
	_online_active = false
	return true


# Safe to call after Steam shuts down.
func reset_online_state() -> void:
	_online_active = false
	_reset_party()


func is_online_active() -> bool:
	return _online_active


func is_joining_party() -> bool:
	return _joining or _searching_code


func is_searching_party_code() -> bool:
	return _searching_code


func is_busy() -> bool:
	return _creating or _joining or _searching_code


func is_owner() -> bool:
	if not _online_active or lobby_id == 0:
		return false

	if not Steam.loggedOn():
		return false

	return Steam.getLobbyOwner(lobby_id) == Steam.getSteamID()


func is_in_party(steam_id: int) -> bool:
	return members.has(steam_id)


func has_pending_invite(steam_id: int) -> bool:
	return pending_invites.has(steam_id)


func can_invite() -> bool:
	if not _online_active or is_busy() or lobby_id == 0:
		return false

	if not Steam.loggedOn():
		return false

	return (
		is_owner()
		and Steam.getNumLobbyMembers(lobby_id) < MAX_PLAYERS
	)


func can_kick(steam_id: int) -> bool:
	return (
		not is_busy()
		and is_owner()
		and steam_id != Steam.getSteamID()
		and is_in_party(steam_id)
	)


func start_hosting() -> bool:
	if not _require_online():
		return false

	if is_busy():
		_fail("A party operation is already running.")
		return false

	if lobby_id != 0:
		_fail("Leave the current party before hosting another.")
		return false

	invite_only = true
	_party_code = ""
	_creating = true

	Steam.createLobby(
		Steam.LOBBY_TYPE_PRIVATE,
		MAX_PLAYERS
	)

	privacy_changed.emit()
	invitations_changed.emit()
	return true


func set_invite_only(value: bool) -> bool:
	if not _require_online():
		return false

	if is_busy():
		_fail("Wait until the party operation has finished.")
		return false

	if lobby_id == 0:
		_fail("Host a lobby before changing its privacy.")
		return false

	if not is_owner():
		_fail("Only the owner can change party privacy.")
		return false

	if value == invite_only:
		return true

	if not _approve_open_members():
		return false

	return _publish_privacy(value)


func _publish_privacy(value: bool) -> bool:
	var previous_type: int = _get_lobby_type(invite_only)
	var next_type: int = _get_lobby_type(value)

	if not Steam.setLobbyType(lobby_id, next_type):
		_fail("Steam could not change party privacy.")
		return false

	if not Steam.setLobbyData(
		lobby_id,
		PRIVACY_KEY,
		"1" if value else "0"
	):
		Steam.setLobbyType(lobby_id, previous_type)
		_fail("Steam could not synchronize party privacy.")
		return false

	invite_only = value
	privacy_changed.emit()
	_refresh_members()
	return true


func _get_lobby_type(locked: bool) -> int:
	return (
		Steam.LOBBY_TYPE_PRIVATE
		if locked
		else Steam.LOBBY_TYPE_PUBLIC
	)


func _sync_lobby_privacy() -> void:
	var stored: String = Steam.getLobbyData(lobby_id, PRIVACY_KEY)

	if stored.is_empty():
		return

	var next_value: bool = stored != "0"

	if invite_only != next_value:
		invite_only = next_value
		privacy_changed.emit()


func _approve_open_members() -> bool:
	if invite_only or not is_owner():
		return true

	var count: int = Steam.getNumLobbyMembers(lobby_id)

	for index in range(count):
		var steam_id: int = Steam.getLobbyMemberByIndex(lobby_id, index)

		if steam_id == Steam.getSteamID():
			continue

		# Voluntary departure preserves access.
		# Kicks and cancelled invitations remain blocked.
		if _get_access(steam_id).is_empty():
			if not _set_access(steam_id, "allowed"):
				return false

	return true


func invite_friend(steam_id: int) -> void:
	if not _require_online():
		return

	if is_busy():
		_fail("Wait until the party operation has finished.")
		return

	if steam_id <= 0 or steam_id == Steam.getSteamID():
		return

	if is_in_party(steam_id) or has_pending_invite(steam_id):
		return

	if lobby_id == 0:
		_fail("Host a lobby before inviting friends.")
		return

	if not is_owner():
		_fail("Only the party owner can invite players.")
		return

	_send_invite(steam_id)


func _send_invite(steam_id: int) -> void:
	if Steam.getNumLobbyMembers(lobby_id) >= MAX_PLAYERS:
		_fail("Your party is full.")
		return

	var previous_access: String = _get_access(steam_id)

	if not _set_access(steam_id, "allowed"):
		return

	if Steam.inviteUserToLobby(lobby_id, steam_id):
		pending_invites[steam_id] = true
	else:
		_set_access(steam_id, previous_access)
		pending_invites.erase(steam_id)
		_fail("Steam could not send the invitation.")

	invitations_changed.emit()


func cancel_invite(steam_id: int) -> void:
	if not _require_online():
		return

	if is_busy() or not has_pending_invite(steam_id):
		return

	if not is_owner():
		_fail("Only the party owner can cancel invitations.")
		return

	if _steam_contains_member(steam_id):
		_refresh_members()
		_fail("This player already joined. Use Kick instead.")
		return

	if not _set_access(steam_id, "cancelled"):
		return

	pending_invites.erase(steam_id)
	invitations_changed.emit()
	_refresh_members()


func kick_member(steam_id: int) -> void:
	if not _require_online():
		return

	if is_busy():
		return

	if not can_kick(steam_id):
		_fail("Only the owner can kick another party member.")
		return

	if not _set_access(steam_id, "kicked"):
		return

	pending_invites.erase(steam_id)
	invitations_changed.emit()
	_refresh_members()


func get_party_code() -> String:
	if not _online_active or lobby_id == 0:
		return ""

	if not Steam.loggedOn():
		return ""

	return _party_code


func _generate_party_code() -> String:
	var code: String = ""

	for index in range(CODE_LENGTH):
		var character_index: int = _code_rng.randi_range(
			0,
			CODE_ALPHABET.length() - 1
		)
		code += CODE_ALPHABET.substr(character_index, 1)

	return code


func _is_valid_party_code(code: String) -> bool:
	if code.length() != CODE_LENGTH:
		return false

	for index in range(code.length()):
		if CODE_ALPHABET.find(code.substr(index, 1)) == -1:
			return false

	return true


func _publish_party_code() -> bool:
	var code: String = _generate_party_code()

	if not Steam.setLobbyData(
		lobby_id,
		PARTY_APP_KEY,
		str(Steam.getAppID())
	):
		return false

	if not Steam.setLobbyData(
		lobby_id,
		PARTY_GAME_KEY,
		GAME_IDENTIFIER
	):
		return false

	if not Steam.setLobbyData(lobby_id, PARTY_CODE_KEY, code):
		return false

	_party_code = code
	return true


func _sync_party_code() -> bool:
	var code: String = Steam.getLobbyData(lobby_id, PARTY_CODE_KEY)

	if not _is_valid_party_code(code):
		code = ""

	if code == _party_code:
		return false

	_party_code = code
	return true


func join_by_code(text: String) -> void:
	if not _require_online():
		return

	if is_busy():
		_fail("Wait until the party operation has finished.")
		return

	var code: String = text.strip_edges().to_upper()

	if not _is_valid_party_code(code):
		_fail("Enter a five-character party code. O, 0, I and 1 are not used.")
		return

	if lobby_id != 0 and code == _party_code:
		_fail("You are already in this party.")
		return

	_search_code = code
	_searching_code = true
	_code_lookup_deadline = (
		Time.get_ticks_msec() + CODE_LOOKUP_TIMEOUT_MS
	)

	# Reapply all filters for each search.
	Steam.addRequestLobbyListStringFilter(
		PARTY_GAME_KEY,
		GAME_IDENTIFIER,
		Steam.LOBBY_COMPARISON_EQUAL
	)
	Steam.addRequestLobbyListStringFilter(
		PARTY_APP_KEY,
		str(Steam.getAppID()),
		Steam.LOBBY_COMPARISON_EQUAL
	)
	Steam.addRequestLobbyListStringFilter(
		PARTY_CODE_KEY,
		code,
		Steam.LOBBY_COMPARISON_EQUAL
	)
	Steam.addRequestLobbyListDistanceFilter(
		Steam.LOBBY_DISTANCE_FILTER_WORLDWIDE
	)

	# Two results are enough to detect an ambiguous search.
	Steam.addRequestLobbyListResultCountFilter(2)

	invitations_changed.emit()
	Steam.requestLobbyList()


func _finish_code_search() -> void:
	_searching_code = false
	_search_code = ""
	_code_lookup_deadline = 0
	invitations_changed.emit()


func _on_lobby_match_list(lobbies: Array) -> void:
	if not _online_active or not _searching_code:
		return

	var requested_code: String = _search_code
	var matches: Array[int] = []

	if not Steam.loggedOn():
		_finish_code_search()
		_fail("No access to online services.")
		return

	for entry in lobbies:
		var target: int = int(entry)

		if target <= 0 or matches.has(target):
			continue

		if Steam.getLobbyData(target, PARTY_GAME_KEY) != GAME_IDENTIFIER:
			continue

		if Steam.getLobbyData(target, PARTY_APP_KEY) != str(Steam.getAppID()):
			continue

		if Steam.getLobbyData(target, PARTY_CODE_KEY) != requested_code:
			continue

		matches.append(target)

	_finish_code_search()

	if matches.is_empty():
		_fail("Party not found or unavailable. Ask the host to open it.")
		return

	if matches.size() > 1:
		_fail("This code matches multiple parties. Ask the host to recreate the lobby.")
		return

	var target_lobby: int = matches[0]

	if target_lobby == lobby_id:
		_fail("You are already in this party.")
		return

	if Steam.getLobbyData(target_lobby, PRIVACY_KEY) != "0":
		_fail("This party is invite only. Ask the host to open it.")
		return

	var access: String = Steam.getLobbyData(
		target_lobby,
		_access_key(Steam.getSteamID())
	)

	if access == "kicked" or access == "cancelled":
		_fail("Ask the host for a new invitation to this party.")
		return

	join_party(target_lobby)


func join_friend(steam_id: int) -> void:
	if not _require_online():
		return

	if is_busy():
		_fail("Wait until the party operation has finished.")
		return

	var target_lobby: int = SteamManager.get_friend_lobby_id(steam_id)

	if target_lobby == 0:
		_fail("This friend no longer has a lobby for this game.")
		return

	if target_lobby == lobby_id:
		return

	if not SteamManager.can_join_friend(steam_id):
		_fail("This friend's party is not currently available.")
		return

	join_party(target_lobby)


func join_party(target_lobby: int) -> void:
	if not _require_online():
		return

	if target_lobby <= 0 or target_lobby == lobby_id:
		return

	if is_busy():
		_fail("A party operation is already running.")
		return

	leave_party()

	_joining = true
	_join_target = target_lobby

	invitations_changed.emit()
	Steam.joinLobby(target_lobby)


func leave_party() -> void:
	if is_busy():
		_fail("Wait until the party operation has finished.")
		return

	if _online_active and lobby_id != 0:
		Steam.leaveLobby(lobby_id)

	_reset_party()


func _reset_party() -> void:
	lobby_id = 0
	owner_id = 0
	members.clear()
	pending_invites.clear()

	invite_only = true
	_creating = false
	_joining = false
	_join_target = 0

	_party_code = ""
	_search_code = ""
	_searching_code = false
	_code_lookup_deadline = 0

	_admission_deadline = 0
	_refresh_elapsed = 0.0

	party_changed.emit()
	invitations_changed.emit()
	privacy_changed.emit()


func _on_lobby_created(result: int, _new_lobby_id: int) -> void:
	if not _online_active or not _creating:
		return

	if result != 1:
		_reset_party()
		_fail("Could not create the party. Steam result: %s" % result)

	# Successful creation also produces lobby_joined.


func _on_lobby_joined(
	new_lobby_id: int,
	_permissions: int,
	_locked: bool,
	response: int
) -> void:
	if not _online_active:
		return

	if not _creating and not _joining:
		return

	if _joining and new_lobby_id != _join_target:
		return

	var was_creating: bool = _creating

	_creating = false
	_joining = false
	_join_target = 0

	if response != 1:
		_reset_party()
		_fail("Could not join the party. Steam response: %s" % response)
		return

	lobby_id = new_lobby_id
	_admission_deadline = (
		Time.get_ticks_msec() + ADMISSION_GRACE_MS
	)

	if was_creating:
		if not _publish_party_code():
			leave_party()
			_fail("Steam could not prepare the party code.")
			return

		if not _publish_privacy(invite_only):
			leave_party()
			return
	else:
		_sync_lobby_privacy()
		_sync_party_code()

	_refresh_members()
	invitations_changed.emit()


func _on_join_requested(
	target_lobby: int,
	_friend_id: int
) -> void:
	if not _online_active:
		return

	join_party(target_lobby)


func _on_lobby_chat_update(
	changed_lobby: int,
	_changed_user: int,
	_making_change: int,
	_chat_state: int
) -> void:
	if _online_active and changed_lobby == lobby_id:
		_refresh_members()


func _on_lobby_data_update(
	success: int,
	changed_lobby: int,
	_member_id: int
) -> void:
	if (
		_online_active
		and success != 0
		and changed_lobby == lobby_id
	):
		_refresh_members()


func _refresh_members() -> void:
	if not _online_active or lobby_id == 0:
		return

	if not Steam.loggedOn():
		return

	var current_owner: int = Steam.getLobbyOwner(lobby_id)

	if current_owner == 0:
		return

	_sync_lobby_privacy()
	var code_changed: bool = _sync_party_code()

	if not _approve_open_members():
		return

	var my_id: int = Steam.getSteamID()

	if my_id != current_owner:
		var access: String = _get_access(my_id)

		if access != "allowed":
			if (
				access.is_empty()
				and Time.get_ticks_msec() < _admission_deadline
			):
				return

			var reason: String = "This invitation is no longer valid."

			if access == "kicked":
				reason = "You were removed from the party."

			if _searching_code:
				_finish_code_search()

			leave_party()
			removed_from_party.emit(reason)
			return

	var next_members: Array[int] = []
	var count: int = Steam.getNumLobbyMembers(lobby_id)

	if _steam_contains_member(current_owner):
		next_members.append(current_owner)

	for index in range(count):
		var steam_id: int = Steam.getLobbyMemberByIndex(lobby_id, index)

		if steam_id == current_owner:
			continue

		if _get_access(steam_id) == "allowed":
			next_members.append(steam_id)

	var invites_changed: bool = false

	for steam_id in next_members:
		if pending_invites.erase(steam_id):
			invites_changed = true

	var changed: bool = (
		owner_id != current_owner
		or members != next_members
		or code_changed
	)

	owner_id = current_owner
	members = next_members

	if changed:
		party_changed.emit()

	if invites_changed:
		invitations_changed.emit()


func _access_key(steam_id: int) -> String:
	return ACCESS_PREFIX + str(steam_id)


func _get_access(steam_id: int) -> String:
	return Steam.getLobbyData(lobby_id, _access_key(steam_id))


func _set_access(steam_id: int, value: String) -> bool:
	if not is_owner():
		return false

	if not Steam.setLobbyData(
		lobby_id,
		_access_key(steam_id),
		value
	):
		_fail("Steam could not update party access.")
		return false

	return true


func _steam_contains_member(steam_id: int) -> bool:
	if lobby_id == 0:
		return false

	var count: int = Steam.getNumLobbyMembers(lobby_id)

	for index in range(count):
		if Steam.getLobbyMemberByIndex(lobby_id, index) == steam_id:
			return true

	return false


func _require_online() -> bool:
	if not _online_active:
		_fail("Online features are turned off.")
		return false

	if not Steam.loggedOn():
		_fail("Steam is not connected.")
		return false

	return true


func _fail(message: String) -> void:
	push_warning(message)
	operation_failed.emit(message)
