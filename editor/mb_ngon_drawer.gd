## MBNgonDrawer — Interactive polygon drawing controller for Knife tool and N-Gon Shape Extrusion.
##
## Runtime-safe, pure logic (no editor classes, headless-testable).
## Driven from the plugin's _forward_3d_gui_input:
##
## Shared UX:
## - Click on any surface (or grid) to place vertices.
## - Live visible overlay shows placed vertices connected by lines,
##   plus a live rubber-band line to the cursor with a vertex indicator under mouse.
## - Click and drag existing placed vertices to reposition them along the surface plane.
## - Snapping: snaps to placed vertices, target mesh edges and vertices, and the grid.
## - Enter completes the polygon:
##   - Knife: cuts the face (edge-to-edge cut splits face in two; closed loop cuts inner/outer).
##   - N-Gon: transitions to HEIGHT phase to adjust 3rd dimension by moving mouse,
##     LMB click confirms extrusion into a 3D prism.
## - ESC cancels/aborts cleanly.
@tool
class_name MBNgonDrawer
extends RefCounted

enum Mode { NONE, KNIFE, NGON_EXTRUDE }
enum State { INACTIVE, ARMED, DRAWING, DRAGGING_VERT, HEIGHT }

const RAY_MISS := Vector3(INF, INF, INF)
## Snap radii in WORLD units. The plugin sets them from screen pixels at the
## cursor's depth on every mouse move (10 px for corners, 9 px for edges), so
## the magnet feels the same on a 0.5 m prop and on a 20 m wall — fixed metres
## grabbed everything on small objects and nothing on large ones.
const SNAP_VERT_DISTANCE := 0.15
const SNAP_EDGE_DISTANCE := 0.12
var snap_vert_radius: float = SNAP_VERT_DISTANCE
var snap_edge_radius: float = SNAP_EDGE_DISTANCE
## Held Alt turns the magnet off entirely (place a point exactly where you
## point at, without the face pulling it to a corner).
var snap_disabled: bool = false
## Snap radii follow the target face's size instead of screen pixels: the same
## feel on a 10 cm prop face and on a 20 m wall, and never zero.
var auto_radii: bool = true
## What the last snap grabbed: 0 = nothing, 1 = a corner, 2 = an edge.
var last_snap_kind: int = 0
## Was the last committed knife cut a closed loop (a hole) rather than a stroke?
var last_cut_closed: bool = false
## World-space view direction of the cut (screen-space stroke projected onto
## every crossed face's plane along it).
var view_dir: Vector3 = Vector3.ZERO

var mode: Mode = Mode.NONE
var state: State = State.INACTIVE

## Drawing plane captured on first click
var plane_point: Vector3 = Vector3.ZERO
var plane_normal: Vector3 = Vector3.UP

## In-plane orthonormal axes
var u_axis: Vector3 = Vector3.RIGHT
var v_axis: Vector3 = Vector3.FORWARD

## Target mesh and face index (used by Knife tool)
var target_mesh: MBMesh = null
var target_face_index: int = -1

## Placed 3D vertices on the drawing plane (world space)
var points: Array[Vector3] = []

## Live cursor point on the plane (world space)
var live_cursor_point: Vector3 = Vector3.ZERO

## Hover and drag tracking for placed vertices
var hovered_vert_idx: int = -1
var dragged_vert_idx: int = -1

## Extrusion height for NGON_EXTRUDE
var height: float = 0.0

## Preview node for live 3D extrusion preview
var preview_node: MBMesh = null

## Plugin grid for snapping
var grid: MBGrid = null

## Vertex-snap hooks for the HEIGHT phase, injected by the plugin (inert when
## unset, so headless tests need nothing). Same semantics as the shape
## creator's: the drawn polygon's corners are the snap sources.
var vertex_snap_active_fn: Callable = Callable()
var vertex_snap_candidates_fn: Callable = Callable()

# ==============================================================================
# Lifecycle & State Management
# ==============================================================================

func is_active() -> bool:
	return state != State.INACTIVE

