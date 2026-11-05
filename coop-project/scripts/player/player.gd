extends CharacterBody3D
class_name SessionPlayerCharacter

@export_group("Movement")
@export var move_speed: float = 5.0
@export var acceleration: float = 25.0
@export var jump_velocity: float = 5.0

# Camera position, rotation, projection and size are authored on Camera3D in the Inspector.

@export_group("Mouse Aim")
@export var mouse_sensitivity: float = 0.002
@export var min_pitch: float = -89.0
@export var max_pitch: float = 89.0

@export_group("Network Smoothing")
# Read from the scene's MultiplayerSynchronizer during prepare().
var network_updates_per_second: float = 30.0
# Minimum playback buffer; existing scene overrides still apply.
@export var interpolation_delay: float = 0.10
@export var adaptive_buffering: bool = true
@export_range(0.10, 0.30, 0.01) var maximum_interpolation_delay: float = 0.20
@export_range(0.0, 0.15, 0.01) var maximum_extrapolation: float = 0.10
@export var recovery_speed: float = 15.0
@export var teleport_distance: float = 5.0
@export var print_network_statistics: bool = true

@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var visual: Node3D = $Visual

var controlling_peer_id: int = 1
var networked: bool = false
var _playback_rate: float = 1.0
var _movement_time: float = 0.0
var _adaptive_delay: float = 0.10
var _observed_jitter: float = 0.0
var _buffer_hold_until: float = 0.0
var _last_buffer_increase: float = -10.0
var _render_velocity: Vector3 = Vector3.ZERO

# Time and transform travel together in one synchronized property.
@export var network_sample: Dictionary = {}

var _gravity: float = float(
	ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
)

var _esc_menu: Node
var _loading_screen: Node
var _window_focused: bool = true
var _local_player: bool = false

# Aim state
var _look_yaw: float = 0.0
var _camera_pitch: float = 0.0

var _visual_local_transform: Transform3D = Transform3D.IDENTITY
var _camera_local_offset: Vector3 = Vector3.ZERO
var _previous_physics_position: Vector3 = Vector3.ZERO
var _current_physics_position: Vector3 = Vector3.ZERO
var _visual_error: Vector3 = Vector3.ZERO
var _recover_visual: bool = false
var _was_extrapolating: bool = false
var _synchronizer: MultiplayerSynchronizer

var _snapshots: Array[Dictionary] = []
var _playback_time: float = 0.0
var _latest_sample_time: float = -1.0

var _statistics_elapsed: float = 0.0
var _received_samples: int = 0
var _last_receive_time: float = -1.0
var _maximum_receive_gap: float = 0.0
var _buffer_empty_frames: int = 0


# Called by the spawning script before entering the scene tree.
func prepare(peer_id: int, use_network: bool) -> bool:
	controlling_peer_id = peer_id
	networked = use_network
	network_sample = {
		"time": _now_seconds(),
		"transform": transform,
		"velocity": _movement_velocity_local()
	}

	_synchronizer = get_node_or_null("MultiplayerSynchronizer") as MultiplayerSynchronizer
	if not networked:
		# Solo instances must not register replication when a peer later connects.
		# The saved Player scene and its Inspector configuration are untouched.
		if _synchronizer != null:
			remove_child(_synchronizer)
			_synchronizer.free()
			_synchronizer = null
		set_multiplayer_authority(peer_id)
		return true

	if _synchronizer == null:
		push_error("Player: add a MultiplayerSynchronizer child in the Player scene.")
		return false
	if _synchronizer.get_node_or_null(_synchronizer.root_path) != self:
		push_error("Player: MultiplayerSynchronizer Root Path must point to the Player root (..).")
		return false

	# The scene's Replication list is authoritative. Read and validate it;
	# never create a replacement config or discard additional properties.
	var config: SceneReplicationConfig = _synchronizer.replication_config
	var movement_path: NodePath = NodePath(".:network_sample")
	if config == null or not config.has_property(movement_path):
		push_error("Player: add network_sample to the synchronizer's Replication list.")
		return false
	if config.property_get_replication_mode(movement_path) != SceneReplicationConfig.REPLICATION_MODE_ALWAYS:
		push_error("Player: network_sample Replication Mode must be Always.")
		return false
	if config.property_get_spawn(movement_path):
		push_error("Player: turn off Spawn for network_sample; MultiplayerSpawner supplies the initial transform.")
		return false

	if _synchronizer.replication_interval > 0.0:
		network_updates_per_second = 1.0 / _synchronizer.replication_interval

	# Player ownership is assigned before the instance enters the scene tree.
	set_multiplayer_authority(peer_id)
	return true


