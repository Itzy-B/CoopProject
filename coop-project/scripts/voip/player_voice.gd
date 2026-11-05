extends Node3D

@export_group("Playback Nodes")
@export var proximity_player: AudioStreamPlayer3D
@export var radio_player: AudioStreamPlayer

@export_group("Voice Buffer")
@export_range(0.04, 0.20, 0.01) var prebuffer_seconds: float = 0.08
@export_range(0.04, 0.20, 0.01) var reorder_wait_seconds: float = 0.08
@export_range(0.20, 0.80, 0.05) var maximum_queue_seconds: float = 0.40

const SAMPLE_RATE: int = 16000
const MAX_PENDING_PACKETS: int = 32
const MAX_DECODED_BYTES: int = 64000

var _player: Node
var _listener: AudioListener3D
var _peer_id: int = 0
var _registered: bool = false
var _proximity: AudioStreamPlayer3D
var _radio: AudioStreamPlayer
var _outputs: Array[Dictionary] = []
var _pending: Dictionary = {}
var _next_sequence: int = -1
var _last_packet_ms: int = 0
var _gap_started_ms: int = 0
var _last_radio: bool = false
var _in_proximity_range: bool = true
var _proximity_base_db: float = 0.0
var _radio_base_db: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = get_parent()
	call_deferred("_register")


func _register() -> void:
	if not is_instance_valid(_player) or not _player.has_method("is_local_player"):
		push_error("PlayerVoice must be a direct child of your Player.")
		return
	# Deferred registration runs after the Player has established local ownership.
	# Only this client's character may own the viewport's listening position.
	if bool(_player.call("is_local_player")):
		_listener = AudioListener3D.new()
		_listener.name = "CharacterAudioListener"
		add_child(_listener)
		_update_listener()
		_listener.make_current()
	if not bool(_player.get("networked")):
		set_process(is_instance_valid(_listener))
		return
	_peer_id = int(_player.get("controlling_peer_id"))
	if not _validate_outputs():
		set_process(is_instance_valid(_listener))
		return
	_proximity = proximity_player
	_radio = radio_player
	_proximity_base_db = _proximity.volume_db
	_radio_base_db = _radio.volume_db
	# These nodes also exist on our local character, which must stay silent.
	_proximity.stop()
	_radio.stop()
	if not bool(_player.call("is_local_player")):
		if not _bind_outputs():
			set_process(false)
			return
	VoiceManager.register_player(_peer_id, self)
	_registered = true


func can_transmit() -> bool:
	return (
		_registered and is_instance_valid(_player)
		and bool(_player.call("is_local_player"))
		and not bool(_player.call("_controls_blocked"))
	)


func _validate_outputs() -> bool:
	if proximity_player == null or radio_player == null:
		push_error("PlayerVoice: assign Proximity Player and Radio Player in the Inspector.")
		return false
	for output in [proximity_player, radio_player]:
		var generator: AudioStreamGenerator = output.stream as AudioStreamGenerator
		if generator == null:
			push_error("PlayerVoice: both audio players need an AudioStreamGenerator.")
			return false
		if not is_equal_approx(generator.mix_rate, float(SAMPLE_RATE)):
			push_error("PlayerVoice: set both generators' Mix Rate to 16000 Hz.")
			return false
		# Newer Godot versions can select an input/output rate instead of custom.
		if generator.has_method("get_mix_rate_mode"):
			if int(generator.call("get_mix_rate_mode")) != 2:
				push_error("PlayerVoice: set both generators' Mix Rate Mode to Custom.")
				return false
		if generator.buffer_length < 0.08:
			push_error("PlayerVoice: generator Buffer Length must be at least 0.08 seconds; use 0.20.")
			return false
	return true


func _bind_outputs() -> bool:
	# Nodes, streams, bus routing, attenuation and volumes come from the scene.
	for output in [_proximity, _radio]:
		output.play()
		var playback: AudioStreamGeneratorPlayback = output.get_stream_playback() as AudioStreamGeneratorPlayback
		if playback == null:
			push_error("PlayerVoice: could not start the assigned generator playback.")
			return false
		_outputs.append({"player": output, "playback": playback, "capacity": playback.get_frames_available(), "frames": PackedVector2Array(), "offset": 0, "started": false, "first_ms": 0, "last_ms": 0})
	return true


func receive_voice(sequence: int, radio: bool, data: PackedByteArray) -> void:
	if _outputs.is_empty() or sequence <= 0:
		return
	if sequence < _next_sequence:
		return
	var now: int = Time.get_ticks_msec()
	# A long silence starts a new talk burst; late packets otherwise expire.
	if _next_sequence < 0 or now - _last_packet_ms > 1500:
		_pending.clear()
		_next_sequence = sequence
		_gap_started_ms = 0
	if sequence < _next_sequence or _pending.has(sequence):
		return
	if _pending.size() >= MAX_PENDING_PACKETS:
		return
	_last_packet_ms = now
	_pending[sequence] = {"radio": radio, "data": data}


