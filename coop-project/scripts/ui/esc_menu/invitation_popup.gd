extends CanvasLayer

@export var invitation_lifetime_seconds: float = 60.0
@export var metadata_timeout_seconds: float = 10.0
@export var maximum_queued_invitations: int = 8
@export var placeholder_avatar: Texture2D

@export_group("Popup Animation")
enum SlideSide { LEFT, RIGHT }
@export var slide_side: SlideSide = SlideSide.LEFT
@export_range(0.01, 2.0, 0.01) var slide_seconds: float = 0.25

@onready var panel: PanelContainer = $Root/Panel
@onready var avatar: TextureRect = $Root/Panel/Margin/Content/Profile/Avatar
@onready var inviter_label: Label = $Root/Panel/Margin/Content/Profile/Text/Inviter
@onready var detail_label: Label = $Root/Panel/Margin/Content/Profile/Text/Details
@onready var expires_label: Label = $Root/Panel/Margin/Content/Expires
@onready var accept_button: Button = $Root/Panel/Margin/Content/Actions/Accept
@onready var refuse_button: Button = $Root/Panel/Margin/Content/Actions/Refuse

# Lobby ID -> inviter, expiry and validation state. Entries are local UI state.
var _invitations: Dictionary = {}
var _shown_lobby: int = 0
var _pending_accept: int = 0
var _panel_open: bool = false
var _slide_tween: Tween
var _slide_offset: float = 0.0
var _avatar_requests: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	panel.hide()
	if placeholder_avatar == null:
		placeholder_avatar = avatar.texture
	SteamManager.friends_changed.connect(_update_inviter_avatar)
	accept_button.focus_mode = Control.FOCUS_NONE
	refuse_button.focus_mode = Control.FOCUS_NONE
	accept_button.pressed.connect(_accept_current)
	refuse_button.pressed.connect(_refuse_current)

	if not Steam.has_signal("lobby_invite"):
		push_error("InvitationPopup: this Steam build does not expose lobby_invite.")
		set_process(false)
		return

	Steam.connect("lobby_invite", _on_lobby_invite)
	Steam.lobby_data_update.connect(_on_lobby_data_update)
	Steam.persona_state_change.connect(_on_persona_state_change)
	SteamManager.online_state_changed.connect(_on_online_state_changed)


func _on_lobby_invite(inviter_id: int, target_lobby: int, game_id: int) -> void:
	if not SteamManager.is_online():
		return
	if game_id != Steam.getAppID():
		return
	if inviter_id <= 0 or inviter_id == SteamManager.my_steam_id:
		return
	if target_lobby <= 0 or target_lobby == LobbyManager.lobby_id:
		return
	if target_lobby == _pending_accept:
		return

	if not _invitations.has(target_lobby):
		if _invitations.size() >= maxi(maximum_queued_invitations, 1):
			# Do not evict the entry currently being accepted.
			for old_key in _invitations.keys():
				var old_lobby: int = int(old_key)
				if old_lobby != _pending_accept:
					_invitations.erase(old_lobby)
					break

	var now: int = Time.get_ticks_msec()
	_invitations[target_lobby] = {
		"inviter_id": inviter_id,
		"expires_at": now + int(maxf(invitation_lifetime_seconds, 5.0) * 1000.0),
		"validated": false,
		"requested_at": now
	}
	# Distinguish this project from other projects using development AppID 480.
	if not Steam.requestLobbyData(target_lobby):
		_invitations.erase(target_lobby)
	_refresh_popup()


func _on_lobby_data_update(success: int, changed_lobby: int, member_id: int) -> void:
	if not _invitations.has(changed_lobby) or not SteamManager.is_online():
		return
	if success != 0 and member_id != changed_lobby:
		return

	var error: String = "This invitation is no longer available."
	if success != 0:
		error = _invitation_error(changed_lobby)
	if not error.is_empty():
		var was_accepting: bool = _pending_accept == changed_lobby
		_remove_invitation(changed_lobby)
		if was_accepting:
			LobbyManager.operation_failed.emit(error)
			_open_menu_for_error()
		_refresh_popup()
		return

	var invitation: Dictionary = _invitations[changed_lobby]
	invitation["validated"] = true
	invitation["requested_at"] = 0

	if _pending_accept == changed_lobby:
		# Keep the existing party if another operation started while checking.
		if _join_is_busy():
			_pending_accept = 0
			_refresh_popup()
			return
		_remove_invitation(changed_lobby)
		_hide_popup(false)
		# This emits the signals already used by ConnectionLoading.
		LobbyManager.join_party(changed_lobby)
		return

	_refresh_popup()


