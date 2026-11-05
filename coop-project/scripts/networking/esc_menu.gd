extends Control

const LIST_PATH: String = (
	"HostVBoxContainer/FriendsViewportContainer/"
	+ "SubViewport/ListScrollContainer/MarginContainer/VBoxContainer"
)

@export var friend_panel_scene: PackedScene
@export var start_open: bool = true

@export_group("Menu Sections")
@export var options_container: Control
@export var host_panel: Control
@export var lobby_portraits: Control
@export var party_section: Control
@export var error_display: Label

@export_group("Lobby Button")
@export var host_button: Button
@export var hold_progress: ProgressBar
@export var hold_seconds: float = 1.0
@export var drain_seconds: float = 1.0

@export_group("Friend List")
@export var online_container: VBoxContainer
@export var offline_container: VBoxContainer
@export var invite_sent_container: VBoxContainer
@export var party_container: VBoxContainer
@export var in_game_container: VBoxContainer

@export_group("Code Visibility Textures")
@export var code_hidden_texture: Texture2D
@export var code_visible_texture: Texture2D

@export_group("My Profile")
@export var my_portrait: TextureButton
@export var my_name_label: Label

@export_group("Party Code")
@export var party_code_section: Control
@export var party_code_field: LineEdit
@export var hide_code_button: TextureButton
@export var copy_code_button: TextureButton

@export_group("Join By Code")
@export var join_code_section: Control
@export var join_code_field: LineEdit
@export var join_code_button: TextureButton

@export_group("Error Popup")
@export var error_display_seconds: float = 3.0
@export var error_fade_seconds: float = 1.0

var _menu_open: bool = false
var _list_ready: bool = false
var _refresh_queued: bool = false

var _friend_rows: Dictionary = {}
var _my_placeholder_avatar: Texture2D

var _holding: bool = false
var _hold_value: float = 0.0
var _hold_lobby_id: int = 0

var _party_code_hidden: bool = true
var _displayed_code_lobby: int = 0
var _error_tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	show()

	_resolve_nodes()
	_setup_party_code_controls()

	if my_portrait != null:
		_my_placeholder_avatar = my_portrait.texture_normal

	if host_button != null:
		host_button.toggle_mode = false
		host_button.button_down.connect(_on_hold_started)
		host_button.button_up.connect(_on_hold_released)
		host_button.mouse_exited.connect(_on_hold_released)

	if hold_progress != null:
		hold_progress.min_value = 0.0
		hold_progress.max_value = 1.0
		hold_progress.step = 0.001
		hold_progress.value = 0.0
		hold_progress.show_percentage = false
		hold_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE

	if error_display != null:
		error_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
		error_display.hide()

	visibility_changed.connect(_on_root_visibility_changed)

	SteamManager.online_state_changed.connect(_on_online_state_changed)
	SteamManager.error_changed.connect(_show_error)
	SteamManager.my_profile_changed.connect(_update_my_profile)
	SteamManager.my_profile_changed.connect(_queue_refresh)
	SteamManager.friends_changed.connect(_queue_refresh)

	LobbyManager.party_changed.connect(_on_party_changed)
	LobbyManager.invitations_changed.connect(_on_party_operation_changed)
	LobbyManager.privacy_changed.connect(_sync_party_code_ui)

	_list_ready = _validate_friend_list()
	set_menu_open(start_open)