func _process(_delta: float) -> void:
	_update_listener()
	if _outputs.is_empty():
		return
	if not NetworkManager.is_session_connected():
		clear_voice()
		return
	# Match Godot's actual 3D audio listener, not the overhead camera.
	var listener: AudioListener3D = get_viewport().get_audio_listener_3d()
	var in_range: bool = false
	if listener != null:
		in_range = (
			_proximity.max_distance <= 0.0
			or listener.get_listener_transform().origin.distance_to(
				_proximity.global_position
			) < _proximity.max_distance
		)
	if not in_range and _in_proximity_range:
		_clear_output(_outputs[0])
	_in_proximity_range = in_range
	var now: int = Time.get_ticks_msec()
	# Small reordering window, then skip missing packets rather than wait forever.
	for _step in range(MAX_PENDING_PACKETS):
		if _pending.is_empty():
			break
		if not _pending.has(_next_sequence):
			if _gap_started_ms == 0:
				_gap_started_ms = now
			if now - _gap_started_ms < int(reorder_wait_seconds * 1000.0):
				break
			var keys: Array = _pending.keys()
			keys.sort()
			_next_sequence = int(keys[0])
		var packet: Dictionary = _pending[_next_sequence]
		_pending.erase(_next_sequence)
		_next_sequence += 1
		_gap_started_ms = 0
		_decode_packet(packet, now)
	if _in_proximity_range:
		_feed_output(_outputs[0], now)
	_feed_output(_outputs[1], now)
	var gain: float = VoiceManager.output_volume
	_proximity.volume_db = _proximity_base_db + linear_to_db(maxf(gain, 0.0001))
	_radio.volume_db = _radio_base_db + linear_to_db(maxf(gain, 0.0001))


func _update_listener() -> void:
	if not is_instance_valid(_listener):
		return
	# Hear from the character. Use camera yaw for stable screen-left/right
	# panning, so moving the aiming cursor does not spin the sound field.
	var listener_basis: Basis = Basis.IDENTITY
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera != null:
		var camera_back: Vector3 = camera.global_basis.z
		camera_back.y = 0.0
		if camera_back.length_squared() > 0.0001:
			listener_basis = Basis(Vector3.UP, atan2(camera_back.x, camera_back.z))
	_listener.global_transform = Transform3D(listener_basis, global_position)


func _decode_packet(packet: Dictionary, now: int) -> void:
	if not SteamManager.is_steam_initialized():
		return
	if not bool(packet["radio"]) and not _in_proximity_range:
		return
	var compressed: PackedByteArray = packet["data"]
	var decoded: Dictionary = Steam.decompressVoice(compressed, SAMPLE_RATE, MAX_DECODED_BYTES)
	if int(decoded.get("result", -1)) != Steam.VOICE_RESULT_OK:
		return
	var pcm: PackedByteArray = decoded.get("uncompressed", PackedByteArray())
	# GodotSteam returns the allocated buffer, not necessarily its written size.
	var written: int = mini(int(decoded.get("size", 0)), pcm.size())
	if written < 2:
		return
	var radio: bool = bool(packet["radio"])
	if radio != _last_radio:
		# Switching mode should not play a backlog on both outputs.
		for output in _outputs:
			_clear_output(output)
		_last_radio = radio
	var target: Dictionary = _outputs[1 if radio else 0]
	var frames: PackedVector2Array = target["frames"]
	var offset: int = int(target["offset"])
	if offset > 0:
		frames = frames.slice(offset)
		target["offset"] = 0
	var count: int = written >> 1
	if count > int(maximum_queue_seconds * SAMPLE_RATE):
		return
	if frames.size() + count > int(maximum_queue_seconds * SAMPLE_RATE):
		_clear_output(target)
		frames = PackedVector2Array()
	if frames.is_empty():
		target["first_ms"] = now
	var start: int = frames.size()
	frames.resize(start + count)
	for index in range(count):
		var sample: float = float(pcm.decode_s16(index * 2)) / 32768.0
		frames[start + index] = Vector2(sample, sample)
	target["frames"] = frames
	target["last_ms"] = now


func _feed_output(output: Dictionary, now: int) -> void:
	var frames: PackedVector2Array = output["frames"]
	var offset: int = int(output["offset"])
	var remaining: int = frames.size() - offset
	if remaining <= 0:
		if now - int(output["last_ms"]) > 250:
			output["started"] = false
		return
	if not bool(output["started"]):
		if remaining < int(prebuffer_seconds * SAMPLE_RATE) and now - int(output["first_ms"]) < int(prebuffer_seconds * 1000.0):
			return
		output["started"] = true
	var playback: AudioStreamGeneratorPlayback = output["playback"]
	# Fill only a short horizon, not the generator's entire capacity.
	var queued: int = int(output["capacity"]) - playback.get_frames_available()
	var count: int = mini(remaining, maxi(0, int(0.06 * SAMPLE_RATE) - queued))
	if count > 0:
		if playback.push_buffer(frames.slice(offset, offset + count)):
			output["offset"] = offset + count
			VoiceManager.note_voice_playback(_peer_id, output["player"] == _radio, float(queued + count) / SAMPLE_RATE)


func _clear_output(output: Dictionary) -> void:
	VoiceManager.clear_speaker_activity(_peer_id, 1 if output["player"] == _radio else 0)
	output["frames"] = PackedVector2Array()
	output["offset"] = 0
	output["started"] = false
	output["first_ms"] = 0
	output["last_ms"] = 0
	# clear_buffer() is forbidden while a generator is active. Restart its
	# player instead, which gives us a fresh, empty playback instance.
	var player: Node = output["player"]
	player.stop()
	player.play()
	var playback: AudioStreamGeneratorPlayback = player.get_stream_playback()
	output["playback"] = playback
	output["capacity"] = playback.get_frames_available()


func clear_voice() -> void:
	_pending.clear()
	_next_sequence = -1
	_last_packet_ms = 0
	_gap_started_ms = 0
	for output in _outputs:
		_clear_output(output)


func _exit_tree() -> void:
	# Do not clear a newer local player's listener during scene replacement.
	if is_instance_valid(_listener):
		if get_viewport().get_audio_listener_3d() == _listener:
			_listener.clear_current()
	if _registered and is_instance_valid(VoiceManager):
		VoiceManager.unregister_player(_peer_id, self)
