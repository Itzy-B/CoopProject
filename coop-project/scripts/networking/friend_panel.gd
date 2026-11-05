extends PanelContainer

enum MainAction {
	NONE,
	INVITE,
	CANCEL_INVITE,
	KICK,
	LEAVE
}

@export_group("Action Textures")
@export var invite_texture: Texture2D
@export var cancel_texture: Texture2D
@export var kick_texture: Texture2D
@export var leave_texture: Texture2D
@export var join_texture: Texture2D

@onready var main_button: TextureButton = (
	$HBoxContainer/MainActionButton
)
@onready var secondary_button: TextureButton = (
	$HBoxContainer/SecondaryActionButton
)
@onready var portrait: TextureButton = (
	$HBoxContainer/TextureButton
)
@onready var name_label: Label = (
	$HBoxContainer/VBoxContainer/Name
)
@onready var status_label: Label = (
	$HBoxContainer/VBoxContainer/Status
)

var steam_id: int = 0

var _main_action: MainAction = MainAction.NONE
var _join_available: bool = false
var _hovered: bool = false

var _placeholder_avatar: Texture2D
var _default_main_texture: Texture2D
var _default_join_texture: Texture2D


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS

	_placeholder_avatar = portrait.texture_normal
	_default_main_texture = main_button.texture_normal
	_default_join_texture = secondary_button.texture_normal

	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait.focus_mode = Control.FOCUS_NONE
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_prepare_button(main_button)
	_prepare_button(secondary_button)

	main_button.pressed.connect(_on_main_pressed)
	secondary_button.pressed.connect(_on_join_pressed)

	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()


func _prepare_button(button: TextureButton) -> void:
	button.focus_mode = Control.FOCUS_NONE
	button.toggle_mode = false
	button.texture_hover = null
	button.texture_pressed = null
	button.texture_focused = null

	# Reserve button space so the name and status don't move.
	button.show()


func update_profile(profile: Dictionary) -> void:
	steam_id = int(profile.get("steam_id", 0))

	var display_name: String = str(
		profile.get("display_name", "")
	)

	name_label.text = (
		display_name
		if not display_name.is_empty()
		else "Loading..."
	)

	var avatar: Texture2D = profile.get("avatar")

	portrait.texture_normal = (
		avatar if avatar != null else _placeholder_avatar
	)

	status_label.text = str(profile.get("status", "Unknown"))

	_main_action = MainAction.NONE
	_join_available = false
	main_button.tooltip_text = ""
	secondary_button.tooltip_text = ""

	var in_party: bool = LobbyManager.is_in_party(steam_id)
	var local_is_owner: bool = LobbyManager.is_owner()

	var is_me: bool = (
		steam_id > 0
		and steam_id == SteamManager.my_steam_id
	)

	var is_party_owner: bool = (
		LobbyManager.lobby_id != 0
		and steam_id == LobbyManager.owner_id
	)

	if is_me:
		if LobbyManager.lobby_id != 0:
			status_label.text = (
				"Party Owner" if local_is_owner else "In Party"
			)

			_set_main_action(
				MainAction.LEAVE,
				leave_texture,
				"Leave Party"
			)

	elif in_party:
		status_label.text = (
			"Party Owner" if is_party_owner else "In Party"
		)

		if local_is_owner:
			_set_main_action(
				MainAction.KICK,
				kick_texture,
				"Kick from Party"
			)

	elif LobbyManager.has_pending_invite(steam_id):
		status_label.text = "Invite Sent"

		if local_is_owner:
			_set_main_action(
				MainAction.CANCEL_INVITE,
				cancel_texture,
				"Cancel Invitation"
			)

	elif LobbyManager.can_invite():
		_set_main_action(
			MainAction.INVITE,
			invite_texture,
			"Invite to Party"
		)

	# Join is a separate action beside Invite.
	if (
		not is_me
		and not in_party
		and SteamManager.can_join_friend(steam_id)
	):
		_join_available = true

		secondary_button.texture_normal = (
			join_texture
			if join_texture != null
			else _default_join_texture
		)

		secondary_button.texture_disabled = (
			secondary_button.texture_normal
		)
		secondary_button.tooltip_text = "Join Friend's Party"

	_apply_button_visibility()


func _set_main_action(
	action: MainAction,
	texture: Texture2D,
	tooltip: String
) -> void:
	_main_action = action

	main_button.texture_normal = (
		texture if texture != null else _default_main_texture
	)
	main_button.texture_disabled = main_button.texture_normal
	main_button.tooltip_text = tooltip


func _process(_delta: float) -> void:
	# Local UI check only; no Steam requests.
	_hovered = get_global_rect().has_point(
		get_global_mouse_position()
	)

	# Also updates disabled state when a party operation starts/ends.
	_apply_button_visibility()


func _apply_button_visibility() -> void:
	var main_visible: bool = (
		_hovered and _main_action != MainAction.NONE
	)
	var join_visible: bool = _hovered and _join_available

	var can_interact: bool = (
		SteamManager.is_online()
		and not SteamManager.is_busy()
	)

	main_button.modulate.a = 1.0 if main_visible else 0.0
	secondary_button.modulate.a = 1.0 if join_visible else 0.0

	main_button.disabled = not main_visible or not can_interact
	secondary_button.disabled = not join_visible or not can_interact

	# Invisible buttons should not intercept mouse input.
	main_button.mouse_filter = (
		Control.MOUSE_FILTER_STOP
		if main_visible
		else Control.MOUSE_FILTER_IGNORE
	)
	secondary_button.mouse_filter = (
		Control.MOUSE_FILTER_STOP
		if join_visible
		else Control.MOUSE_FILTER_IGNORE
	)


func _on_visibility_changed() -> void:
	var row_visible: bool = is_visible_in_tree()
	set_process(row_visible)

	if not row_visible:
		_hovered = false

	_apply_button_visibility()


func _on_main_pressed() -> void:
	if not SteamManager.is_online() or SteamManager.is_busy():
		return

	match _main_action:
		MainAction.LEAVE:
			if (
				steam_id == SteamManager.my_steam_id
				and LobbyManager.lobby_id != 0
			):
				LobbyManager.leave_party()

		MainAction.KICK:
			if LobbyManager.can_kick(steam_id):
				LobbyManager.kick_member(steam_id)

		MainAction.CANCEL_INVITE:
			if (
				LobbyManager.is_owner()
				and LobbyManager.has_pending_invite(steam_id)
			):
				LobbyManager.cancel_invite(steam_id)

		MainAction.INVITE:
			if (
				LobbyManager.can_invite()
				and not LobbyManager.is_in_party(steam_id)
				and not LobbyManager.has_pending_invite(steam_id)
			):
				LobbyManager.invite_friend(steam_id)


func _on_join_pressed() -> void:
	if not SteamManager.is_online() or SteamManager.is_busy():
		return

	if SteamManager.can_join_friend(steam_id):
		LobbyManager.join_friend(steam_id)