func _resolve_nodes() -> void:
	if options_container == null:
		options_container = get_node_or_null(
			"OptionsVBoxContainer"
		) as Control

	if host_panel == null or host_panel == self:
		host_panel = get_node_or_null("HostVBoxContainer") as Control

	if lobby_portraits == null:
		lobby_portraits = get_node_or_null(
			"HostVBoxContainer/LobbyHBoxContainer"
		) as Control

	if party_section == null:
		party_section = _list_node("Party") as Control

	if host_button == null:
		host_button = _list_node("Confirm") as Button

	if hold_progress == null and host_button != null:
		hold_progress = host_button.get_node_or_null(
			"ConfirmProgressBar"
		) as ProgressBar

	if error_display == null:
		error_display = get_node_or_null("ErrorDisplay") as Label

	if online_container == null:
		online_container = _list_node(
			"Online/OnlineVBoxContainer"
		) as VBoxContainer

	if offline_container == null:
		offline_container = _list_node(
			"Offline/OfflineVBoxContainer"
		) as VBoxContainer

	if invite_sent_container == null:
		invite_sent_container = _list_node(
			"Party/InvitesSentVBoxContainer"
		) as VBoxContainer

	if party_container == null:
		party_container = _list_node(
			"Party/PartyVBoxContainer"
		) as VBoxContainer

	if in_game_container == null:
		in_game_container = _list_node(
			"InGame/InGameVBoxContainer"
		) as VBoxContainer

	if party_code_section == null:
		party_code_section = _list_node(
			"PartyCodeVBoxContainer"
		) as Control

	var code_path: String = (
		"PartyCodeVBoxContainer/PartyCodeHBoxContainer/"
	)

	if party_code_field == null:
		party_code_field = _list_node(
			code_path + "PartyCodeLineEdit"
		) as LineEdit

	if hide_code_button == null:
		hide_code_button = _list_node(
			code_path + "HideTextureButton"
		) as TextureButton

	if copy_code_button == null:
		copy_code_button = _list_node(
			code_path + "CopyTextureButton"
		) as TextureButton

	if join_code_section == null:
		join_code_section = _list_node(
			"JoinVBoxContainer"
		) as Control

	if join_code_field == null:
		join_code_field = _list_node(
			"JoinVBoxContainer/JoinHBoxContainer/JoinLineEdit"
		) as LineEdit

	if join_code_button == null:
		join_code_button = _list_node(
			"JoinVBoxContainer/JoinHBoxContainer/JoinTextureButton"
		) as TextureButton

	if options_container == null or host_panel == null:
		push_error("EscMenu: assign Options Container and Host Panel.")

	if host_button == null or hold_progress == null:
		push_error("EscMenu: assign Host Button and Hold Progress.")

	if lobby_portraits == null or party_section == null:
		push_error("EscMenu: assign Lobby Portraits and Party Section.")

	if error_display == null:
		push_error("EscMenu: assign Error Display.")

	if (
		party_code_section == null
		or party_code_field == null
		or hide_code_button == null
		or copy_code_button == null
		or join_code_section == null
		or join_code_field == null
		or join_code_button == null
	):
		push_error("EscMenu: assign the Party Code and Join By Code nodes.")


func _list_node(relative_path: String) -> Node:
	return get_node_or_null(LIST_PATH + "/" + relative_path)


func _validate_friend_list() -> bool:
	if friend_panel_scene == null:
		push_error("EscMenu: assign Friend Panel Scene.")
		return false

	if (
		online_container == null
		or offline_container == null
		or invite_sent_container == null
		or party_container == null
		or in_game_container == null
	):
		push_error("EscMenu: assign all five friend-list containers.")
		return false

	return true


func _setup_party_code_controls() -> void:
	if party_code_field != null:
		party_code_field.editable = false
		party_code_field.secret = true
		party_code_field.text = ""
		party_code_field.placeholder_text = "Create a lobby first"

	if hide_code_button != null:
		hide_code_button.toggle_mode = false
		hide_code_button.pressed.connect(_on_hide_code_pressed)

	if copy_code_button != null:
		copy_code_button.toggle_mode = false
		copy_code_button.tooltip_text = "Copy party code"
		copy_code_button.pressed.connect(_on_copy_code_pressed)

	if join_code_field != null:
		join_code_field.placeholder_text = "Enter party code"
		join_code_field.text_changed.connect(_on_join_code_changed)
		join_code_field.text_submitted.connect(_on_join_code_submitted)

	if join_code_button != null:
		join_code_button.toggle_mode = false
		join_code_button.tooltip_text = "Join party"
		join_code_button.pressed.connect(_on_join_code_pressed)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("esc_menu") and not event.is_echo():
		set_menu_open(not _menu_open)
		get_viewport().set_input_as_handled()