func _invitation_error(target_lobby: int) -> String:
	if Steam.getLobbyData(target_lobby, LobbyManager.PARTY_GAME_KEY) != LobbyManager.GAME_IDENTIFIER:
		return "This invitation belongs to another game or build."
	if Steam.getLobbyData(target_lobby, LobbyManager.PARTY_APP_KEY) != str(Steam.getAppID()):
		return "This invitation belongs to another game."
	var access: String = Steam.getLobbyData(
		target_lobby, LobbyManager.ACCESS_PREFIX + str(SteamManager.my_steam_id)
	)
	if access == "kicked" or access == "cancelled":
		return "This invitation was cancelled. Ask the host for another invite."
	if access != "allowed":
		return "This invitation is no longer valid."
	return ""


func _process(_delta: float) -> void:
	if _invitations.is_empty():
		return
	var now: int = Time.get_ticks_msec()
	for key in _invitations.keys():
		var target_lobby: int = int(key)
		var invitation: Dictionary = _invitations[target_lobby]
		var requested_at: int = int(invitation["requested_at"])
		var expired: bool = now >= int(invitation["expires_at"])
		var timed_out: bool = (
			requested_at != 0
			and now - requested_at >= int(maxf(metadata_timeout_seconds, 1.0) * 1000.0)
		)
		if expired or timed_out or target_lobby == LobbyManager.lobby_id:
			var was_accepting: bool = _pending_accept == target_lobby
			_remove_invitation(target_lobby)
			if was_accepting and (expired or timed_out):
				LobbyManager.operation_failed.emit("Invitation check timed out. Please ask for another invite.")
				_open_menu_for_error()
	_refresh_popup()


func _accept_current() -> void:
	if _shown_lobby == 0 or _pending_accept != 0 or _join_is_busy():
		return
	if not SteamManager.is_online() or not _invitations.has(_shown_lobby):
		return
	var invitation: Dictionary = _invitations[_shown_lobby]
	if Time.get_ticks_msec() >= int(invitation["expires_at"]):
		_remove_invitation(_shown_lobby)
		_refresh_popup()
		return

	_pending_accept = _shown_lobby
	invitation["requested_at"] = Time.get_ticks_msec()
	# Refresh immediately before joining: privacy/access may have changed.
	if not Steam.requestLobbyData(_pending_accept):
		_remove_invitation(_pending_accept)
		LobbyManager.operation_failed.emit("Steam could not check the invitation. Please try again.")
		_open_menu_for_error()
	_refresh_popup()


func _refuse_current() -> void:
	if _shown_lobby != 0:
		# Dismiss locally. This never joins or leaves a party.
		_remove_invitation(_shown_lobby)
		_refresh_popup()


func _remove_invitation(target_lobby: int) -> void:
	_invitations.erase(target_lobby)
	if _pending_accept == target_lobby:
		_pending_accept = 0


func _refresh_popup() -> void:
	if not SteamManager.is_online() or _join_is_busy():
		_hide_popup(false)
		return

	var next_lobby: int = 0
	for key in _invitations:
		var invitation: Dictionary = _invitations[key]
		if bool(invitation["validated"]):
			next_lobby = int(key)
			break
	if next_lobby == 0:
		_hide_popup(true)
		return

	if next_lobby != _shown_lobby:
		_shown_lobby = next_lobby
		_update_inviter_name()
	var checking: bool = _pending_accept != 0
	accept_button.disabled = checking
	var detail: String = "Invited you to their party."
	if checking:
		detail = "Checking invitation..."
	elif LobbyManager.lobby_id != 0:
		detail = "Invited you to their party. Accepting leaves your current party."
	detail_label.text = detail
	var current: Dictionary = _invitations[_shown_lobby]
	var remaining: int = maxi(0, ceili(float(int(current["expires_at"]) - Time.get_ticks_msec()) / 1000.0))
	expires_label.text = "Expires in %ds • %d pending" % [remaining, _invitations.size()]
	_show_popup()


