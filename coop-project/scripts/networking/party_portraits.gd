extends HBoxContainer

@export var locked_texture: Texture2D
@export var unlocked_texture: Texture2D

@onready var my_portrait: TextureButton = $MeVBoxContainer/MePortrait
@onready var my_name_label: Label = $MeVBoxContainer/NameClip/MeLabel

@onready var settings_button: TextureButton = (
	$LobbySettingsVBoxContainer/LobbySettingsTextureButton
)
@onready var settings_label: Label = (
	$LobbySettingsVBoxContainer/LobbySettingsLabel
)

@onready var portraits: Array[TextureButton] = [
	$Player1VBoxContainer/Player1Portrait,
	$Player2VBoxContainer/Player2Portrait,
	$Player3VBoxContainer/Player3Portrait
]

@onready var name_labels: Array[Label] = [
	$Player1VBoxContainer/NameClip/Player1Label,
	$Player2VBoxContainer/NameClip/Player2Label,
	$Player3VBoxContainer/NameClip/Player3Label
]

var _my_placeholder: Texture2D
var _placeholder_textures: Array[Texture2D] = []
var _slot_ids: Array[int] = [0, 0, 0]
var _refresh_queued: bool = false


func _ready() -> void:
	_my_placeholder = my_portrait.texture_normal
	_prepare_owner_decoration(my_portrait)

	if locked_texture == null:
		locked_texture = settings_button.texture_normal

	settings_button.texture_hover = null
	settings_button.texture_pressed = null
	settings_button.texture_focused = null
	settings_button.pressed.connect(_on_settings_pressed)

	for index in range(portraits.size()):
		_placeholder_textures.append(
			portraits[index].texture_normal
		)

		_prepare_owner_decoration(portraits[index])

		portraits[index].pressed.connect(
			_on_portrait_pressed.bind(index)
		)

	LobbyManager.party_changed.connect(_queue_refresh)
	LobbyManager.invitations_changed.connect(_queue_refresh)
	LobbyManager.privacy_changed.connect(_queue_refresh)

	SteamManager.friends_changed.connect(_queue_refresh)
	SteamManager.my_profile_changed.connect(_queue_refresh)
	
	visibility_changed.connect(_on_visibility_changed)
	
	_refresh()


func _queue_refresh() -> void:
	if not is_visible_in_tree() or _refresh_queued:
		return

	_refresh_queued = true
	call_deferred("_refresh")


func _refresh() -> void:
	_refresh_queued = false

	if not is_visible_in_tree():
		return

	# Local player always stays in the Me slot.
	my_name_label.text = SteamManager.my_name
	my_portrait.tooltip_text = SteamManager.my_name
	my_portrait.texture_normal = (
		SteamManager.my_avatar
		if SteamManager.my_avatar != null
		else _my_placeholder
	)

	var teammates: Array[int] = []

	for steam_id in LobbyManager.members:
		if steam_id != SteamManager.my_steam_id:
			teammates.append(steam_id)

	# Clear slots belonging to players who left.
	for index in range(_slot_ids.size()):
		if not teammates.has(_slot_ids[index]):
			_slot_ids[index] = 0

	# Keep existing teammates in their current slots.
	for steam_id in teammates:
		if _slot_ids.has(steam_id):
			continue

		var empty_index: int = _slot_ids.find(0)

		if empty_index != -1:
			_slot_ids[empty_index] = steam_id

	for index in range(portraits.size()):
		var steam_id: int = _slot_ids[index]
		var portrait: TextureButton = portraits[index]

		portrait.texture_normal = _placeholder_textures[index]

		if steam_id == 0:
			name_labels[index].text = "Invite Friend"
			portrait.tooltip_text = "Open Steam Friends"
			continue

		var profile: Dictionary = SteamManager.get_player_profile(
			steam_id
		)

		var display_name: String = profile.get("display_name", "")

		if display_name.is_empty() or display_name == "[unknown]":
			display_name = "Loading..."

		name_labels[index].text = display_name
		portrait.tooltip_text = display_name

		var avatar: Texture2D = profile.get("avatar")

		if avatar != null:
			portrait.texture_normal = avatar

	_update_owner_portraits()
	_update_settings_button()


func _on_portrait_pressed(index: int) -> void:
	if _slot_ids[index] == 0:
		SteamManager.open_friends_overlay()


func _on_settings_pressed() -> void:
	LobbyManager.set_invite_only(
		not LobbyManager.invite_only
	)


func _update_settings_button() -> void:
	var icon: Texture2D = (
		locked_texture
		if LobbyManager.invite_only
		else unlocked_texture
	)

	settings_button.texture_normal = icon
	settings_button.texture_disabled = icon

	settings_label.text = (
		"Invite Only"
		if LobbyManager.invite_only
		else "Open"
	)

	var can_change: bool = (
		not LobbyManager.is_busy()
		and (
			LobbyManager.lobby_id == 0
			or LobbyManager.is_owner()
		)
	)

	settings_button.disabled = not can_change

	if not can_change:
		settings_button.tooltip_text = (
			"Only the owner can change party privacy"
		)
	elif LobbyManager.invite_only:
		settings_button.tooltip_text = "Click to allow friends and party code joining"
	else:
		settings_button.tooltip_text = "Click to make invite only"


func _prepare_owner_decoration(
	portrait: TextureButton
) -> void:
	portrait.clip_contents = false

	var outline: Panel = portrait.get_node("OwnerOutline") as Panel
	outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outline.clip_contents = false

	var crown: TextureRect = outline.get_node("Crown") as TextureRect
	crown.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _update_owner_portraits() -> void:
	var has_owner: bool = (
		LobbyManager.lobby_id != 0
		and LobbyManager.owner_id != 0
		and LobbyManager.is_in_party(LobbyManager.owner_id)
	)

	_set_owner_outline(
		my_portrait,
		has_owner
		and LobbyManager.owner_id == SteamManager.my_steam_id
	)

	for index in range(portraits.size()):
		_set_owner_outline(
			portraits[index],
			has_owner
			and _slot_ids[index] == LobbyManager.owner_id
		)


func _set_owner_outline(
	portrait: TextureButton,
	show_outline: bool
) -> void:
	var outline: Panel = portrait.get_node("OwnerOutline") as Panel
	outline.visible = show_outline

	var crown: TextureRect = outline.get_node("Crown") as TextureRect
	crown.visible = show_outline

func _on_visibility_changed() -> void:
	if is_visible_in_tree():
		_queue_refresh()
