extends Node

signal transmitting_changed(active: bool, radio: bool)
signal voice_error(message: String)
signal speakers_changed
signal speaker_names_changed

# Steam handles capture/compression. Godot RPCs carry opaque compressed blobs.
# All client voice is relayed by the host; no extra P2P connections are opened.
const SAMPLE_RATE: int = 16000
const POLL_INTERVAL: float = 0.03
const MAX_PACKET_BYTES: int = 8192
const MAX_PACKETS_PER_SECOND: int = 80
const MAX_BYTES_PER_SECOND: int = 64000

@export var microphone_enabled: bool = true
@export var radio_enabled: bool = true
@export_range(0.0, 2.0, 0.05) var output_volume: float = 1.0

var _voices: Dictionary = {}
var _muted: Dictionary = {}
var _limits: Dictionary = {}
var _recording: bool = false
var _active_radio: bool = false
var _drain_until: int = 0
var _poll_elapsed: float = 0.0
var _sequence: int = 0
var _session_id: int = 0
var _last_error: String = ""
var _speakers: Dictionary = {}
var _speaker_steam_ids: Dictionary = {}
var _speaker_profile_requests: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	NetworkManager.returned_to_solo.connect(_reset_session)
	NetworkManager.player_disconnected.connect(_on_peer_disconnected)
	SteamManager.steam_stopping.connect(_reset_session)
	Steam.persona_state_change.connect(_on_speaker_persona_changed)
	for action in ["voice_proximity", "voice_radio"]:
		if not InputMap.has_action(action):
			_report_error("Add '%s' in Project Settings > Input Map." % action)


func register_player(peer_id: int, component: Node) -> void:
	_voices[peer_id] = component


func unregister_player(peer_id: int, component: Node) -> void:
	# A retiring instance must not unregister its replacement.
	if _voices.get(peer_id) == component:
		_voices.erase(peer_id)
		_limits.erase(peer_id)
		clear_speaker_activity(peer_id)
		_speaker_steam_ids.erase(peer_id)


func set_peer_muted(peer_id: int, muted: bool) -> void:
	if muted:
		_muted[peer_id] = true
	else:
		_muted.erase(peer_id)
	var voice: Node = _voices.get(peer_id)
	if is_instance_valid(voice):
		voice.call("clear_voice")


func is_peer_muted(peer_id: int) -> bool:
	return _muted.has(peer_id)


func _process(delta: float) -> void:
	_expire_speakers()
	if not NetworkManager.is_session_connected():
		if _session_id != 0 or _recording or _drain_until != 0:
			_reset_session()
		return
	var current_session: int = NetworkManager.get_session_lobby_id()
	if current_session != _session_id:
		_reset_session()
		_session_id = current_session

	var local_voice: Node = _voices.get(multiplayer.get_unique_id())
	var can_talk: bool = (
		microphone_enabled and _session_matches(current_session)
		and SteamManager.is_steam_initialized()
		and get_window().has_focus() and not SteamManager.overlay_active
		and is_instance_valid(local_voice)
	)
	if can_talk:
		can_talk = bool(local_voice.call("can_transmit"))
	var use_radio: bool = can_talk and radio_enabled and _pressed("voice_radio")
	var wanted: bool = can_talk and (use_radio or _pressed("voice_proximity"))

	if wanted and not _recording:
		# Discard the previous capture's tail before starting a new talk burst.
		_poll_voice(false)
		_drain_until = 0
		_active_radio = use_radio
		Steam.startVoiceRecording()
		Steam.setInGameVoiceSpeaking(SteamManager.my_steam_id, true)
		_recording = true
		_set_speaker_activity(multiplayer.get_unique_id(), _active_radio, -1)
		transmitting_changed.emit(true, _active_radio)
	elif wanted and _active_radio != use_radio:
		_poll_voice(true)
		_active_radio = use_radio
		_set_speaker_activity(multiplayer.get_unique_id(), _active_radio, -1)
		transmitting_changed.emit(true, _active_radio)
	elif not wanted and _recording:
		_stop_recording()

	_poll_elapsed += delta
	if _poll_elapsed >= POLL_INTERVAL:
		_poll_elapsed = fmod(_poll_elapsed, POLL_INTERVAL)
		if _recording or Time.get_ticks_msec() < _drain_until:
			# Loss of focus, loading, mute, or an open menu discards the tail.
			_poll_voice(can_talk)
		elif _drain_until != 0:
			_drain_until = 0


