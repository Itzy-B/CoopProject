extends Node

const SEND_INTERVAL: float = 0.05
const REPORT_INTERVAL: float = 5.0

var _send_elapsed: float = 0.0
var _report_elapsed: float = 0.0

var _last_frame_us: int = 0
var _maximum_frame_gap_ms: float = 0.0

var _last_physics_us: int = 0
var _maximum_physics_gap_ms: float = 0.0

var _received: Dictionary = {}
var _last_sent_us: int = 0
var _maximum_send_gap_ms: float = 0.0
var _sequence: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	if not NetworkManager.is_session_connected():
		_reset()
		return

	var now_us: int = Time.get_ticks_usec()

	if _last_frame_us != 0:
		_maximum_frame_gap_ms = maxf(
			_maximum_frame_gap_ms,
			float(now_us - _last_frame_us) / 1000.0
		)

	_last_frame_us = now_us
	_send_elapsed += delta
	_report_elapsed += delta

	if _send_elapsed >= SEND_INTERVAL:
		# Send one current probe. Don't burst old probes after a stall.
		_send_elapsed = fmod(_send_elapsed, SEND_INTERVAL)

		if _last_sent_us != 0:
			_maximum_send_gap_ms = maxf(
				_maximum_send_gap_ms, float(now_us - _last_sent_us) / 1000.0
			)
		_last_sent_us = now_us
		_sequence += 1

		if NetworkManager.is_hosting():
			for peer_id in multiplayer.get_peers():
				_receive_probe.rpc_id(peer_id, _sequence, now_us)
		else:
			_receive_probe.rpc_id(1, _sequence, now_us)

	if _report_elapsed >= REPORT_INTERVAL:
		_report()


func _physics_process(_delta: float) -> void:
	if not NetworkManager.is_session_connected():
		_last_physics_us = 0
		return

	var now_us: int = Time.get_ticks_usec()

	if _last_physics_us != 0:
		_maximum_physics_gap_ms = maxf(
			_maximum_physics_gap_ms,
			float(now_us - _last_physics_us) / 1000.0
		)

	_last_physics_us = now_us


# Explicitly unreliable; independent of player synchronization.
@rpc("any_peer", "call_remote", "unreliable", 0)
func _receive_probe(sequence: int, sent_us: int) -> void:
	if not NetworkManager.is_session_connected():
		return

	var sender_id: int = multiplayer.get_remote_sender_id()
	var now_us: int = Time.get_ticks_usec()

	var entry: Dictionary = _received.get(sender_id, {
		"count": 0,
		"last_us": 0,
		"maximum_gap_ms": 0.0,
		"last_sequence": 0,
		"last_sent_us": 0,
		"maximum_extra_delay_ms": 0.0
	})

	# Out-of-order datagrams do not move our measurement baseline backwards.
	if sequence <= int(entry["last_sequence"]):
		return
	var previous_us: int = int(entry["last_us"])
	var previous_sent_us: int = int(entry["last_sent_us"])
	if previous_us != 0 and previous_sent_us != 0:
		# Clock offsets cancel: compare elapsed times, not absolute timestamps.
		var extra_delay_ms: float = float(
			(now_us - previous_us) - (sent_us - previous_sent_us)
		) / 1000.0
		entry["maximum_extra_delay_ms"] = maxf(
			float(entry["maximum_extra_delay_ms"]), extra_delay_ms
		)
	entry["last_sequence"] = sequence
	entry["last_sent_us"] = sent_us

	if previous_us != 0:
		entry["maximum_gap_ms"] = maxf(
			float(entry["maximum_gap_ms"]),
			float(now_us - previous_us) / 1000.0
		)

	entry["count"] = int(entry["count"]) + 1
	entry["last_us"] = now_us
	_received[sender_id] = entry


func _report() -> void:
	print(
		"PROBE LOCAL | fps=", Engine.get_frames_per_second(),
		" | max_frame_gap_ms=",
		snappedf(_maximum_frame_gap_ms, 0.1),
		" | max_physics_gap_ms=",
		snappedf(_maximum_physics_gap_ms, 0.1),
		" | max_send_gap_ms=", snappedf(_maximum_send_gap_ms, 0.1)
	)

	for sender_id in _received:
		var entry: Dictionary = _received[sender_id]

		print(
			"PROBE RECEIVE | from=", sender_id,
			" | packets/s=",
			snappedf(float(entry["count"]) / _report_elapsed, 0.1),
			" | max_gap_ms=",
			snappedf(float(entry["maximum_gap_ms"]), 0.1),
			" | max_extra_delay_ms=",
			snappedf(float(entry["maximum_extra_delay_ms"]), 0.1)
		)

		entry["count"] = 0
		entry["maximum_gap_ms"] = 0.0
		entry["maximum_extra_delay_ms"] = 0.0

	_report_elapsed = 0.0
	_maximum_frame_gap_ms = 0.0
	_maximum_send_gap_ms = 0.0
	_maximum_physics_gap_ms = 0.0


func _reset() -> void:
	_send_elapsed = 0.0
	_report_elapsed = 0.0
	_last_frame_us = 0
	_last_physics_us = 0
	_maximum_frame_gap_ms = 0.0
	_maximum_send_gap_ms = 0.0
	_maximum_physics_gap_ms = 0.0
	_received.clear()
	_last_sent_us = 0
	_sequence = 0