func _join_is_busy() -> bool:
	if LobbyManager.is_busy() or NetworkManager.is_connecting():
		return true
	var loading: Node = get_tree().get_first_node_in_group("connection_loading_ui")
	return loading != null and bool(loading.call("is_loading"))


func _update_inviter_name() -> void:
	if not _invitations.has(_shown_lobby):
		return
	var invitation: Dictionary = _invitations[_shown_lobby]
	var display_name: String = Steam.getFriendPersonaName(int(invitation["inviter_id"]))
	inviter_label.text = display_name if not display_name.is_empty() else "Steam player"
	_update_inviter_avatar()


func _update_inviter_avatar() -> void:
	if not SteamManager.is_online() or not _invitations.has(_shown_lobby):
		return
	var invitation: Dictionary = _invitations[_shown_lobby]
	var steam_id: int = int(invitation["inviter_id"])
	# Reuse SteamManager's avatar cache and avatar_loaded handling.
	var profile: Dictionary = SteamManager.get_player_profile(steam_id)
	var texture: Texture2D = profile.get("avatar")
	avatar.texture = texture if texture != null else placeholder_avatar
	if texture != null:
		return
	var now: int = Time.get_ticks_msec()
	if now - int(_avatar_requests.get(steam_id, -10000)) < 10000:
		return
	_avatar_requests[steam_id] = now
	# This also works when the friends menu has never been opened.
	Steam.getPlayerAvatar(2, steam_id)


func _on_persona_state_change(steam_id: int, _flags: int) -> void:
	if _invitations.has(_shown_lobby):
		var invitation: Dictionary = _invitations[_shown_lobby]
		if steam_id == int(invitation["inviter_id"]):
			_update_inviter_name()


func _input(event: InputEvent) -> void:
	if not _panel_open or _join_is_busy() or SteamManager.overlay_active:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F6:
			_accept_current()
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_F7:
			_refuse_current()
			get_viewport().set_input_as_handled()


func _offscreen_slide_offset() -> float:
	# Measure the existing layout. Never set size, anchors or resting offsets.
	var rect: Rect2 = panel.get_global_rect()
	if slide_side == SlideSide.LEFT:
		return -rect.end.x - 1.0
	return get_viewport().get_visible_rect().size.x - rect.position.x + 1.0


func _set_slide_offset(value: float) -> void:
	# Move this CanvasLayer visually. The parent container retains exclusive
	# control of the panel's position and size.
	offset.x += value - _slide_offset
	_slide_offset = value


func _show_popup() -> void:
	if _panel_open:
		return
	_panel_open = true
	if _slide_tween != null:
		_slide_tween.kill()
	_set_slide_offset(0.0)
	var hidden_offset: float = _offscreen_slide_offset()
	_set_slide_offset(hidden_offset)
	panel.show()
	_slide_tween = create_tween()
	_slide_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_slide_tween.tween_method(
		_set_slide_offset, hidden_offset, 0.0, maxf(slide_seconds, 0.01)
	)


func _hide_popup(animate: bool) -> void:
	_shown_lobby = 0
	if not _panel_open:
		if not animate:
			if _slide_tween != null:
				_slide_tween.kill()
			panel.hide()
			_set_slide_offset(0.0)
		return
	_panel_open = false
	if _slide_tween != null:
		_slide_tween.kill()
	if not animate:
		panel.hide()
		_set_slide_offset(0.0)
		return
	# Measure from the resting position, including if the entry was interrupted.
	var current_offset: float = _slide_offset
	_set_slide_offset(0.0)
	var hidden_offset: float = _offscreen_slide_offset()
	_set_slide_offset(current_offset)
	_slide_tween = create_tween()
	_slide_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_slide_tween.tween_method(
		_set_slide_offset, current_offset, hidden_offset, maxf(slide_seconds, 0.01)
	)
	_slide_tween.tween_callback(_finish_hiding_popup)


func _finish_hiding_popup() -> void:
	panel.hide()
	_set_slide_offset(0.0)


func _on_online_state_changed() -> void:
	if not SteamManager.is_online():
		_invitations.clear()
		_avatar_requests.clear()
		_pending_accept = 0
		_hide_popup(false)


func _open_menu_for_error() -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var menu: Node = scene.get_node_or_null("CanvasLayer/EscMenu")
	if menu != null and menu.has_method("set_menu_open"):
		menu.call("set_menu_open", true)