func _ready() -> void:
	# Both the camera and remote characters are interpolated manually.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_local_player = (
		not networked
		or controlling_peer_id == multiplayer.get_unique_id()
	)

	if not _local_player:
		camera.current = false
		visual.show()

		set_physics_process(false)
		set_process_unhandled_input(false)

		_adaptive_delay = _minimum_buffer_delay()
		if _synchronizer != null:
			_synchronizer.synchronized.connect(_on_network_snapshot)

		return

	_esc_menu = get_tree().current_scene.get_node_or_null(
		"CanvasLayer/EscMenu"
	)

	_loading_screen = get_tree().get_first_node_in_group("connection_loading_ui")
	_movement_time = _now_seconds()
	_window_focused = true
	_look_yaw = global_rotation.y
	
	# Initial camera rotation to match spawn
	_camera_pitch = camera.global_rotation.x

	_visual_local_transform = visual.transform
	visual.top_level = true
	visual.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_previous_physics_position = global_position
	_current_physics_position = global_position
	
	# Cache local camera offset (often just head height on the Y axis in FPS)
	_camera_local_offset = camera.global_position - global_position

	camera.top_level = true
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_update_local_camera()

	camera.make_current()
	
	# Consider hiding the local player body for true FPS (or setting shadows only).
	# visual.hide() 
	visual.show()
	_update_local_visual()
	add_to_group("local_session_player")
	_update_mouse_mode()

	if networked:
		_publish_movement()

		print(
			"SPAWN [", Time.get_ticks_msec(),
			" ms] | Local network player ready: ",
			controlling_peer_id
		)


func _unhandled_input(event: InputEvent) -> void:
	if not _local_player or _controls_blocked():
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Mouse X controls Yaw, Mouse Y controls Pitch
		_look_yaw -= event.relative.x * mouse_sensitivity
		_camera_pitch -= event.relative.y * mouse_sensitivity
		
		# Clamp pitch to prevent looking too far up or down and flipping the camera
		_camera_pitch = clampf(_camera_pitch, deg_to_rad(min_pitch), deg_to_rad(max_pitch))


func _process(delta: float) -> void:
	if _local_player:
		_update_mouse_mode()
		_update_local_camera()
		_update_local_visual()
		return

	_update_adaptive_buffer(delta)
	_interpolate_remote_player(delta)
	_update_network_statistics(delta)