func arm(p_mode: Mode, p_mesh: MBMesh = null, p_face: int = -1) -> void:
	reset()
	mode = p_mode
	state = State.ARMED
	target_mesh = p_mesh
	target_face_index = p_face

func begin(point: Vector3, normal: Vector3, p_mesh: MBMesh = null, p_face: int = -1) -> void:
	plane_normal = normal.normalized()
	if plane_normal.length_squared() < 0.0001:
		plane_normal = Vector3.UP

	var up := Vector3.UP if absf(plane_normal.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	u_axis = plane_normal.cross(up).normalized()
	v_axis = plane_normal.cross(u_axis).normalized()

	if p_mesh != null:
		target_mesh = p_mesh
	if p_face >= 0:
		target_face_index = p_face

	points.clear()
	var start_pt := snap_starting_point(point, plane_normal, target_mesh, target_face_index)
	plane_point = start_pt
	points.append(start_pt)
	live_cursor_point = start_pt
	hovered_vert_idx = -1
	dragged_vert_idx = -1
	state = State.DRAWING
func add_point(point: Vector3) -> bool:
	if state != State.DRAWING:
		return false
	var snapped_pt := _snap_point(point)
	# Disallow placing right on top of the last vertex
	if not points.is_empty() and points[points.size() - 1].distance_to(snapped_pt) < 0.001:
		return false
	points.append(snapped_pt)
	return true

func start_drag_vert(idx: int) -> void:
	if idx >= 0 and idx < points.size():
		dragged_vert_idx = idx
		state = State.DRAGGING_VERT

func end_drag_vert() -> void:
	if state == State.DRAGGING_VERT:
		dragged_vert_idx = -1
		state = State.DRAWING

func update_cursor_plane(raw_point: Vector3) -> void:
	if state == State.INACTIVE or state == State.HEIGHT:
		return

	# Project point strictly onto plane
	var proj := raw_point - plane_normal * plane_normal.dot(raw_point - plane_point)

	# Keep a knife cut on the face FIRST, then snap: snapping before the clamp
	# threw away a corner the cursor had just caught.
	if mode == Mode.KNIFE and target_mesh != null and target_mesh.mb_mesh_data != null and target_face_index >= 0:
		proj = _clamp_to_face_boundary(target_mesh, target_face_index, proj)

	var snapped_pt := _snap_point(proj)
	live_cursor_point = snapped_pt

	if state == State.DRAGGING_VERT and dragged_vert_idx >= 0 and dragged_vert_idx < points.size():
		points[dragged_vert_idx] = snapped_pt
		hovered_vert_idx = dragged_vert_idx
		return

	# Update hovered vertex index
	hovered_vert_idx = -1
	var best_d := snap_vert_radius
	for i in range(points.size()):
		var d := proj.distance_to(points[i])
		if d < best_d:
			best_d = d
			hovered_vert_idx = i

## Live extents readout for the tool overlay (draw + height phases).
func get_extents_readout() -> String:
	match state:
		State.DRAWING, State.DRAGGING_VERT:
			return "%d vertices" % points.size() if not points.is_empty() else "0 vertices"
		State.HEIGHT:
			return "Height: %.2fm" % height
	return ""

func update_height_point(ref_point: Vector3) -> void:
	if state != State.HEIGHT:
		return
	var raw := plane_normal.dot(ref_point - plane_point)
	if grid != null and grid.enabled:
		raw = grid.snap_val(raw)
	raw = _vertex_snap_height(raw)
	height = raw

## Magnetic vertex snap for the rising polygon: the placed corners are the
## snap sources; when one would pass within the magnet radius of a scene
## vertex along the surface normal, the height locks onto that vertex.
func _vertex_snap_height(raw_height: float) -> float:
	if not (vertex_snap_active_fn.is_valid() and vertex_snap_active_fn.call()):
		return raw_height
	if not vertex_snap_candidates_fn.is_valid():
		return raw_height
	var candidates: PackedVector3Array = vertex_snap_candidates_fn.call()
	if candidates.is_empty() or points.is_empty():
		return raw_height
	var n := plane_normal.normalized()
	if n.length_squared() < 0.5:
		return raw_height
	var res := MBElementEditor.snap_axis_delta(PackedVector3Array(points), candidates, n,
		raw_height, MBElementEditor.vertex_snap_radius(grid))
	return float(res["d"]) if res["caught"] else raw_height

func complete() -> Dictionary:
	if state != State.DRAWING and state != State.DRAGGING_VERT:
		return {"ok": false, "error": "Not in drawing state"}

	if points.size() < 2:
		return {"ok": false, "error": "Need at least 2 points"}

	if mode == Mode.KNIFE:
		return _complete_knife()
	elif mode == Mode.NGON_EXTRUDE:
		return _complete_ngon_extrude()
	return {"ok": false, "error": "Unknown mode"}

func _complete_knife() -> Dictionary:
	if target_mesh == null or target_mesh.mb_mesh_data == null:
		return {"ok": false, "error": "Knife: no target mesh"}
	if target_face_index < 0 or target_face_index >= target_mesh.mb_mesh_data.faces.size():
		return {"ok": false, "error": "Knife: no target face"}

	var local_points := PackedVector3Array()
	var inv_xf := target_mesh.global_transform.affine_inverse()
	for p in points:
		local_points.append(inv_xf * p)

	# If first and last vertex match within 1mm, it's a closed loop
	var is_closed := false
	if local_points.size() >= 3 and local_points[0].distance_to(local_points[local_points.size() - 1]) < 0.001:
		is_closed = true

	last_cut_closed = is_closed
	# An open stroke belongs to every face it crosses (a wall of several quads is
	# cut through by one line); only a closed loop is a single-face hole.
	var res: Dictionary
	if is_closed:
		res = MBMeshOps.cut_face(target_mesh.mb_mesh_data, target_face_index, local_points, true)
	else:
		var local_dir: Vector3 = inv_xf.basis * view_dir
		res = MBMeshOps.cut_along_path(target_mesh.mb_mesh_data, local_points, local_dir)
	if not res.get("ok", false) and not is_closed and local_points.size() > 2:
		# A wiggly path can fail to clip on every face while the straight span
		# between its ends does cut: retry with the span alone.
		res = MBMeshOps.cut_along_path(target_mesh.mb_mesh_data,
			PackedVector3Array([local_points[0], local_points[local_points.size() - 1]]),
			(inv_xf.basis * view_dir))
	if not res.get("ok", false) and not is_closed:
		# Fallback: the stroke may not cross any face along the view direction
		# (degenerate projection) — cut the face the knife started on.
		res = MBMeshOps.cut_face(target_mesh.mb_mesh_data, target_face_index, local_points, false)
	if res.get("ok", false):
		state = State.INACTIVE
	return res

func _complete_ngon_extrude() -> Dictionary:
	if points.size() < 3:
		return {"ok": false, "error": "N-Gon extrude requires at least 3 points"}

	# Ensure closed loop
	if points[0].distance_to(points[points.size() - 1]) < 0.001:
		points.remove_at(points.size() - 1)
	if points.size() < 3:
		return {"ok": false, "error": "N-Gon extrude requires at least 3 points"}

	state = State.HEIGHT
	height = 0.0
	return {"ok": true, "action": "enter_height"}

func confirm_height() -> Dictionary:
	if state != State.HEIGHT:
		return {"ok": false, "error": "Not in height state"}

	var poly := PackedVector3Array()
	for p in points:
		poly.append(p)

	var eff_height := height if absf(height) > 0.0001 else 0.05
	var local_data := MBShapeComplex.create_ngon_prism(
		poly, eff_height, plane_normal
	)
	if local_data == null:
		reset()
		return {"ok": false, "error": "Failed to create n-gon prism"}

	# Use poly[0] (which is snapped to grid) as the node pivot for clean grid alignment
	var pivot := poly[0]
	if grid != null and grid.enabled:
		pivot = grid.snap_point(poly[0])

	for i in range(local_data.positions.size()):
		local_data.positions[i] -= pivot

	var placement := Transform3D(Basis(), pivot)

	var result := {
		"ok": true,
		"data": local_data,
		"transform": placement,
		"height": eff_height,
		"normal": plane_normal
	}
	reset()
	return result
func build_preview_data() -> MBMeshData:
	if state != State.HEIGHT:
		return null
	var poly := PackedVector3Array()
	for p in points:
		poly.append(p)
	var eff_height := height if absf(height) > 0.0001 else 0.001
	return MBShapeComplex.create_ngon_prism(poly, eff_height, plane_normal)

func reset() -> void:
	mode = Mode.NONE
	state = State.INACTIVE
	plane_point = Vector3.ZERO
	plane_normal = Vector3.UP
	target_mesh = null
	target_face_index = -1
	points.clear()
	live_cursor_point = Vector3.ZERO
	hovered_vert_idx = -1
	dragged_vert_idx = -1
	height = 0.0
	preview_node = null

# ==============================================================================
# Snapping & Geometry Helpers

func can_transition_to_face(face_idx: int) -> bool:
	if points.is_empty():
		return true
	if target_mesh == null or target_mesh.mb_mesh_data == null:
		return false
	var md: MBMeshData = target_mesh.mb_mesh_data
	if face_idx < 0 or face_idx >= md.faces.size():
		return false
	var last_p := points[points.size() - 1]
	var xf := target_mesh.global_transform
	var face := md.faces[face_idx]
	for edge in face.get_edges():
		var wa: Vector3 = xf * md.positions[edge.a]
		var wb: Vector3 = xf * md.positions[edge.b]
		var ab := wb - wa
		var len2 := ab.length_squared()
		if len2 > 0.000001:
			var t := clampf((last_p - wa).dot(ab) / len2, 0.0, 1.0)
			var edge_pt := wa + ab * t
			if last_p.distance_to(edge_pt) <= 0.08:
				return true
	return false

func switch_target_face(face_idx: int) -> void:
	if target_mesh == null or target_mesh.mb_mesh_data == null:
		return
	var md: MBMeshData = target_mesh.mb_mesh_data
	if face_idx < 0 or face_idx >= md.faces.size():
		return
	target_face_index = face_idx
	var face := md.faces[face_idx]
	var norm := MBMath.normal_from_positions(md.positions, face.get_indexes()).normalized()
	var xf := target_mesh.global_transform
	plane_normal = (xf.basis * norm).normalized()
	var idxs := face.get_indexes()
	if not idxs.is_empty():
		plane_point = xf * md.positions[idxs[0]]
	var up := Vector3.UP if absf(plane_normal.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	u_axis = plane_normal.cross(up).normalized()
	v_axis = plane_normal.cross(u_axis).normalized()
## Snaps an initial starting point to face geometry or to the grid.
func snap_starting_point(point: Vector3, normal: Vector3, p_mesh: MBMesh = null, p_face: int = -1) -> Vector3:
	if p_mesh != null and p_face >= 0:
		var face_snapped := snap_to_face(p_mesh, p_face, point)
		if face_snapped.distance_squared_to(point) > 0.00001:
			return face_snapped
	if grid != null and grid.enabled:
		var n := normal.normalized()
		if MBGrid.is_cardinal(n):
			return grid.snap_point_masked(point, n)
		return grid.snap_point(point)
	return point

## Snaps a world point to that face's corners/edges with the same radii as the
## magnetic snap (closest wins).
func snap_to_face(node: MBMesh, face_index: int, p: Vector3) -> Vector3:
	if node == null or node.mb_mesh_data == null or face_index < 0 or face_index >= node.mb_mesh_data.faces.size():
		return p
	var saved_mesh := target_mesh
	var saved_face := target_face_index
	target_mesh = node
	target_face_index = face_index
	var out := snap_point_world(p)
	target_mesh = saved_mesh
	target_face_index = saved_face
	return out

func _clamp_to_face_boundary(node: MBMesh, face_idx: int, world_pt: Vector3) -> Vector3:
	if node == null or node.mb_mesh_data == null:
		return world_pt
	var md: MBMeshData = node.mb_mesh_data
	if face_idx < 0 or face_idx >= md.faces.size():
		return world_pt

	var face := md.faces[face_idx]
	var loop := MBMeshOps._ordered_loop(face)
	if loop.size() < 3:
		return world_pt

	var xf := node.global_transform
	var inv_xf := xf.affine_inverse()
	var local_p := inv_xf * world_pt

	var norm := MBMath.normal_from_positions(md.positions, face.get_indexes()).normalized()
	if norm.length_squared() < 0.0001:
		return world_pt

	var up := Vector3.UP if absf(norm.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u := norm.cross(up).normalized()
	var v := norm.cross(u).normalized()
	var orig := md.positions[loop[0]]

	var to_2d = func(p3: Vector3) -> Vector2:
		var d := p3 - orig
		return Vector2(d.dot(u), d.dot(v))

	var to_3d = func(p2: Vector2) -> Vector3:
		return orig + u * p2.x + v * p2.y

	var loop_2d := PackedVector2Array()
	for idx in loop:
		loop_2d.append(to_2d.call(md.positions[idx]))

	var p2 := to_2d.call(local_p)
	if Geometry2D.is_point_in_polygon(p2, loop_2d):
		return world_pt

	var best_dist := INF
	var best_closest := p2
	var n_pts := loop_2d.size()
	for i in range(n_pts):
		var j := (i + 1) % n_pts
		var res := MBMeshOps._point_to_segment_distance_2d(p2, loop_2d[i], loop_2d[j])
		var d: float = res["dist"]
		if d < best_dist:
			best_dist = d
			best_closest = res["closest"]

	return xf * to_3d.call(best_closest)
# ==============================================================================

## Magnetic snap: the CLOSEST candidate wins between the points already placed
## in this session, the target face's corners (corner radius) and its edges
## (edge radius). Picking by type instead used to send the cursor to a far
## corner while a near edge was right under it.
## One position per welded corner of the mesh. Cached by position count (ids
## stay valid while vertices move — positions are resolved at use time).
var _corner_cache: Dictionary = {}

## Radii as a fraction of the target face's size. A corner magnet of 14 % and an
## edge magnet of 20 % of the face's bigger side reads the same at any zoom and
## cannot collapse to "a fraction of a pixel" like a screen-space radius did.
func _refresh_auto_radii() -> void:
	if target_mesh == null or target_mesh.mb_mesh_data == null or target_face_index < 0:
		return
	var md: MBMeshData = target_mesh.mb_mesh_data
	if target_face_index >= md.faces.size():
		return
	var loop := MBMeshOps._ordered_loop(md.faces[target_face_index])
	if loop.size() < 3:
		return
	var extent := 0.0
	for i in loop.size():
		var a: Vector3 = md.positions[loop[i]]
		var b: Vector3 = md.positions[loop[(i + 1) % loop.size()]]
		extent = maxf(extent, a.distance_to(b))
	if extent <= 0.0001:
		return
	snap_vert_radius = clampf(extent * 0.14, 0.004, 1.0)
	snap_edge_radius = clampf(extent * 0.20, 0.006, 1.5)

func _mesh_corner_positions(md: MBMeshData) -> PackedInt32Array:
	var key: int = md.get_instance_id()
	var cached: Dictionary = _corner_cache.get(key, {})
	if int(cached.get("size", -1)) == md.positions.size() and cached.has("ids"):
		return cached["ids"]
	var ids := PackedInt32Array()
	var seen := {}
	for face in md.faces:
		if face == null:
			continue
		for vi in face.get_indexes():
			var p: Vector3 = md.positions[vi]
			var k := Vector3i(roundi(p.x * 10000.0), roundi(p.y * 10000.0), roundi(p.z * 10000.0))
			if seen.has(k):
				continue
			seen[k] = true
			ids.append(vi)
	_corner_cache[key] = {"size": md.positions.size(), "ids": ids}
	return ids

func snap_point_world(p: Vector3) -> Vector3:
	var best := p
	var best_d := INF
	if snap_disabled:
		return p
	if auto_radii:
		_refresh_auto_radii()

	last_snap_kind = 0
	for i in range(points.size()):
		if state == State.DRAGGING_VERT and i == dragged_vert_idx:
			continue
		var d: float = p.distance_to(points[i])
		if d <= snap_vert_radius and d < best_d:
			best_d = d
			best = points[i]
			last_snap_kind = 1

	if target_mesh != null and target_mesh.mb_mesh_data != null and target_face_index >= 0:
		var md: MBMeshData = target_mesh.mb_mesh_data
		if target_face_index < md.faces.size():
			var xf := target_mesh.global_transform
			var face := md.faces[target_face_index]
			# Corners of the WHOLE mesh: aiming at a corner that belongs to the
			# neighbouring face is normal while cutting, and only the target
			# face's own corners used to snap.
			# Corners WIN over edges inside their radius: near a corner the edge
			# is always closer, so "closest wins" made vertices unreachable.
			var corner_best := INF
			var corner_pt := Vector3.ZERO
			var corner_hit := false
			# The knife may only aim at corners of the face being cut. CSG-converted
			# meshes keep a private copy of every vertex per face, and a neighbouring
			# face's copy of the "same" corner can sit centimetres away — snapping
			# to it made the cut end on an edge next to the real corner.
			var corner_ids := _mesh_corner_positions(md)
			if mode == Mode.KNIFE and target_face_index >= 0 and target_face_index < md.faces.size():
				corner_ids = md.faces[target_face_index].get_distinct_indexes()
			for idx in corner_ids:
				var corner: Vector3 = xf * md.positions[idx]
				var dc: float = p.distance_to(corner)
				if dc <= snap_vert_radius and dc < corner_best:
					corner_best = dc
					corner_pt = corner
					corner_hit = true
			if corner_hit and corner_best <= best_d:
				best_d = corner_best
				best = corner_pt
				last_snap_kind = 1
			# Inside a corner's radius the corner always wins — an edge is
			# geometrically closer near every corner, so "closest wins" made
			# vertices impossible to hit.
			if not corner_hit:
				for edge in face.get_edges():
					var wa: Vector3 = xf * md.positions[edge.a]
					var wb: Vector3 = xf * md.positions[edge.b]
					var ab := wb - wa
					var len2 := ab.length_squared()
					if len2 <= 0.000001:
						continue
					var t := clampf((p - wa).dot(ab) / len2, 0.0, 1.0)
					var edge_pt: Vector3 = wa + ab * t
					var de: float = p.distance_to(edge_pt)
					if de <= snap_edge_radius and de < best_d:
						best_d = de
						best = edge_pt
						last_snap_kind = 2
	return best

func _snap_point(p: Vector3) -> Vector3:
	var snapped := snap_point_world(p)
	if snapped != p:
		return snapped
	# 3. Snap to grid if enabled
	if grid != null and grid.enabled:
		return _snap_to_grid(p)

	return p

func _snap_to_grid(p: Vector3) -> Vector3:
	var s: float = grid.step()
	if s <= 0.0001:
		return p
	var n := plane_normal.normalized()
	if MBGrid.is_cardinal(n):
		return grid.snap_point_masked(p, n)
	# Non-cardinal plane: snap along in-plane u/v axes relative to plane_point
	var d := p - plane_point
	var u: float = grid.snap_val(d.dot(u_axis))
	var v: float = grid.snap_val(d.dot(v_axis))
	return plane_point + u_axis * u + v_axis * v
static func ray_plane_intersect(ray_o: Vector3, ray_d: Vector3, plane_pt: Vector3, plane_norm: Vector3) -> Vector3:
	var denom := plane_norm.dot(ray_d)
	if absf(denom) < 0.00001:
		return RAY_MISS
	var t := plane_norm.dot(plane_pt - ray_o) / denom
	if t < 0.0:
		return RAY_MISS
	return ray_o + ray_d * t
