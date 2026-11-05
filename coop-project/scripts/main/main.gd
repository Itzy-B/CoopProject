
extends Node

@export_group("World")
@export var waiting_area_scene: PackedScene

@export_group("UI Scenes")
@export var connection_loading_scene: PackedScene
@export var invitation_popup_scene: PackedScene
@export var voice_status_scene: PackedScene

@onready var world: Node3D = $World
@onready var esc_menu: Control = $CanvasLayer/EscMenu


func _ready() -> void:
	Engine.physics_jitter_fix = 0.0

	_add_ui_scene(connection_loading_scene, "Connection Loading")
	_add_ui_scene(invitation_popup_scene, "Invitation Popup")
	_add_ui_scene(voice_status_scene, "Voice Status")

	esc_menu.call("set_menu_open", false)

	call_deferred("_load_waiting_area")


func _add_ui_scene(
	scene: PackedScene,
	description: String
) -> void:
	if scene == null:
		push_error("Main: assign %s in the Inspector." % description)
		return

	add_child(scene.instantiate())


func _load_waiting_area() -> void:
	if waiting_area_scene == null:
		push_error("Main: assign Waiting Area Scene.")
		return

	world.add_child(waiting_area_scene.instantiate())