func set_menu_open(value: bool) -> void:
	_menu_open = value

	if not value:
		_reset_hold()
		_party_code_hidden = true
		_release_code_focus()

	_sync_ui()
	_show_error(SteamManager.last_error)

	if _is_menu_visible():
		_update_my_profile()
		_queue_refresh()


func _is_menu_visible() -> bool:
	return _menu_open and is_visible_in_tree()


func _can_show_friends() -> bool:
	return _is_menu_visible() and SteamManager.is_online()


func _sync_ui() -> void:
	var menu_visible: bool = _is_menu_visible()
	var friends_visible: bool = _can_show_friends()
	var has_lobby: bool = LobbyManager.lobby_id != 0

	if options_container != null:
		options_container.visible = menu_visible

	if host_panel != null:
		host_panel.visible = friends_visible

	if lobby_portraits != null:
		lobby_portraits.visible = friends_visible and has_lobby

	if party_section != null:
		party_section.visible = friends_visible and has_lobby

	SteamManager.set_friends_menu_open(friends_visible)

	if host_button != null:
		host_button.disabled = (
			not friends_visible
			or SteamManager.is_busy()
			or hold_progress == null
		)

		host_button.text = (
			"Leave Lobby" if has_lobby else "Create Lobby"
		)

		host_button.tooltip_text = (
			"Hold for %.1f seconds to leave." % hold_seconds
			if has_lobby
			else "Hold for %.1f seconds to create a lobby." % hold_seconds
		)

	_sync_party_code_ui()


func _sync_party_code_ui() -> void:
	var online_visible: bool = _can_show_friends()
	var current_lobby: int = LobbyManager.lobby_id
	var has_lobby: bool = current_lobby != 0
	var busy: bool = SteamManager.is_busy()

	if current_lobby != _displayed_code_lobby:
		_displayed_code_lobby = current_lobby
		_party_code_hidden = true

		if has_lobby and join_code_field != null:
			join_code_field.release_focus()
			join_code_field.clear()

	var code: String = ""

	if online_visible and has_lobby:
		code = LobbyManager.get_party_code()

	if party_code_section != null:
		party_code_section.visible = online_visible and has_lobby

	if party_code_field != null:
		if party_code_field.text != code:
			party_code_field.text = code

		party_code_field.secret = _party_code_hidden
		party_code_field.tooltip_text = (
			"Invite Only: the host must open the lobby for code joining."
			if LobbyManager.invite_only
			else "Share this code to let someone join your party."
		)

	if hide_code_button != null:
		hide_code_button.disabled = code.is_empty()
		hide_code_button.tooltip_text = (
			"Show party code"
			if _party_code_hidden
			else "Hide party code"
		)

	if copy_code_button != null:
		copy_code_button.disabled = code.is_empty()

	if join_code_section != null:
		join_code_section.visible = online_visible and not has_lobby

	var can_enter_code: bool = (
		online_visible and not has_lobby and not busy
	)

	var has_input: bool = false

	if join_code_field != null:
		join_code_field.editable = can_enter_code
		has_input = not join_code_field.text.strip_edges().is_empty()

	if join_code_button != null:
		join_code_button.disabled = not can_enter_code or not has_input
		join_code_button.tooltip_text = (
			"Checking or joining party..." if busy else "Join party"
		)
	_update_code_visibility_texture()


func _on_hide_code_pressed() -> void:
	if not _can_show_friends() or LobbyManager.lobby_id == 0:
		return

	_party_code_hidden = not _party_code_hidden
	_update_code_visibility_texture()


func _update_code_visibility_texture() -> void:
	if party_code_field != null:
		party_code_field.secret = _party_code_hidden

	if hide_code_button == null:
		return

	var texture: Texture2D = (
		code_hidden_texture
		if _party_code_hidden
		else code_visible_texture
	)

	hide_code_button.texture_normal = texture
	hide_code_button.texture_hover = texture
	hide_code_button.texture_pressed = texture
	hide_code_button.texture_disabled = texture
	hide_code_button.texture_focused = null

	hide_code_button.tooltip_text = (
		"Show party code"
		if _party_code_hidden
		else "Hide party code"
	)


