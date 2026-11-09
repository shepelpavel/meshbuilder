## MBGrid — MeshBuilder's snapping state (runtime-safe, headless-testable).
##
## The plugin used to draw and own a full grid of its own (unit, subdivisions,
## elevation, a viewport line mesh). That is gone: the editor already has a 3D
## grid, so MeshBuilder now only SNAPS to it — and it snaps exactly the way the
## editor itself does, on two engine-owned values:
## - the snap SWITCH is the Spatial Editor's own "Use Snap" toggle (Y), pushed
##   into `enabled` by the plugin (the plugin has no Snap button of its own);
## - the snap STEP is the engine's translate snap value, read from the
##   editor's project metadata ("3d_editor"/"snap_translate_value" — the same
##   key the engine restores from, see node_3d_editor_plugin.cpp).
##
## Application points (wired by the plugin/editor layer):
## - Element MOVE drags: absolute world-grid snapping anchored on a VERTEX of
##   the dragged selection (MBElementEditor._grid_snap_anchor), not on the
##   selection's centre — a centroid is off the ticks even when every corner
##   is on one. Intra-selection offsets are preserved: the whole selection
##   translates rigidly by the delta that puts that vertex on the line.
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

## Shift while dragging shrinks the step — the engine's own fine-snap modifier
## (Node3DEditor::get_translate_snap divides by 10 under Shift).
const FINE_FACTOR := 0.1

## World-space origin of the grid plane (the editor grid sits at y = 0; used as
## the drawing plane when shape creation has no surface under the cursor).
var origin: Vector3 = Vector3.ZERO

## Whether MeshBuilder snapping applies to element drags and creation. Driven
## by the editor's own "Use Snap" toggle — there is no separate plugin switch.
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

## The effective snap step in meters — the editor's translate snap value,
## read live on every call so a change in the Snap Settings dialog is live on
## the next drag without any plugin-side bookkeeping.
func step() -> float:
	return _editor_snap_step()

## Step for an interactive drag: `fine` (Shift held) divides it by 10, exactly
## like the editor's own snapping — so a 1 m grid can be nudged in 10 cm steps
## without touching Snap Settings.
func drag_step(fine: bool) -> float:
	var s := step()
	return s * FINE_FACTOR if fine else s

## The editor's own translate snap step: project metadata
## "3d_editor"/"snap_translate_value", the very key the engine restores its
## Snap Settings from (default 1 m). Falls back to the viewport grid cell, then
## to 1 m.
static func _editor_snap_step() -> float:
	if not Engine.is_editor_hint():
		return DEFAULT_STEP
	var es: EditorSettings = null
	if Engine.has_singleton("EditorInterface"):
		es = EditorInterface.get_editor_settings()
	if es == null:
		return DEFAULT_STEP
	var v: float = float(es.get_project_metadata("3d_editor", "snap_translate_value", DEFAULT_STEP))
	if v > 0.0001:
		return v
	if es.has_setting("editors/3d/grid_size"):
		var g: float = float(es.get_setting("editors/3d/grid_size"))
		if g > 0.0001:
			return g
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

## Snaps a world-space position onto the grid, ignoring the on/off switch:
## explicit commands (Snap Selection To Grid) ask for it by definition.
func snap_point_always(p: Vector3) -> Vector3:
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
