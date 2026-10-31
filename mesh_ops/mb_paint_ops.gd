## MBPaintOps — vertex-colour operations for the Paint tab.
##
## Colours live in MBMeshData.colors, one per POSITION (the same array the mesh
## builder uploads as ARRAY_COLOR). Corners that share a point share a colour,
## which is exactly what you want for a soft gradient, and duplicates of the same
## point (after cuts, CSG or mirroring) are painted together — otherwise a brush
## stroke would leave half of a seam behind.
@tool
class_name MBPaintOps
extends RefCounted

## Makes sure the colour array matches the vertex count, starting from white so
## an unpainted mesh looks exactly like it did before painting.
static func ensure_colors(mesh_data: MBMeshData) -> void:
	if mesh_data == null:
		return
	if mesh_data.colors.size() == mesh_data.positions.size():
		return
	var out := PackedColorArray()
	out.resize(mesh_data.positions.size())
	out.fill(Color.WHITE)
	for i in mini(mesh_data.colors.size(), out.size()):
		out[i] = mesh_data.colors[i]
	mesh_data.colors = out

## Paints every corner of the given faces.
static func fill_faces(mesh_data: MBMeshData, faces: PackedInt32Array, color: Color) -> int:
	if mesh_data == null or faces.is_empty():
		return 0
	ensure_colors(mesh_data)
	var touched := 0
	for fi in faces:
		if fi < 0 or fi >= mesh_data.faces.size() or mesh_data.faces[fi] == null:
			continue
		for idx in mesh_data.faces[fi].get_distinct_indexes():
			if idx >= 0 and idx < mesh_data.colors.size():
				mesh_data.colors[idx] = color
				touched += 1
	mesh_data.shape_edited = true
	return touched

## Paints the whole mesh.
static func fill_all(mesh_data: MBMeshData, color: Color) -> int:
	if mesh_data == null:
		return 0
	ensure_colors(mesh_data)
	for i in mesh_data.colors.size():
		mesh_data.colors[i] = color
	mesh_data.shape_edited = true
	return mesh_data.colors.size()

## Soft round brush: every vertex inside `radius` of `center` is blended towards
## `color` by `strength` scaled with a smooth falloff, so a stroke edges out
## instead of stamping a disc.
static func paint_sphere(mesh_data: MBMeshData, center: Vector3, radius: float,
		color: Color, strength: float = 1.0) -> int:
	if mesh_data == null or radius <= 0.0:
		return 0
	ensure_colors(mesh_data)
	var r2 := radius * radius
	var touched := 0
	for i in mesh_data.positions.size():
		var d2: float = mesh_data.positions[i].distance_squared_to(center)
		if d2 > r2:
			continue
		var falloff: float = 1.0 - sqrt(d2) / radius
		falloff = falloff * falloff * (3.0 - 2.0 * falloff)
		var t: float = clampf(strength * falloff, 0.0, 1.0)
		if t <= 0.0:
			continue
		var current: Color = mesh_data.colors[i]
		mesh_data.colors[i] = current.lerp(color, t)
		touched += 1
	if touched == 0:
		# The brush landed in the middle of a large face, farther from every
		# vertex than the radius — a big prop has metres between corners, and a
		# stroke that paints literally nothing reads as "the brush is broken".
		# Colour the single nearest corner instead.
		var nearest := -1
		var best := INF
		for i in mesh_data.positions.size():
			var d2: float = mesh_data.positions[i].distance_squared_to(center)
			if d2 < best:
				best = d2
				nearest = i
		if nearest >= 0:
			mesh_data.colors[nearest] = mesh_data.colors[nearest].lerp(color, clampf(strength, 0.0, 1.0))
			touched = 1
	mesh_data.shape_edited = true
	return touched

## Nearest vertex colour — the eyedropper.
static func color_at(mesh_data: MBMeshData, point: Vector3, tolerance: float = 0.05) -> Color:
	if mesh_data == null:
		return Color.WHITE
	ensure_colors(mesh_data)
	var best := -1
	var best_d := tolerance * tolerance
	for i in mesh_data.positions.size():
		var d2: float = mesh_data.positions[i].distance_squared_to(point)
		if d2 <= best_d:
			best_d = d2
			best = i
	return mesh_data.colors[best] if best >= 0 else Color.WHITE

## Turns on "vertex colour as albedo" in the mesh's materials. Without it the
## painted colours are uploaded to the mesh but every surface still shows its
## plain texture — which looks exactly like "the brush does nothing".
## Returns the number of materials that had to be switched.
static func enable_vertex_color_albedo(mesh_data: MBMeshData) -> int:
	if mesh_data == null:
		return 0
	var changed := 0
	for mat in mesh_data.materials:
		if mat is BaseMaterial3D and not (mat as BaseMaterial3D).vertex_color_use_as_albedo:
			(mat as BaseMaterial3D).vertex_color_use_as_albedo = true
			changed += 1
	var fallback := MBMeshData.get_default_material()
	if changed == 0 and mesh_data.materials.is_empty() and fallback is BaseMaterial3D:
		if not (fallback as BaseMaterial3D).vertex_color_use_as_albedo:
			(fallback as BaseMaterial3D).vertex_color_use_as_albedo = true
			changed += 1
	return changed