func _on_network_snapshot() -> void:
	if _local_player:
		return

	if not network_sample.has("time"):
		return

	if not network_sample.has("transform"):
		return

	if typeof(network_sample["transform"]) != TYPE_TRANSFORM3D:
		return

	var sample_time: float = float(network_sample["time"])
	var sample_transform: Transform3D = network_sample["transform"]
	var sample_velocity: Vector3 = Vector3.ZERO
	if typeof(network_sample.get("velocity")) == TYPE_VECTOR3:
		sample_velocity = network_sample["velocity"]
	if not is_finite(sample_time) or not sample_transform.is_finite():
		return
	if not sample_velocity.is_finite():
		return

	# Ignore repeated or out-of-order movement samples.
	if sample_time <= _latest_sample_time:
		return

	var received_at: float = _now_seconds()

	if _last_receive_time >= 0.0:
		var arrival_gap: float = received_at - _last_receive_time
		_maximum_receive_gap = maxf(_maximum_receive_gap, arrival_gap)
		# Elapsed times need no clock synchronization between computers.
		# Subtract sender time so missing samples alone don't imply jitter.
		var sender_gap: float = sample_time - _latest_sample_time
		var extra_gap: float = maxf(0.0, arrival_gap - sender_gap)
		if extra_gap > _observed_jitter:
			_observed_jitter = extra_gap
			if extra_gap > 0.03:
				_buffer_hold_until = received_at + 3.0

	_last_receive_time = received_at
	_received_samples += 1

	var reset_buffer: bool = _snapshots.is_empty()

	if not _snapshots.is_empty():
		var previous_transform: Transform3D = (
			_snapshots.back()["transform"]
		)

		var distance: float = (
			sample_transform.origin - previous_transform.origin
		).length()

		if distance > teleport_distance:
			reset_buffer = true

		# Recover cleanly after a long interruption.
		if sample_time - _latest_sample_time > 1.0:
			reset_buffer = true

	if _was_extrapolating:
		_recover_visual = true

	if reset_buffer:
		_visual_error = Vector3.ZERO
		_recover_visual = false
		_was_extrapolating = false
		_playback_rate = 1.0
		_render_velocity = Vector3.ZERO
		_snapshots.clear()
		_playback_time = sample_time - _target_buffer_delay()
		transform = sample_transform

	_latest_sample_time = sample_time

	_snapshots.append({
		"time": sample_time,
		"transform": sample_transform,
		"velocity": sample_velocity
	})

	while _snapshots.size() > 64:
		_snapshots.pop_front()


func _interpolate_remote_player(delta: float) -> void:
	if _snapshots.is_empty():
		return

	var desired_delay: float = _target_buffer_delay()
	var buffered_time: float = _latest_sample_time - _playback_time

	# Rebase after a large burst, but preserve visual continuity below.
	if buffered_time > maxf(0.35, desired_delay + 0.15):
		_playback_time = _latest_sample_time - desired_delay
		buffered_time = desired_delay
		_recover_visual = true

	var buffer_error: float = buffered_time - desired_delay
	# Ignore normal sample-sized fluctuations. Catch up faster when a burst
	# leaves excess history; slow gently when we need to rebuild the buffer.
	var dead_zone: float = maxf(0.02, 0.5 / maxf(network_updates_per_second, 1.0))
	var target_rate: float = 1.0
	if buffer_error > dead_zone:
		target_rate += minf((buffer_error - dead_zone) * 2.0, 0.12)
	elif buffer_error < -dead_zone:
		target_rate -= minf((-buffer_error - dead_zone), 0.06)
	_playback_rate = lerpf(
		_playback_rate, target_rate, 1.0 - exp(-6.0 * delta)
	)

	# Continue briefly past the newest sample rather than stopping immediately.
	# Never predict an entire long outage: stop at the configured limit.
	_playback_time = minf(
		_playback_time + delta * _playback_rate,
		_latest_sample_time + clampf(maximum_extrapolation, 0.0, 0.15)
	)

	while (
		_snapshots.size() >= 2
		and float(_snapshots[1]["time"]) <= _playback_time
	):
		_snapshots.pop_front()

	var target: Transform3D
	var next_render_velocity: Vector3 = Vector3.ZERO
	_was_extrapolating = _playback_time > _latest_sample_time
	if _was_extrapolating:
		_buffer_empty_frames += 1

	if _snapshots.size() == 1:
		var newest: Dictionary = _snapshots[0]
		target = newest["transform"]
		var extra_time: float = clampf(
			_playback_time - float(newest["time"]),
			0.0, clampf(maximum_extrapolation, 0.0, 0.15)
		)
		var sample_velocity: Vector3 = newest["velocity"]
		target.origin += sample_velocity * extra_time
		if extra_time < clampf(maximum_extrapolation, 0.0, 0.15):
			next_render_velocity = sample_velocity * _playback_rate
	else:
		var first: Dictionary = _snapshots[0]
		var second: Dictionary = _snapshots[1]
		var first_time: float = float(first["time"])
		var duration: float = maxf(float(second["time"]) - first_time, 0.0001)
		var weight: float = clampf((_playback_time - first_time) / duration, 0.0, 1.0)
		var first_transform: Transform3D = first["transform"]
		var second_transform: Transform3D = second["transform"]
		target = first_transform.interpolate_with(second_transform, weight)
		next_render_velocity = (
			(second_transform.origin - first_transform.origin) / duration
		) * _playback_rate

	if _recover_visual:
		# Preserve the expected forward motion as well as visual continuity.
		# Otherwise recovery can cause tiny pauses on each arriving sample.
		_visual_error = position + _render_velocity * delta - target.origin
		_recover_visual = false
		if _visual_error.length() > teleport_distance:
			_visual_error = Vector3.ZERO

	_visual_error *= exp(-maxf(recovery_speed, 0.1) * delta)
	target.origin += _visual_error
	transform = target
	_render_velocity = next_render_velocity