func _pressed(action: StringName) -> bool:
	return InputMap.has_action(action) and Input.is_action_pressed(action)


func _stop_recording() -> void:
	if not _recording:
		return
	if SteamManager.is_steam_initialized():
		Steam.stopVoiceRecording()
		Steam.setInGameVoiceSpeaking(SteamManager.my_steam_id, false)
	_recording = false
	# Steam may return final encoded audio after StopVoiceRecording.
	_drain_until = Time.get_ticks_msec() + 1000
	clear_speaker_activity(multiplayer.get_unique_id())
	transmitting_changed.emit(false, _active_radio)


func _poll_voice(send_audio: bool) -> void:
	if not SteamManager.is_steam_initialized():
		return
	var available: Dictionary = Steam.getAvailableVoice()
	var result: int = int(available.get("result", -1))
	if result == Steam.VOICE_RESULT_NOT_RECORDING:
		_drain_until = 0
		return
	if result == Steam.VOICE_RESULT_NO_DATA:
		return
	if result != Steam.VOICE_RESULT_OK:
		_report_error("Steam microphone capture failed (code %d). Check your Steam microphone settings." % result)
		return
	var size: int = int(available.get("size", 0))
	if size <= 0:
		return
	# Drain stale audio after a long stall rather than send a delayed backlog.
	var captured: Dictionary = Steam.getVoice(clampi(size, 1024, 65536))
	if int(captured.get("result", -1)) != Steam.VOICE_RESULT_OK:
		return
	var compressed: PackedByteArray = captured.get("buffer", PackedByteArray())
	if not send_audio or compressed.is_empty() or compressed.size() > MAX_PACKET_BYTES:
		return
	if not _session_matches(_session_id):
		return
	_sequence += 1
	if NetworkManager.is_hosting():
		_relay_voice(multiplayer.get_unique_id(), _sequence, _active_radio, compressed)
	elif multiplayer.get_peers().has(1):
		_submit_voice.rpc_id(1, _session_id, _sequence, _active_radio, compressed)


@rpc("any_peer", "call_remote", "unreliable", 0)
func _submit_voice(lobby_id: int, sequence: int, radio: bool, data: PackedByteArray) -> void:
	if not NetworkManager.is_hosting() or not _session_matches(lobby_id):
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if not multiplayer.get_peers().has(sender) or not _voices.has(sender):
		return
	if not _accept_packet(sender, sequence, data):
		return
	_relay_voice(sender, sequence, radio, data)


func _relay_voice(sender: int, sequence: int, radio: bool, data: PackedByteArray) -> void:
	_deliver_voice(sender, sequence, radio, data)
	for peer_id in multiplayer.get_peers():
		if peer_id != sender and _session_matches(_session_id):
			_receive_voice.rpc_id(peer_id, _session_id, sender, sequence, radio, data)


@rpc("authority", "call_remote", "unreliable", 0)
func _receive_voice(lobby_id: int, sender: int, sequence: int, radio: bool, data: PackedByteArray) -> void:
	if multiplayer.get_remote_sender_id() != 1 or not _session_matches(lobby_id):
		return
	if not _accept_packet(sender, sequence, data):
		return
	_deliver_voice(sender, sequence, radio, data)


func _accept_packet(sender: int, sequence: int, data: PackedByteArray) -> bool:
	if sequence <= 0 or data.is_empty() or data.size() > MAX_PACKET_BYTES:
		return false
	var now: int = Time.get_ticks_msec()
	var budget: Dictionary = _limits.get(sender, {"start": now, "packets": 0, "bytes": 0})
	if now - int(budget["start"]) >= 1000:
		budget = {"start": now, "packets": 0, "bytes": 0}
	budget["packets"] = int(budget["packets"]) + 1
	budget["bytes"] = int(budget["bytes"]) + data.size()
	_limits[sender] = budget
	return int(budget["packets"]) <= MAX_PACKETS_PER_SECOND and int(budget["bytes"]) <= MAX_BYTES_PER_SECOND


func _deliver_voice(sender: int, sequence: int, radio: bool, data: PackedByteArray) -> void:
	if sender == multiplayer.get_unique_id() or is_peer_muted(sender):
		return
	if radio and not radio_enabled:
		return
	var voice: Node = _voices.get(sender)
	if is_instance_valid(voice):
		voice.call("receive_voice", sequence, radio, data)