## Paints the whole face nearest to the point. Used when the sphere brush caught
## at most a single corner: on big flat panels the corners are metres apart, and
## painting one of them looks like nothing happened.
static func paint_nearest_face(mesh_data: MBMeshData, point: Vector3, color: Color,
		strength: float = 1.0) -> int:
	if mesh_data == null or mesh_data.faces.is_empty():
		return 0
	ensure_colors(mesh_data)
	var best := -1
	var best_d := INF
	for fi in mesh_data.faces.size():
		var face: MBFace = mesh_data.faces[fi]
		if face == null:
			continue
		var d := _face_distance(mesh_data, face, point)
		if d < best_d:
			best_d = d
			best = fi
	if best < 0:
		return 0
	var touched := 0
	for idx in mesh_data.faces[best].get_distinct_indexes():
		mesh_data.colors[idx] = mesh_data.colors[idx].lerp(color, clampf(strength, 0.0, 1.0))
		touched += 1
	mesh_data.shape_edited = true
	return touched

## Paints the whole face that owns a triangle under the cursor. Props have big
## flat faces with corners metres apart, so a sphere brush can miss every vertex
## there — this makes a click on such a face always do something you can see.
static func paint_face_at(mesh_data: MBMeshData, corners: Array, color: Color,
		strength: float = 1.0) -> int:
	if mesh_data == null or corners.size() < 3:
		return 0
	ensure_colors(mesh_data)
	var want: Array[Vector3i] = []
	for c in corners:
		want.append(_key(c))
	var touched := 0
	for fi in mesh_data.faces.size():
		var face: MBFace = mesh_data.faces[fi]
		if face == null:
			continue
		var found := 0
		for idx in face.get_distinct_indexes():
			var k := _key(mesh_data.positions[idx])
			for w in want:
				if k == w:
					found += 1
					break
		if found < 3:
			continue
		for idx in face.get_distinct_indexes():
			mesh_data.colors[idx] = mesh_data.colors[idx].lerp(color, clampf(strength, 0.0, 1.0))
			touched += 1
		break
	mesh_data.shape_edited = true
	return touched

static func _key(p: Vector3) -> Vector3i:
	return Vector3i(roundi(p.x * 10000.0), roundi(p.y * 10000.0), roundi(p.z * 10000.0))

## Distance from a point to the closest of the face's triangles.
static func _face_distance(mesh_data: MBMeshData, face: MBFace, point: Vector3) -> float:
	var idx := face.get_indexes()
	var best := INF
	var k := 0
	while k + 2 < idx.size():
		var a: Vector3 = mesh_data.positions[idx[k]]
		var b: Vector3 = mesh_data.positions[idx[k + 1]]
		var c: Vector3 = mesh_data.positions[idx[k + 2]]
		best = minf(best, _point_triangle_distance(point, a, b, c))
		k += 3
	return best