func _minimum_buffer_delay() -> float:
	return maxf(interpolation_delay, 2.0 / maxf(network_updates_per_second, 1.0))


func _target_buffer_delay() -> float:
	if not adaptive_buffering:
		return _minimum_buffer_delay()
	return _adaptive_delay


func _update_adaptive_buffer(delta: float) -> void:
	var minimum: float = _minimum_buffer_delay()
	var maximum: float = maxf(minimum, maximum_interpolation_delay)
	if not adaptive_buffering:
		_adaptive_delay = minimum
		return

	var now: float = _now_seconds()
	# Remember recent spikes, then forget them instead of permanently raising
	# the buffer after one bad packet. Target changes never rewind playback.
	_observed_jitter *= exp(-delta / 2.0)
	var sample_interval: float = 1.0 / maxf(network_updates_per_second, 1.0)
	var wanted: float = clampf(2.0 * sample_interval + _observed_jitter, minimum, maximum)

	# Once per second at most, an underrun asks for 20 ms more headroom.
	if _was_extrapolating and now - _last_buffer_increase >= 1.0:
		_adaptive_delay = minf(_adaptive_delay + 0.02, maximum)
		wanted = maxf(wanted, _adaptive_delay)
		_last_buffer_increase = now
		_buffer_hold_until = now + 3.0

	if wanted > _adaptive_delay:
		_adaptive_delay = move_toward(_adaptive_delay, wanted, delta * 0.25)
	elif now >= _buffer_hold_until:
		# Shed the target delay slowly: 5 ms per second during stable delivery.
		_adaptive_delay = move_toward(_adaptive_delay, wanted, delta * 0.005)
	_adaptive_delay = clampf(_adaptive_delay, minimum, maximum)


func _update_network_statistics(delta: float) -> void:
	if not print_network_statistics:
		return

	_statistics_elapsed += delta

	if _statistics_elapsed < 5.0:
		return

	var received_per_second: float = (
		float(_received_samples) / _statistics_elapsed
	)

	var buffered_ms: float = maxf(
		0.0,
		(_latest_sample_time - _playback_time) * 1000.0
	)

	print(
		"MOVEMENT | remote=", controlling_peer_id,
		" | local_fps=", Engine.get_frames_per_second(),
		" | updates/s=", snappedf(received_per_second, 0.1),
		" | max_gap_ms=", snappedf(_maximum_receive_gap * 1000.0, 0.1),
		" | buffer_ms=", snappedf(buffered_ms, 0.1),
		" | target_ms=", snappedf(_target_buffer_delay() * 1000.0, 0.1),
		" | playback_rate=", snappedf(_playback_rate, 0.001),
		" | empty_frames=", _buffer_empty_frames
	)

	_statistics_elapsed = 0.0
	_received_samples = 0
	_maximum_receive_gap = 0.0
	_buffer_empty_frames = 0


func _publish_movement() -> void:
	# Timestamp the simulated step, not its irregular wall-clock execution time.
	network_sample = {
		"time": _movement_time,
		"transform": transform,
		"velocity": _movement_velocity_local()
	}