func _on_copy_code_pressed() -> void:
	if not _can_show_friends():
		return

	var code: String = LobbyManager.get_party_code()

	if not code.is_empty():
		DisplayServer.clipboard_set(code)


func _on_join_code_changed(_text: String) -> void:
	_sync_party_code_ui()


func _on_join_code_submitted(_text: String) -> void:
	_on_join_code_pressed()


func _on_join_code_pressed() -> void:
	if not _can_show_friends() or SteamManager.is_busy():
		return

	if LobbyManager.lobby_id != 0 or join_code_field == null:
		return

	var code: String = join_code_field.text.strip_edges()

	if code.is_empty():
		return

	_reset_hold()
	SteamManager.clear_error()
	LobbyManager.join_by_code(code)
	_sync_ui()


func _release_code_focus() -> void:
	if party_code_field != null:
		party_code_field.release_focus()

	if join_code_field != null:
		join_code_field.release_focus()


func _on_hold_started() -> void:
	if not _can_show_friends() or SteamManager.is_busy():
		return

	if host_button == null or hold_progress == null:
		return

	if _hold_lobby_id != LobbyManager.lobby_id:
		_reset_hold()

	_hold_lobby_id = LobbyManager.lobby_id
	_holding = true


func _on_hold_released() -> void:
	_holding = false


func _process(delta: float) -> void:
	if not _holding and _hold_value <= 0.0:
		return

	if (
		host_button == null
		or hold_progress == null
		or not _can_show_friends()
		or SteamManager.is_busy()
		or _hold_lobby_id != LobbyManager.lobby_id
	):
		_reset_hold()
		return

	if _holding and host_button.is_pressed():
		_hold_value = move_toward(
			_hold_value, 1.0, delta / maxf(hold_seconds, 0.1)
		)
	else:
		_hold_value = move_toward(
			_hold_value, 0.0, delta / maxf(drain_seconds, 0.1)
		)

	hold_progress.value = _hold_value

	if _hold_value >= 1.0:
		_execute_lobby_action()


func _execute_lobby_action() -> void:
	var target_lobby: int = _hold_lobby_id
	_reset_hold()

	if not _can_show_friends() or SteamManager.is_busy():
		return

	if LobbyManager.lobby_id != target_lobby:
		return

	SteamManager.clear_error()

	if target_lobby == 0:
		LobbyManager.start_hosting()
	else:
		LobbyManager.leave_party()

	_sync_ui()


func _reset_hold() -> void:
	_holding = false
	_hold_value = 0.0
	_hold_lobby_id = LobbyManager.lobby_id

	if hold_progress != null:
		hold_progress.value = 0.0


func _on_online_state_changed() -> void:
	_reset_hold()

	if not SteamManager.is_online():
		_party_code_hidden = true
		_release_code_focus()

	_sync_ui()
	_show_error(SteamManager.last_error)

	if not SteamManager.is_online():
		_clear_friend_rows()
		return

	_update_my_profile()
	_queue_refresh()


func _on_party_changed() -> void:
	_reset_hold()
	_sync_ui()
	_queue_refresh()


func _on_party_operation_changed() -> void:
	_sync_ui()
	_queue_refresh()


func _on_root_visibility_changed() -> void:
	if not _is_menu_visible():
		_reset_hold()
		_party_code_hidden = true
		_release_code_focus()

	_sync_ui()
	_show_error(SteamManager.last_error)
	_update_my_profile()
	_queue_refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_node_ready():
		_reset_hold()


func _show_error(message: String) -> void:
	if error_display == null:
		return

	if _error_tween != null:
		_error_tween.kill()
		_error_tween = null

	if not _is_menu_visible():
		error_display.hide()
		return

	if not SteamManager.is_online():
		error_display.text = "No access to online services."
		error_display.modulate.a = 1.0
		error_display.show()
		return

	if message.is_empty():
		error_display.hide()
		return

	error_display.text = message
	error_display.modulate.a = 1.0
	error_display.show()

	_error_tween = create_tween()
	_error_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_error_tween.tween_interval(maxf(error_display_seconds, 0.0))
	_error_tween.tween_property(
		error_display,
		"modulate:a",
		0.0,
		maxf(error_fade_seconds, 0.01)
	)
	_error_tween.tween_callback(error_display.hide)


