extends Node3D

# Add this as a direct child of the existing Player root.
# Playback nodes/streams are local, never part of the Replication list.
@export_group("Proximity")
@export_range(1.0, 100.0, 1.0) var proximity_distance: float = 20.0
@export_range(0.1, 20.0, 0.1) var unit_size: float = 5.0
@export_range(-40.0, 12.0, 1.0) var proximity_volume_db: float = 0.0

@export_group("Radio")
@export_range(-40.0, 12.0, 1.0) var radio_volume_db: float = -3.0

@export_group("Voice Buffer")
@export_range(0.04, 0.20, 0.01) var prebuffer_seconds: float = 0.08
@export_range(0.04, 0.20, 0.01) var reorder_wait_seconds: float = 0.08
@export_range(0.20, 0.80, 0.05) var maximum_queue_seconds: float = 0.40

const SAMPLE_RATE: int = 16000
const MAX_PENDING_PACKETS: int = 32
const MAX_DECODED_BYTES: int = 64000

var _player: Node
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


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = get_parent()
	call_deferred("_register")


func _register() -> void:
	if not is_instance_valid(_player) or not _player.has_method("is_local_player"):
		push_error("PlayerVoice must be a direct child of your Player.")
		return
	if not bool(_player.get("networked")):
		set_process(false)
		return
	_peer_id = int(_player.get("controlling_peer_id"))
	if not bool(_player.call("is_local_player")):
		_create_outputs()
	VoiceManager.register_player(_peer_id, self)
	_registered = true


func can_transmit() -> bool:
	return (
		_registered and is_instance_valid(_player)
		and bool(_player.call("is_local_player"))
		and not bool(_player.call("_controls_blocked"))
	)


func _create_outputs() -> void:
	_proximity = AudioStreamPlayer3D.new()
	_proximity.name = "ProximityPlayback"
	_proximity.max_distance = proximity_distance
	_proximity.unit_size = unit_size
	add_child(_proximity)
	_radio = AudioStreamPlayer.new()
	_radio.name = "RadioPlayback"
	_radio.bus = &"VoiceRadio"
	add_child(_radio)
	for output in [_proximity, _radio]:
		var generator := AudioStreamGenerator.new()
		generator.mix_rate = SAMPLE_RATE
		generator.buffer_length = 0.20
		output.stream = generator
		output.play()
		var playback: AudioStreamGeneratorPlayback = output.get_stream_playback()
		_outputs.append({"player": output, "playback": playback, "capacity": playback.get_frames_available(), "frames": PackedVector2Array(), "offset": 0, "started": false, "first_ms": 0, "last_ms": 0})


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
	if _outputs.is_empty():
		return
	if not NetworkManager.is_session_connected():
		clear_voice()
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	var in_range: bool = camera == null or camera.global_position.distance_to(global_position) < proximity_distance
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
	_proximity.volume_db = proximity_volume_db + linear_to_db(maxf(gain, 0.0001))
	_radio.volume_db = radio_volume_db + linear_to_db(maxf(gain, 0.0001))


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


func _clear_output(output: Dictionary) -> void:
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
	if _registered and is_instance_valid(VoiceManager):
		VoiceManager.unregister_player(_peer_id, self)