func _now_seconds() -> float:
	return float(Time.get_ticks_usec()) / 1000000.0


func _physics_process(delta: float) -> void:
	if not _local_player:
		return

	_movement_time += delta
	_previous_physics_position = _current_physics_position
	
	# Rotate the actual body collision bounds on the Y axis for accurate hitboxes
	global_rotation = Vector3(0.0, _look_yaw, 0.0)

	if not is_on_floor():
		velocity.y -= _gravity * delta

	var blocked: bool = _controls_blocked()
	var input_direction: Vector2 = Vector2.ZERO
	var direction: Vector3 = Vector3.ZERO

	if not blocked:
		input_direction = Input.get_vector(
			"move_left",
			"move_right",
			"move_forward",
			"move_backward"
		)

		if Input.is_action_just_pressed("jump") and is_on_floor():
			velocity.y = jump_velocity

		# Transform WASD input to be relative to the player's view yaw
		var aim_basis := Basis(Vector3.UP, _look_yaw)
		direction = aim_basis * Vector3(input_direction.x, 0.0, input_direction.y)

	direction.y = 0.0

	if direction.length_squared() > 1.0:
		direction = direction.normalized()

	if blocked:
		velocity.x = 0.0
		velocity.z = 0.0
	else:
		velocity.x = move_toward(
			velocity.x,
			direction.x * move_speed,
			acceleration * delta
		)
		velocity.z = move_toward(
			velocity.z,
			direction.z * move_speed,
			acceleration * delta
		)

	move_and_slide()
	_current_physics_position = global_position

	if networked:
		_publish_movement()


func is_local_player() -> bool:
	# Retains the identity even after NetworkManager resets the peer to solo.
	return _local_player


func reset_local_camera_interpolation() -> void:
	# Call after explicitly teleporting the local character.
	_previous_physics_position = global_position
	_current_physics_position = global_position
	if _local_player:
		_update_local_camera()
		_update_local_visual()


func _interpolated_local_position() -> Vector3:
	var fraction: float = clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
	return _previous_physics_position.lerp(_current_physics_position, fraction)


func _update_local_camera() -> void:
	var target_pos := _interpolated_local_position()
	
	# Apply camera position offset, rotated by the current Yaw
	var head_offset := Basis(Vector3.UP, _look_yaw) * _camera_local_offset
	
	# Apply final Pitch + Yaw directly to camera
	var cam_basis := Basis(Vector3.UP, _look_yaw) * Basis(Vector3.RIGHT, _camera_pitch)

	camera.global_transform = Transform3D(
		cam_basis,
		target_pos + head_offset
	)


func _update_local_visual() -> void:
	# Match camera interpolation to prevent the local model jittering under it.
	# Preserve the Visual node's authored position, rotation and scale.
	var rendered_body := Transform3D(
		Basis(Vector3.UP, _look_yaw), _interpolated_local_position()
	)
	visual.global_transform = rendered_body * _visual_local_transform


func _movement_velocity_local() -> Vector3:
	# CharacterBody velocity is global; snapshots use the Players parent's space.
	var parent_3d: Node3D = get_parent() as Node3D
	if parent_3d != null:
		return parent_3d.global_transform.basis.inverse() * velocity
	return velocity


func _controls_blocked() -> bool:
	if is_instance_valid(_loading_screen):
		if bool(_loading_screen.call("is_loading")):
			return true

	if not _window_focused:
		return true

	if SteamManager.overlay_active:
		return true

	if is_instance_valid(_esc_menu):
		if _esc_menu.has_method("_is_menu_visible"):
			return bool(_esc_menu.call("_is_menu_visible"))

	return false


func _update_mouse_mode() -> void:
	# FPS aiming requires mouse capture. Return cursor to menus when blocked.
	if _controls_blocked():
		if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_window_focused = false

		if _local_player:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_window_focused = true


func _exit_tree() -> void:
	if _local_player:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