func _session_matches(lobby_id: int) -> bool:
	return (
		lobby_id != 0 and NetworkManager.is_session_connected()
		and NetworkManager.get_session_lobby_id() == lobby_id
		and LobbyManager.lobby_id == lobby_id and not LobbyManager.is_joining_party()
	)


func _on_peer_disconnected(peer_id: int) -> void:
	var voice: Node = _voices.get(peer_id)
	if is_instance_valid(voice):
		voice.call("clear_voice")
	_voices.erase(peer_id)
	_limits.erase(peer_id)
	_muted.erase(peer_id)
	clear_speaker_activity(peer_id)
	_speaker_steam_ids.erase(peer_id)


func _reset_session() -> void:
	_stop_recording()
	_drain_until = 0
	_poll_elapsed = 0.0
	_session_id = 0
	_sequence = 0
	_limits.clear()
	_muted.clear()
	_speaker_steam_ids.clear()
	_speaker_profile_requests.clear()
	if not _speakers.is_empty():
		_speakers.clear()
		speakers_changed.emit()
	# Keep registrations: session_ready may have just spawned replacements.
	for voice in _voices.values():
		if is_instance_valid(voice):
			voice.call("clear_voice")


func _report_error(message: String) -> void:
	if message == _last_error:
		return
	_last_error = message
	voice_error.emit(message)
	push_warning(message)


func _exit_tree() -> void:
	_stop_recording()


# Called when a remote component actually feeds playable voice frames.
func note_voice_playback(peer_id: int, radio: bool, seconds_queued: float) -> void:
	if not _session_matches(_session_id) or not _voices.has(peer_id):
		return
	if is_peer_muted(peer_id) or output_volume <= 0.0 or (radio and not radio_enabled):
		clear_speaker_activity(peer_id)
		return
	var expires: int = Time.get_ticks_msec() + int(maxf(seconds_queued, 0.0) * 1000.0) + 220
	_set_speaker_activity(peer_id, radio, expires)


func _set_speaker_activity(peer_id: int, radio: bool, expires: int) -> void:
	var changed: bool = not _speakers.has(peer_id)
	if not changed:
		changed = bool(_speakers[peer_id]["radio"]) != radio
	_speakers[peer_id] = {"radio": radio, "expires": expires}
	if changed:
		speakers_changed.emit()


# mode: -1 = either, 0 = proximity, 1 = radio.
func clear_speaker_activity(peer_id: int, mode: int = -1) -> void:
	if not _speakers.has(peer_id):
		return
	if mode >= 0 and bool(_speakers[peer_id]["radio"]) != (mode == 1):
		return
	_speakers.erase(peer_id)
	speakers_changed.emit()


func _expire_speakers() -> void:
	var now: int = Time.get_ticks_msec()
	for peer_id in _speakers.keys():
		var expires: int = int(_speakers[peer_id]["expires"])
		if expires >= 0 and now >= expires:
			clear_speaker_activity(int(peer_id))


func get_active_speakers() -> Dictionary:
	return _speakers.duplicate(true)


func get_speaker_name(peer_id: int) -> String:
	if peer_id == multiplayer.get_unique_id():
		return SteamManager.my_name if not SteamManager.my_name.is_empty() else "You"
	if not SteamManager.is_steam_initialized():
		return "Player %d" % peer_id
	var steam_id: int = int(_speaker_steam_ids.get(peer_id, 0))
	if steam_id == 0:
		var peer: MultiplayerPeer = multiplayer.multiplayer_peer
		if peer != null and peer.has_method("get_steam_id_for_peer_id"):
			steam_id = int(peer.call("get_steam_id_for_peer_id", peer_id))
		elif peer != null and peer.has_method("get_steam64_from_peer_id"):
			steam_id = int(peer.call("get_steam64_from_peer_id", peer_id))
		if steam_id > 0:
			_speaker_steam_ids[peer_id] = steam_id
	if steam_id <= 0:
		return "Player %d" % peer_id
	if not _speaker_profile_requests.has(steam_id):
		_speaker_profile_requests[steam_id] = true
		Steam.requestUserInformation(steam_id, true)
	var display_name: String = Steam.getFriendPersonaName(steam_id)
	if not display_name.is_empty() and display_name != "[unknown]":
		return display_name
	return "Steam player"


func _on_speaker_persona_changed(steam_id: int, _flags: int) -> void:
	if steam_id == SteamManager.my_steam_id or _speaker_steam_ids.values().has(steam_id):
		speaker_names_changed.emit()
