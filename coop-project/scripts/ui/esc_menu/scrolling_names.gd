extends Control

@export var scroll_speed: float = 30.0
@export var pause_duration: float = 3.0

@onready var _label: Label = get_child(0) as Label

var _tween: Tween
var _previous_text: String = ""
var _previous_size: Vector2 = Vector2.ZERO
var _needs_refresh: bool = true


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.clip_text = false
	_label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	_label.custom_minimum_size = Vector2.ZERO
	_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	visibility_changed.connect(_on_visibility_changed)


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	# Restart only when the name or available space changes.
	if (
		_needs_refresh
		or _label.text != _previous_text
		or size != _previous_size
	):
		_needs_refresh = false
		_previous_text = _label.text
		_previous_size = size
		_restart_scroll()


func _restart_scroll() -> void:
	if _tween != null:
		_tween.kill()
		_tween = null

	_label.position = Vector2.ZERO
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT

	var text_size: Vector2 = _label.get_minimum_size()

	_label.size = Vector2(
		maxf(text_size.x, size.x),
		maxf(text_size.y, size.y)
	)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	var overflow: float = text_size.x - size.x

	# Short names stay centered.
	if overflow <= 1.0 or size.x <= 0.0:
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		return

	var duration: float = overflow / maxf(scroll_speed, 1.0)

	_tween = create_tween()
	_tween.set_loops()

	_tween.tween_interval(maxf(pause_duration, 0.0))
	_tween.tween_property(
		_label, "position:x", -overflow, duration
	).from(0.0)

	_tween.tween_interval(maxf(pause_duration, 0.0))
	_tween.tween_property(
		_label, "position:x", 0.0, duration
	).from(-overflow)

func _on_visibility_changed() -> void:
	if not is_visible_in_tree():
		if _tween != null:
			_tween.kill()
			_tween = null
	else:
		_needs_refresh = true
