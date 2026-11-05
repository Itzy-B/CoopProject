extends CanvasLayer

@export_group("Speaker Rows")
@export var speaker_row_scene: PackedScene
@export var proximity_icon: Texture2D
@export var radio_icon: Texture2D
@export var show_self: bool = true

@export_group("Popup Animation")
@export_range(0.01, 1.0, 0.01) var slide_seconds: float = 0.20

@onready var _panel: VBoxContainer = $Root/Rows
@onready var _preview: Control = $Root/Rows/Preview

var _rows: Dictionary = {}
var _refresh_queued: bool = false
var _open: bool = false
var _slide_offset: float = 0.0
var _resting_offset_x: float = 0.0
var _tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_resting_offset_x = offset.x
	_preview.hide()
	_panel.hide()
	VoiceManager.speakers_changed.connect(_queue_refresh)
	VoiceManager.speaker_names_changed.connect(_queue_refresh)
	_queue_refresh()


func _queue_refresh() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	call_deferred("_refresh")


func _refresh() -> void:
	_refresh_queued = false
	if speaker_row_scene == null:
		push_error("VoiceStatusPopup: assign Speaker Row Scene in the Inspector.")
		return
	var speakers: Dictionary = VoiceManager.get_active_speakers()
	if not show_self:
		speakers.erase(multiplayer.get_unique_id())
	if speakers.is_empty():
		_set_open(false)
		return
	for peer_id in _rows.keys():
		if not speakers.has(peer_id):
			_remove_row(int(peer_id))
	for peer_id in speakers:
		var row: Node = _rows.get(peer_id)
		if not is_instance_valid(row):
			row = speaker_row_scene.instantiate()
			_panel.add_child(row)
			_rows[peer_id] = row
		var radio: bool = bool(speakers[peer_id]["radio"])
		row.call("set_speaker", VoiceManager.get_speaker_name(int(peer_id)), radio, radio_icon if radio else proximity_icon)
	_set_open(true)


func _remove_row(peer_id: int) -> void:
	var row: Node = _rows.get(peer_id)
	_rows.erase(peer_id)
	if is_instance_valid(row):
		_panel.remove_child(row)
		row.queue_free()


func _set_slide_offset(value: float) -> void:
	# Animate the CanvasLayer, leaving the saved Control layout untouched.
	offset.x = _resting_offset_x + value
	_slide_offset = value


func _hidden_offset() -> float:
	var rect: Rect2 = _panel.get_global_rect()
	var right_edge: float = maxf(rect.end.x, rect.position.x + _panel.get_combined_minimum_size().x)
	return -right_edge - 1.0


func _set_open(value: bool) -> void:
	if value == _open:
		return
	_open = value
	if _tween != null:
		_tween.kill()
	if value:
		if not _panel.visible:
			_set_slide_offset(0.0)
			_set_slide_offset(_hidden_offset())
			_panel.modulate.a = 0.0
		_panel.show()
		_tween = create_tween().set_parallel(true)
		_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_tween.tween_method(_set_slide_offset, _slide_offset, 0.0, slide_seconds)
		_tween.tween_property(_panel, "modulate:a", 1.0, slide_seconds)
	else:
		var current: float = _slide_offset
		_set_slide_offset(0.0)
		var hidden: float = _hidden_offset()
		_set_slide_offset(current)
		_tween = create_tween().set_parallel(true)
		_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		_tween.tween_method(_set_slide_offset, current, hidden, slide_seconds)
		_tween.tween_property(_panel, "modulate:a", 0.0, slide_seconds)
		_tween.chain().tween_callback(_finish_hiding)


func _finish_hiding() -> void:
	if _open:
		return
	_panel.hide()
	_set_slide_offset(0.0)
	for peer_id in _rows.keys():
		_remove_row(int(peer_id))
