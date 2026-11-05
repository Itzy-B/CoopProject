extends SubViewportContainer

@export var scroll_container: ScrollContainer

var _scrollbar: VScrollBar
var _fade_material: ShaderMaterial


func _ready() -> void:
	if scroll_container == null:
		push_error("Assign Scroll Container.")
		return

	# Give this list its own shader parameters.
	_fade_material = material.duplicate() as ShaderMaterial
	material = _fade_material

	_scrollbar = scroll_container.get_v_scroll_bar()
	_scrollbar.value_changed.connect(_on_scroll_value_changed)
	_scrollbar.changed.connect(_queue_fade_update)

	call_deferred("_update_fades")


func _on_scroll_value_changed(_value: float) -> void:
	_update_fades()


func _queue_fade_update() -> void:
	# Wait for layout changes to finish.
	call_deferred("_update_fades")


func _update_fades() -> void:
	var bottom_limit: float = maxf(
		_scrollbar.min_value,
		_scrollbar.max_value - _scrollbar.page
	)

	var can_scroll: bool = bottom_limit > _scrollbar.min_value + 1.0

	_fade_material.set_shader_parameter(
		"fade_top",
		can_scroll and _scrollbar.value > _scrollbar.min_value + 1.0
	)

	_fade_material.set_shader_parameter(
		"fade_bottom",
		can_scroll and _scrollbar.value < bottom_limit - 1.0
	)