func _update_my_profile() -> void:
	if not _can_show_friends():
		return

	if my_name_label != null:
		my_name_label.text = SteamManager.my_name

	if my_portrait != null:
		my_portrait.texture_normal = (
			SteamManager.my_avatar
			if SteamManager.my_avatar != null
			else _my_placeholder_avatar
		)


func _queue_refresh() -> void:
	if not _list_ready or not _can_show_friends() or _refresh_queued:
		return

	_refresh_queued = true
	call_deferred("_refresh_friend_rows")


func _refresh_friend_rows() -> void:
	_refresh_queued = false

	if not _list_ready or not _can_show_friends():
		return

	var profiles: Dictionary = SteamManager.friends.duplicate()
	var my_id: int = SteamManager.my_steam_id
	var has_lobby: bool = LobbyManager.lobby_id != 0

	profiles.erase(my_id)

	if has_lobby and my_id > 0:
		profiles[my_id] = SteamManager.get_player_profile(my_id)

	for steam_id in LobbyManager.members:
		if steam_id <= 0 or steam_id == my_id:
			continue

		profiles[steam_id] = SteamManager.get_player_profile(steam_id)

	for steam_id in _friend_rows.keys():
		if not profiles.has(steam_id):
			var old_row = _friend_rows[steam_id]
			old_row.get_parent().remove_child(old_row)
			old_row.queue_free()
			_friend_rows.erase(steam_id)

	var ordered_ids: Array = profiles.keys()
	ordered_ids.sort_custom(_friend_row_before.bind(profiles))

	var next_positions: Dictionary = {}

	for steam_id in ordered_ids:
		var profile: Dictionary = profiles[steam_id]
		var target: VBoxContainer = offline_container
		var is_me_in_party: bool = has_lobby and steam_id == my_id

		if is_me_in_party or LobbyManager.is_in_party(steam_id):
			target = party_container
		elif LobbyManager.has_pending_invite(steam_id):
			target = invite_sent_container
		elif profile.get("is_in_game", false):
			target = in_game_container
		elif profile.get("is_online", false):
			target = online_container

		if not _friend_rows.has(steam_id):
			var new_row = friend_panel_scene.instantiate()
			target.add_child(new_row)
			_friend_rows[steam_id] = new_row

		var row = _friend_rows[steam_id]

		if row.get_parent() != target:
			row.reparent(target, false)

		var position_in_section: int = int(
			next_positions.get(target, 0)
		)

		target.move_child(row, position_in_section)
		next_positions[target] = position_in_section + 1
		row.update_profile(profile)


func _friend_row_before(
	left_id: int,
	right_id: int,
	profiles: Dictionary
) -> bool:
	var left_rank: int = _friend_row_rank(left_id)
	var right_rank: int = _friend_row_rank(right_id)

	if left_rank != right_rank:
		return left_rank < right_rank

	var left_profile: Dictionary = profiles[left_id]
	var right_profile: Dictionary = profiles[right_id]
	var left_name: String = str(left_profile.get("display_name", ""))
	var right_name: String = str(right_profile.get("display_name", ""))
	var comparison: int = left_name.naturalnocasecmp_to(right_name)

	if comparison != 0:
		return comparison < 0

	return left_id < right_id


func _friend_row_rank(steam_id: int) -> int:
	if LobbyManager.lobby_id != 0:
		if steam_id == LobbyManager.owner_id:
			return 0

		if steam_id == SteamManager.my_steam_id:
			return 1

	return 2


func _clear_friend_rows() -> void:
	for row in _friend_rows.values():
		row.get_parent().remove_child(row)
		row.queue_free()

	_friend_rows.clear()


func _exit_tree() -> void:
	SteamManager.set_friends_menu_open(false)