static func _point_triangle_distance(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> float:
	# Closest point on a triangle (Ericson, Real-Time Collision Detection).
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return p.distance_to(a)
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return p.distance_to(b)
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		var v := d1 / (d1 - d3)
		return p.distance_to(a + ab * v)
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return p.distance_to(c)
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		var w := d2 / (d2 - d6)
		return p.distance_to(a + ac * w)
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		var u := (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return p.distance_to(b + (c - b) * u)
	# The point projects INSIDE the triangle: the distance is to the plane.
	# (Missing this branch returned an infinite distance for every face the click
	# was actually on, so the code painted whichever face it happened to measure
	# on its border — "clicked one face, another got painted".)
	var sum := va + vb + vc
	if sum <= 0.0:
		return INF
	var v := vb / sum
	var w := vc / sum
	return p.distance_to(a + ab * v + ac * w)

## Paints the two corners of the edge nearest to the point.
static func paint_nearest_edge(mesh_data: MBMeshData, point: Vector3, color: Color,
		strength: float = 1.0) -> int:
	if mesh_data == null:
		return 0
	ensure_colors(mesh_data)
	var best_a := -1
	var best_b := -1
	var best_d := INF
	for face in mesh_data.faces:
		if face == null:
			continue
		for e in face.get_edges():
			if e.a < 0 or e.a >= mesh_data.positions.size() or e.b < 0 or e.b >= mesh_data.positions.size():
				continue
			var pa: Vector3 = mesh_data.positions[e.a]
			var pb: Vector3 = mesh_data.positions[e.b]
			var d := _point_segment_distance(point, pa, pb)
			if d < best_d:
				best_d = d
				best_a = e.a
				best_b = e.b
	if best_a < 0:
		return 0
	var t := clampf(strength, 0.0, 1.0)
	var touched := 0
	for idx in [best_a, best_b]:
		mesh_data.colors[idx] = mesh_data.colors[idx].lerp(color, t)
		touched += 1
		# twins of the same point follow their edge, otherwise a cut seam keeps
		# half of the edge unpainted
		var key := _key(mesh_data.positions[idx])
		for other in mesh_data.positions.size():
			if other == idx:
				continue
			if _key(mesh_data.positions[other]) == key:
				mesh_data.colors[other] = mesh_data.colors[other].lerp(color, t)
				touched += 1
	mesh_data.shape_edited = true
	return touched

## Paints the single nearest corner (and its twins).
static func paint_nearest_vertex(mesh_data: MBMeshData, point: Vector3, color: Color,
		strength: float = 1.0) -> int:
	if mesh_data == null or mesh_data.positions.is_empty():
		return 0
	ensure_colors(mesh_data)
	var best := -1
	var best_d := INF
	for i in mesh_data.positions.size():
		var d: float = mesh_data.positions[i].distance_squared_to(point)
		if d < best_d:
			best_d = d
			best = i
	if best < 0:
		return 0
	var t := clampf(strength, 0.0, 1.0)
	var touched := 0
	var key := _key(mesh_data.positions[best])
	for i in mesh_data.positions.size():
		if _key(mesh_data.positions[i]) == key:
			mesh_data.colors[i] = mesh_data.colors[i].lerp(color, t)
			touched += 1
	mesh_data.shape_edited = true
	return touched

static func _point_segment_distance(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 < 0.000000000001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)

## Ray/triangle intersection against THIS mesh (Möller–Trumbore). The brush used
## to take its point from the physics ray, and a prop scene can have colliders
## from other nodes (or a stale one) — the click then landed 0.8 m away from the
## model and painted a random face. Aiming at the mesh itself is exact.
## Returns {hit: bool, point: Vector3, face: int, distance: float}.
static func raycast(mesh_data: MBMeshData, origin: Vector3, dir: Vector3) -> Dictionary:
	var result := {"hit": false, "point": Vector3.ZERO, "face": -1, "distance": INF}
	if mesh_data == null or mesh_data.faces.is_empty():
		return result
	var best := INF
	var best_point := Vector3.ZERO
	var best_face := -1
	for fi in mesh_data.faces.size():
		var face: MBFace = mesh_data.faces[fi]
		if face == null:
			continue
		var idx := face.get_indexes()
		var k := 0
		while k + 2 < idx.size():
			var a: Vector3 = mesh_data.positions[idx[k]]
			var b: Vector3 = mesh_data.positions[idx[k + 1]]
			var c: Vector3 = mesh_data.positions[idx[k + 2]]
			var t := _ray_triangle(origin, dir, a, b, c)
			if t > 0.0001 and t < best:
				best = t
				best_point = origin + dir * t
				best_face = fi
			k += 3
	if best_face >= 0:
		result["hit"] = true
		result["point"] = best_point
		result["face"] = best_face
		result["distance"] = best
	return result

static func _ray_triangle(origin: Vector3, dir: Vector3, a: Vector3, b: Vector3, c: Vector3) -> float:
	var edge1 := b - a
	var edge2 := c - a
	var h := dir.cross(edge2)
	var det := edge1.dot(h)
	if absf(det) < 0.00000001:
		return -1.0
	var inv := 1.0 / det
	var s := origin - a
	var u := inv * s.dot(h)
	if u < 0.0 or u > 1.0:
		return -1.0
	var q := s.cross(edge1)
	var v := inv * dir.dot(q)
	if v < 0.0 or u + v > 1.0:
		return -1.0
	return inv * edge2.dot(q)

## Colour of the face the click actually hit: the corner closest to the hit
## point. Picking by "nearest vertex in the whole mesh" grabbed a corner from a
## neighbouring face whenever the clicked face had its own corners further away —
## on a prop that is most of the time.
static func color_at_face(mesh_data: MBMeshData, face_index: int, point: Vector3) -> Color:
	if mesh_data == null:
		return Color.WHITE
	ensure_colors(mesh_data)
	if face_index < 0 or face_index >= mesh_data.faces.size() or mesh_data.faces[face_index] == null:
		return color_at(mesh_data, point)
	var best := -1
	var best_d := INF
	for idx in mesh_data.faces[face_index].get_distinct_indexes():
		if idx < 0 or idx >= mesh_data.colors.size():
			continue
		var d: float = mesh_data.positions[idx].distance_squared_to(point)
		if d < best_d:
			best_d = d
			best = idx
	if best < 0:
		return color_at(mesh_data, point)
	return mesh_data.colors[best]
