## MBGrid — MeshBuilder's snapping state (runtime-safe, headless-testable).
##
## The plugin used to draw and own a full grid of its own (unit, subdivisions,
## elevation, a viewport line mesh). That is gone: the editor already has a 3D
## grid, so MeshBuilder now only SNAPS to it. The step is the engine's own
## transform snap step when the editor exposes it, otherwise the grid cell
## itself (1 unit = 1 m).
##
## Application points (wired by the plugin/editor layer):
## - Element MOVE drags: the drag DELTA snaps per-component in WORLD space
##   (incremental/relative mode — preserves intra-selection offsets).
## - EXTRUDE gestures: the cap distance along the extrude normal snaps.
## - ROTATE drags: the delivered rotation angle snaps to `rotate_step_deg`.
## - SCALE and INSET drags: intentionally unsnapped (ProBuilder parity).
## - Shape creation: the press point snaps MASKED by the surface normal (only
##   on cardinal surfaces); base extents and height quantize.
@tool
class_name MBGrid
extends RefCounted

## Fallback step: one editor grid cell.
const DEFAULT_STEP := 1.0

## Any snapping parameter changed.
signal changed

## World-space origin of the grid plane (the editor grid sits at y = 0; used as
## the drawing plane when shape creation has no surface under the cursor).
var origin: Vector3 = Vector3.ZERO

## Whether MeshBuilder snapping applies to element drags and creation.
var enabled: bool = true:
	set(v):
		if enabled == v:
			return
		enabled = v
		changed.emit()

## Rotation snap step in degrees (matches the engine's 15° default).
var rotate_step_deg: float = 15.0:
	set(v):
		var cv := clampf(v, 0.0, 180.0)
		if is_equal_approx(rotate_step_deg, cv):
			return
		rotate_step_deg = cv
		changed.emit()

## The engine's translate snap step, pushed in by the plugin (0 = unknown).
## Godot keeps it in the Snap Settings dialog, which the tool bridge locates.
var engine_step: float = 0.0

var _step_cache: float = 0.0

## The effective snap step in meters: the editor's own snap step, otherwise the
## grid cell.
func step() -> float:
	if engine_step > 0.0001:
		return engine_step
	if _step_cache <= 0.0001:
		_step_cache = _editor_snap_step()
	return _step_cache

## Lets the plugin feed the live editor value (it moves during a session).
func set_engine_step(v: float) -> void:
	if is_equal_approx(engine_step, v):
		return
	engine_step = v
	changed.emit()

static func _editor_snap_step() -> float:
	if not Engine.is_editor_hint():
		return DEFAULT_STEP
	var es := EditorInterface.get_editor_settings() if Engine.has_singleton("EditorInterface") else null
	if es == null:
		return DEFAULT_STEP
	for key in ["editors/3d/snap_translate", "editors/3d/grid_snap_translate",
			"editors/3d/transform_gizmo/snap_translate", "editors/3d/snap_translate_step"]:
		if es.has_setting(key):
			var v: float = float(es.get_setting(key))
			if v > 0.0001:
				return v
	return DEFAULT_STEP

## Nearest multiple of step, or `v` unchanged when snapping is off.
func snap_val(v: float) -> float:
	if not enabled:
		return v
	return snap_val_exact(v, step())

## Raw: nearest multiple of `p_step` (0 step passes through).
static func snap_val_exact(v: float, p_step: float) -> float:
	if absf(p_step) < 0.0001:
		return v
	return p_step * roundf(v / p_step)

## Snaps a world-space position onto the grid.
func snap_point(p: Vector3) -> Vector3:
	if not enabled:
		return p
	var s := step()
	return Vector3(snap_val_exact(p.x, s), snap_val_exact(p.y, s), snap_val_exact(p.z, s))

## Snaps a point onto the grid MASKED by the surface normal: the axis the
## surface normal aligns with (when cardinal) is left untouched.
func snap_point_masked(p: Vector3, surface_normal: Vector3) -> Vector3:
	if not enabled:
		return p
	var n := surface_normal.normalized()
	var out := snap_point(p)
	if absf(absf(n.x) - 1.0) < 0.001:
		out.x = p.x
	if absf(absf(n.y) - 1.0) < 0.001:
		out.y = p.y
	if absf(absf(n.z) - 1.0) < 0.001:
		out.z = p.z
	return out

## True when the surface normal is world-axis aligned.
static func is_cardinal(n: Vector3) -> bool:
	var nn := n.normalized()
	return absf(absf(nn.x) - 1.0) < 0.001 \
		or absf(absf(nn.y) - 1.0) < 0.001 \
		or absf(absf(nn.z) - 1.0) < 0.001

## Snaps a TRANSLATION DELTA that lives in a node's local space to the world
## grid: converts through the node's rotation (and uniform scale), quantizes
## per world component, converts back.
func snap_local_delta(node_basis: Basis, local_delta: Vector3) -> Vector3:
	if not enabled:
		return local_delta
	var world := node_basis * local_delta
	world = Vector3(snap_val_exact(world.x, step()),
		snap_val_exact(world.y, step()), snap_val_exact(world.z, step()))
	return node_basis.inverse() * world

## Snaps a pure-rotation basis to `rotate_step_deg` about its own axis.
func snap_rotation(b: Basis) -> Basis:
	if not enabled or rotate_step_deg < 0.01:
		return b
	var q := b.get_rotation_quaternion()
	var axis := q.get_axis()
	var angle := q.get_angle()
	if axis.length_squared() < 0.5 or absf(angle) < 0.000001:
		return b
	var snapped_deg := snap_val_exact(rad_to_deg(angle), rotate_step_deg)
	return Basis(axis.normalized(), deg_to_rad(snapped_deg))
