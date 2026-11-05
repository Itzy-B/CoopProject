extends PanelContainer

@onready var _icon: TextureRect = $Margin/Content/Icon
@onready var _name_label: Label = $Margin/Content/Name


func set_speaker(display_name: String, radio: bool, texture: Texture2D) -> void:
	_name_label.text = display_name
	_name_label.tooltip_text = display_name
	_icon.texture = texture
	_icon.tooltip_text = "Radio" if radio else "Proximity"
