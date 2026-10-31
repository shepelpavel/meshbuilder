## MBMeshData — Core editable mesh data container for MeshBuilder.
##
## Stores vertex positions, per-vertex attributes (UV0, colors, tangents),
## faces (MBFace), and shared vertex/texture topological groups.
@tool
class_name MBMeshData
extends Resource

# ==============================================================================
# Serialized / Exported Properties
# ==============================================================================

## Vertex positions in local space.
@export var positions: PackedVector3Array = PackedVector3Array()

## Per-vertex UV channel 0.
@export var textures0: PackedVector2Array = PackedVector2Array()
## Per-vertex UV channel 1 (UV2), author-owned: used by the LightmapGI unwrap.
@export var textures1: PackedVector2Array = PackedVector2Array()

## Lightmap atlas size hint written by the UV2 unwrap (0,0 = none).
@export var lightmap_size_hint: Vector2i = Vector2i.ZERO

## Per-vertex colors.
@export var colors: PackedColorArray = PackedColorArray()

## Per-vertex tangents (packed as groups of 4 floats: x,y,z,w per vertex).
@export var tangents: PackedFloat32Array = PackedFloat32Array()

## Polygon faces — stored as an Array of MBFace resources.
@export var faces: Array[MBFace] = []

## Shared vertex groups — groups of vertex indices that share the same spatial position.
@export var shared_vertices: Array[MBSharedVertex] = []

## Sharp edges, stored as PAIRS of position indices (a, b, a, b, ...). Sharp
## lives on the EDGE, the way it does in Blender: the faces on its two sides
## never average their normals through it, and Auto Smooth never carries
## smoothing across it — whatever the dihedral angle says.
@export var sharp_edges: PackedInt32Array = PackedInt32Array()

## Shared texture groups — groups of vertex indices that share continuous UV coordinates.
@export var shared_textures: Array[MBSharedVertex] = []

## Shape creation bookkeeping: the factory shape id this mesh was generated
## from (empty when the mesh is not a pristine shape), the parameter values
## it was generated with, and whether geometry was edited beyond those
## params (element drags, mesh ops). "Edit Params" only works while
## `shape_edited` is false — regenerating would wipe manual edits.
@export var shape_id: StringName = &""
@export var shape_params: Dictionary = {}
@export var shape_edited: bool = false

## Materials associated with submesh slots (index matches submesh_index on faces).
@export var materials: Array[Material] = []

## Mirror mode (Blender's Mirror modifier): the stored geometry is the half you
## edit, the render gets its reflection across the object's origin on
## `mirror_axis` (0 = X, 1 = Y, 2 = Z). The mirrored side is display only —
## it is built at compile time, never stored as faces.
@export var mirror_enabled: bool = false:
	set(value):
		if mirror_enabled == value:
			return
		mirror_enabled = value
		invalidate_caches()
		emit_changed()
@export var mirror_axis: int = 0:
	set(value):
		var clamped: int = clampi(value, 0, 2)
		if mirror_axis == clamped:
			return
		mirror_axis = clamped
		invalidate_caches()
		emit_changed()

## Persistent object-space texture anchor point. Set at shape creation to the
## initial bounding box minimum corner so texture tiling never slides relative
## to the object when faces are moved or resized.
@export var texture_anchor: Vector3 = Vector3.ZERO
@export var has_texture_anchor: bool = false

# ==============================================================================
# Non-Serialized / Cached Fields
# ==============================================================================

## Cached: vertex_index -> shared_vertex_group_index
var _shared_vertex_lookup: Dictionary = {}
var _shared_vertex_lookup_valid: bool = false

## Cached: vertex_index -> shared_texture_group_index
var _shared_texture_lookup: Dictionary = {}
var _shared_texture_lookup_valid: bool = false

## Cached normals (calculated on demand, not serialized)
var _normals: PackedVector3Array = PackedVector3Array()

## Cached: deduplicated common edges in stable face-scan order
var _common_edges: Array[MBEdge] = []
var _common_edge_indices: PackedInt32Array = PackedInt32Array()
var _common_edges_valid: bool = false

## Cached: submesh_index -> PackedInt32Array of compiled triangle indices (CW front faces).
var _submesh_indices_cache: Dictionary = {}
var _submesh_keys_cache: Array[int] = []

## Cached: position index -> owning face index (position privacy gives every
## position exactly one owner). Used by the incremental normals update.
var _position_face: Dictionary = {}
var _position_face_valid: bool = false

## Instance id of the MBMesh that edits this data in the open scene (0 = none
## yet). Not serialized: MBMesh._claim_mesh_data uses it to spot a second node
## holding the same resource (an editor Ctrl+D shares it) and privatise.
var claimed_by: int = 0

# ==============================================================================
# Property Accessors (Computed, Read-Only)
# ==============================================================================

## Total number of vertex positions.
func vertex_count() -> int:
	return positions.size()

## Total number of faces.
func face_count() -> int:
	return faces.size()

## Total number of triangles across all faces.
func triangle_count() -> int:
	var count: int = 0
	for face in faces:
		if face != null:
			count += face.get_indexes().size() / 3
	return count

## Total number of vertex indices across all faces.
func index_count() -> int:
	var count: int = 0
	for face in faces:
		if face != null:
			count += face.get_indexes().size()
	return count

## Total number of perimeter edges across all faces.
func edge_count() -> int:
	var count: int = 0
	for face in faces:
		if face != null:
			count += face.get_edges().size()
	return count

# ==============================================================================
# Shared Vertex Lookup & Cache Management
# ==============================================================================

## Returns the shared vertex lookup dictionary (vertex_index -> group_index).
## Lazy-cached; rebuilt when invalidated.
func get_shared_vertex_lookup() -> Dictionary:
	if not _shared_vertex_lookup_valid:
		_shared_vertex_lookup = MBSharedVertex.build_lookup(shared_vertices)
		_shared_vertex_lookup_valid = true
	return _shared_vertex_lookup

## Returns the shared vertex group index for the given local vertex index (-1 if none).
func get_shared_vertex_index(local_vertex_idx: int) -> int:
	return get_shared_vertex_lookup().get(local_vertex_idx, -1)

## Returns the shared texture lookup dictionary (vertex_index -> group_index).
## Lazy-cached; rebuilt when invalidated.
func get_shared_texture_lookup() -> Dictionary:
	if not _shared_texture_lookup_valid:
		_shared_texture_lookup = MBSharedVertex.build_lookup(shared_textures)
		_shared_texture_lookup_valid = true
	return _shared_texture_lookup

## Invalidates the shared vertex lookup cache.
func invalidate_shared_vertex_lookup() -> void:
	_shared_vertex_lookup_valid = false

## Invalidates the shared texture lookup cache.
func invalidate_shared_texture_lookup() -> void:
	_shared_texture_lookup_valid = false

## Invalidates all caches.
func invalidate_caches() -> void:
	invalidate_shared_vertex_lookup()
	invalidate_shared_texture_lookup()
	_common_edges_valid = false
	_common_edges.clear()
	_common_edge_indices.clear()
	_position_face_valid = false
	_position_face.clear()
	_submesh_indices_cache.clear()
	_submesh_keys_cache.clear()
	_normals.clear()

## Recomputes normals only for the faces owning `union` positions — the
## incremental path for drags, where exactly the drag union moves. Produces
## the same values as calculate_normals() (per-face sequential triangle
## scan, last triangle wins per position) at a fraction of the cost on
## large meshes. Falls back to the full build when the array is stale.
func update_normals_for(union: PackedInt32Array) -> void:
	if positions.is_empty() or faces.is_empty():
		return
	if _normals.size() != positions.size():
		calculate_normals()
		return
	var wanted := {}
	for idx in union:
		if idx >= 0 and idx < positions.size():
			wanted[idx] = true
	if wanted.is_empty():
		return
	if not _position_face_valid:
		_position_face.clear()
		for fi in range(faces.size()):
			var face: MBFace = faces[fi]
			if face == null:
				continue
			for idx in face.get_indexes():
				_position_face[idx] = fi
		_position_face_valid = true
	var affected_faces := {}
	for idx in wanted:
		if _position_face.has(idx):
			affected_faces[_position_face[idx]] = true
	var pos_count: int = positions.size()
	for fi in affected_faces:
		var face: MBFace = faces[fi]
		if face == null:
			continue
		var idxs := face.get_indexes()
		for t in range(0, idxs.size() - 2, 3):
			var i0: int = idxs[t]
			var i1: int = idxs[t + 1]
			var i2: int = idxs[t + 2]
			if i0 >= pos_count or i1 >= pos_count or i2 >= pos_count:
				continue
			var cross_prod: Vector3 = (positions[i1] - positions[i0]) \
				.cross(positions[i2] - positions[i0])
			var normal: Vector3 = cross_prod.normalized() \
				if not cross_prod.is_zero_approx() else Vector3.ZERO
			_normals[i0] = normal
			_normals[i1] = normal
			_normals[i2] = normal

## Returns all unique edges as position-index pairs, deduplicated by shared
## vertex group pair, in stable face-scan order. Lazy-cached.
## IMPORTANT: the returned MBEdge.a/.b are POSITION indices (one representative
## per welded corner pair) — safe to index into `positions` directly for
## rendering and picking. (An earlier version returned shared-GROUP indices
## here; consumers that indexed positions with them drew garbage chords —
## the "X / diagonal edges on the face" bug.)
## Subgizmo IDs for edge mode index into this list.
func get_common_edges() -> Array[MBEdge]:
	if not _common_edges_valid:
		_build_common_edges()
	return _common_edges

## Returns unique edges as a flat PackedInt32Array of position-index pairs
## [a0, b0, a1, b1, ...]. Avoids MBEdge object allocation and property lookups
## during wireframe rendering and picking.
func get_common_edge_indices() -> PackedInt32Array:
	if not _common_edges_valid:
		_build_common_edges()
	return _common_edge_indices

func _build_common_edges() -> void:
	_common_edges.clear()
	_common_edge_indices.clear()
	var seen: Dictionary = {}
	var lookup := get_shared_vertex_lookup()
	for face in faces:
		if face == null:
			continue
		for edge in face.get_edges():
			var ca: int = lookup.get(edge.a, -1)
			var cb: int = lookup.get(edge.b, -1)
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			if seen.has(key):
				continue
			seen[key] = true
			# Emit the raw POSITION pair; the group key above already
			# guarantees one entry per welded edge.
			_common_edges.append(MBEdge.new(edge.a, edge.b))
			_common_edge_indices.append(edge.a)
			_common_edge_indices.append(edge.b)
	_common_edges_valid = true


## Returns the object-space texture anchor, initializing it to the minimum
## corner of positions if not already established.
func get_texture_anchor() -> Vector3:
	if not has_texture_anchor:
		if positions.is_empty():
			return Vector3.ZERO
		var min_pos := Vector3(INF, INF, INF)
		for p in positions:
			min_pos.x = minf(min_pos.x, p.x)
			min_pos.y = minf(min_pos.y, p.y)
			min_pos.z = minf(min_pos.z, p.z)
		texture_anchor = min_pos
		has_texture_anchor = true
	return texture_anchor

# ==============================================================================
# Coincident Vertex Queries & Common Index Lookups
# ==============================================================================

## Given a single vertex index, find its shared vertex group and return all vertex
## indices in that group (including the input vertex itself).
## If the vertex is not in any shared group, returns [vertex].
func get_coincident_vertices(vertex: int) -> PackedInt32Array:
	var lookup := get_shared_vertex_lookup()
	if not lookup.has(vertex):
		return PackedInt32Array([vertex])
	var group_idx: int = lookup[vertex]
	if group_idx < 0 or group_idx >= shared_vertices.size():
		return PackedInt32Array([vertex])
	return shared_vertices[group_idx].indices

## Given multiple vertex indices, find all coincident vertices across all their
## shared vertex groups. Deduplicates by group — if two input vertices belong to
## the same group, the group's indices appear only once.
func get_coincident_vertices_multi(vertices: PackedInt32Array) -> PackedInt32Array:
	var result := PackedInt32Array()
	var seen_groups: Dictionary = {}
	var lookup := get_shared_vertex_lookup()
	for v in vertices:
		if not lookup.has(v):
			continue
		var group_idx: int = lookup[v]
		if seen_groups.has(group_idx):
			continue
		seen_groups[group_idx] = true
		if group_idx >= 0 and group_idx < shared_vertices.size():
			result.append_array(shared_vertices[group_idx].indices)
	return result

## Given a set of edges, find all coincident vertices for all edge endpoints.
func get_coincident_vertices_from_edges(edges: Array[MBEdge]) -> PackedInt32Array:
	var verts := PackedInt32Array()
	for edge in edges:
		if edge == null:
			continue
		verts.append(edge.a)
		verts.append(edge.b)
	return get_coincident_vertices_multi(verts)

## Given face indices (indices into the faces array), collect all distinct vertex
## indices from those faces, then return all coincident vertices.
func get_coincident_vertices_from_faces(face_indices: PackedInt32Array) -> PackedInt32Array:
	var verts := PackedInt32Array()
	for fi in face_indices:
		if fi < 0 or fi >= faces.size():
			continue
		var face: MBFace = faces[fi]
		if face == null:
			continue
		verts.append_array(face.get_distinct_indexes())
	return get_coincident_vertices_multi(verts)


## Converts a local edge to a "common" edge (both endpoints mapped to their
## shared vertex group indices). Returns null if edge is null.
func get_common_edge(edge: MBEdge) -> MBEdge:
	if edge == null:
		return null
	var lookup := get_shared_vertex_lookup()
	var ca: int = lookup.get(edge.a, -1)
	var cb: int = lookup.get(edge.b, -1)
	return MBEdge.new(ca, cb)

# ==============================================================================
# Weld Integrity
# ==============================================================================

## Ensures shared vertex groups exist and cover every position referenced by
## the faces. Missing or partial welds make edge/vertex element ids resolve to
## raw position pairs — drags then tear corners apart ("moved those 2 verts").
## Rebuilds welds from coincident positions when damaged; returns true if the
## groups were rebuilt. Never merges groups that already exist (explicit
## unwelds are preserved) — it only heals ABSENT coverage.
func ensure_welds(tolerance: float = 0.0001) -> bool:
	var referenced := {}
	for face in faces:
		if face == null:
			continue
		for idx in face.get_indexes():
			if idx >= 0 and idx < positions.size():
				referenced[idx] = true
	if referenced.is_empty():
		return false

	if shared_vertices.is_empty():
		shared_vertices = MBMeshData.build_welds_from_positions(positions, tolerance)
		invalidate_caches()
		return true

	var lookup := get_shared_vertex_lookup()
	for idx in referenced.keys():
		if not lookup.has(idx):
			shared_vertices = MBMeshData.build_welds_from_positions(positions, tolerance)
			invalidate_caches()
			return true
	return false

## Rebuilds the weld groups from the CURRENT positions (the unconditional
## form of ensure_welds). Required after any drag that moved positions
## apart which an earlier op had seeded coincident: a zero-distance
## extrude/inset merges every seed-time-coincident corner into one group,
## and the drag only moves the cap/lifted dups — the stale group then ties
## the moved cap to the unmoved bases, so the next grab drags the bases
## along ("moving the extruded face moves the whole extruded part") and
## the group-pair dedup collapses the cap's edges out of the common-edge
## list ("no edges after extruding").
func rebuild_welds(tolerance: float = 0.0001) -> void:
	shared_vertices = build_welds_from_positions(positions, tolerance)
	invalidate_caches()

## Groups position indices whose coordinates coincide within tolerance.
static func build_welds_from_positions(positions: PackedVector3Array,
		tolerance: float = 0.0001) -> Array[MBSharedVertex]:
	var tol_sq: float = tolerance * tolerance
	var representatives: PackedVector3Array = PackedVector3Array()
	var groups: Array[PackedInt32Array] = []
	for i in range(positions.size()):
		var assigned: int = -1
		for g in range(representatives.size()):
			if representatives[g].distance_squared_to(positions[i]) <= tol_sq:
				assigned = g
				break
		if assigned == -1:
			representatives.append(positions[i])
			groups.append(PackedInt32Array([i]))
		else:
			groups[assigned].append(i)
	var result: Array[MBSharedVertex] = []
	for g in groups:
		result.append(MBSharedVertex.new(g))
	return result

# ==============================================================================
# Data Setters
# ==============================================================================


## Sets faces and invalidates caches.
func set_faces(p_faces: Array[MBFace]) -> void:
	faces = p_faces
	invalidate_caches()



# ==============================================================================
# Validation
# ==============================================================================


# ==============================================================================
# Mesh Compilation & Normals (ToMesh)
# ==============================================================================

## Calculates normals for all vertices across all faces.
## Flat by default ("last triangle wins per position"); faces sharing a
## non-zero smoothing_group at a weld group get their normals AVERAGED there
## (Unity/ProBuilder semantics — the cylinder factory marks its walls
## smoothing_group 1 for exactly this). Returns a PackedVector3Array of the
## same size as positions.
func calculate_normals() -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(positions.size())
	for i in range(normals.size()):
		normals[i] = Vector3.ZERO

	var pos_count: int = positions.size()
	for face in faces:
		if face == null:
			continue
		var idxs := face.get_indexes()
		for tri_i in range(0, idxs.size() - 2, 3):
			var i0: int = idxs[tri_i]
			var i1: int = idxs[tri_i + 1]
			var i2: int = idxs[tri_i + 2]
			if i0 < 0 or i0 >= pos_count or i1 < 0 or i1 >= pos_count or i2 < 0 or i2 >= pos_count:
				continue
			var edge1: Vector3 = positions[i1] - positions[i0]
			var edge2: Vector3 = positions[i2] - positions[i0]
			# Internal data is CCW-from-outside (Unity convention) —
			# normal = edge1 × edge2 points outward
			var cross_prod: Vector3 = edge1.cross(edge2)
			if cross_prod.is_zero_approx():
				continue
			var normal: Vector3 = cross_prod.normalized()
			normals[i0] = normal
			normals[i1] = normal
			normals[i2] = normal

	# Smooth-shading pass: within each weld group, faces wearing the same
	# non-zero smoothing group contribute their area-weighted normal to an
	# average that every one of their positions in the group wears. Faces on
	# smoothing group 0 keep the flat normal, so a smooth-shaded bevel still
	# creases sharply where it meets the untouched flat faces.
	var has_smooth := false
	for face in faces:
		if face != null and face.smoothing_group != 0:
			has_smooth = true
			break
	if has_smooth and not shared_vertices.is_empty():
		# Area-weighted normal per face (unnormalized cross products sum).
		var face_count: int = faces.size()
		var face_normals: Array[Vector3] = []
		face_normals.resize(face_count)
		for fi in range(face_count):
			var face: MBFace = faces[fi]
			if face == null:
				continue
			var acc := Vector3.ZERO
			var idxs := face.get_indexes()
			for tri_i in range(0, idxs.size() - 2, 3):
				var i0: int = idxs[tri_i]
				var i1: int = idxs[tri_i + 1]
				var i2: int = idxs[tri_i + 2]
				if i0 < 0 or i0 >= pos_count or i1 < 0 or i1 >= pos_count or i2 < 0 or i2 >= pos_count:
					continue
				acc += (positions[i1] - positions[i0]).cross(positions[i2] - positions[i0])
			face_normals[fi] = acc
		# Weld group -> { smoothing group -> { face index } }, plus the
		# position each smooth face owns in the group.
		var lookup := get_shared_vertex_lookup()
		var group_faces := {}   # group id -> { sg -> { fi } }
		var group_pos := {}     # group id -> { fi -> position index }
		# Group corners by POSITION, not by the stored weld list: a mesh cut by the
		# knife, by CSG or by intersecting faces carries twins of the same point that
		# never made it into one shared vertex. Grouping by position makes those
		# twins average together, which is exactly what "smooth" means — otherwise
		# one face's triangles keep their flat normals and a seam shows up inside a
		# surface that was never split.
		for fi in range(face_count):
			var face: MBFace = faces[fi]
			if face == null or face.smoothing_group == 0:
				continue
			for idx in face.get_distinct_indexes():
				var gid: Vector3i = _pos_key_v(positions[idx])
				if not group_faces.has(gid):
					group_faces[gid] = {}
				if not group_faces[gid].has(face.smoothing_group):
					group_faces[gid][face.smoothing_group] = {}
				group_faces[gid][face.smoothing_group][fi] = true
				group_pos[gid] = group_pos.get(gid, {})
				# A face can own SEVERAL indices in one weld node (split vertices
				# from cutting, CSG and mirrored copies): every one of them has to
				# wear the average, otherwise the leftover twin keeps its flat
				# triangle normal and a seam shows up inside a single face.
				if not group_pos[gid].has(fi):
					group_pos[gid][fi] = []
				var slots: Array = group_pos[gid][fi]
				if not slots.has(idx):
					slots.append(idx)
				group_pos[gid][fi] = slots
		# Sharp edges are seams: around every corner the faces form a fan, and the
		# fan is cut where it crosses a sharp edge. Faces inside one piece share an
		# average normal (so the edges BETWEEN them stay smooth); the two faces on
		# the seam itself sit in different pieces and get their own normals. That
		# is the whole difference from a flat "except this pair" rule, which used
		# to crease every neighbour of the marked edge as well.
		var sharp_keys := sharp_edge_keys()
		for gid in group_faces:
			var node_pos: Vector3 = Vector3(gid) / 10000.0
			for sg in group_faces[gid]:
				var members: Array = group_faces[gid][sg].keys()
				if members.is_empty():
					continue
				var pieces: Array = [members]
				if not sharp_keys.is_empty():
					pieces = _fan_pieces(members, node_pos, sharp_keys)
				for piece in pieces:
					if piece.is_empty():
						continue
					var avg := Vector3.ZERO
					for fi in piece:
						avg += face_normals[fi]
					if avg.length_squared() < 0.000000000001:
						continue
					avg = avg.normalized()
					for fi in piece:
						for slot in group_pos[gid][fi]:
							normals[int(slot)] = avg

	_normals = normals
	return normals

## Position key of a single point (Vector3i, quantised like sharp_key).
func _pos_key_v(p: Vector3) -> Vector3i:
	return Vector3i(roundi(p.x * 10000.0), roundi(p.y * 10000.0), roundi(p.z * 10000.0))

## The welded corner position of a weld-group id.
func _node_position(gid: int) -> Vector3:
	if gid >= 0 and gid < shared_vertices.size() and not shared_vertices[gid].indices.is_empty():
		return positions[shared_vertices[gid].indices[0]]
	return Vector3.ZERO

## Splits the faces meeting at one corner into smooth pieces, the way a seam
## cuts a surface: the faces are sorted by their angle around the corner, the ring
## is cut where it crosses a sharp edge, and every run between cuts becomes one
## piece. The piece ends next to a cut are "privately owned" by their side, so the
## only edges that crease are the ones actually marked — a marked seam line gives
## a clean split with no stray creases next to it.
func _fan_pieces(members: Array, node_pos: Vector3, sharp_keys: Dictionary) -> Array:
	if members.size() < 2:
		return [members]
	if members.size() == 2:
		# Two faces: either they share a sharp edge (two pieces) or they do not.
		if _faces_share_sharp_edge(int(members[0]), int(members[1]), node_pos, sharp_keys):
			return [[members[0]], [members[1]]]
		return [members]
	# Axis: the average normal around the corner, so the sort happens in the
	# tangent plane of the surface and not in the world plane.
	var axis := Vector3.ZERO
	var centres := {}
	for fi in members:
		var face: MBFace = faces[int(fi)]
		var acc := Vector3.ZERO
		var idxs := face.get_indexes()
		var k := 0
		while k + 2 < idxs.size():
			acc += (positions[idxs[k + 1]] - positions[idxs[k]]).cross(positions[idxs[k + 2]] - positions[idxs[k]])
			k += 3
		axis += acc
		var c := Vector3.ZERO
		for ci in face.get_distinct_indexes():
			c += positions[ci]
		centres[int(fi)] = c / float(maxi(face.get_distinct_indexes().size(), 1))
	if axis.length_squared() < 0.000000000001:
		return [members]
	axis = axis.normalized()
	var helper := Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u := (helper - axis * axis.dot(helper)).normalized()
	var v := axis.cross(u)
	var angles := {}
	for fi in members:
		var d: Vector3 = centres[int(fi)] - node_pos
		d = d - axis * axis.dot(d)
		angles[int(fi)] = atan2(d.dot(v), d.dot(u))
	var order: Array = members.duplicate()
	order.sort_custom(func(a, b): return angles[int(a)] < angles[int(b)])
	var count: int = order.size()
	# Ring position of every face, then the cuts (sharp edges) between neighbours.
	var cuts: Array = []
	for i in count:
		var a: int = order[i]
		var b: int = order[(i + 1) % count]
		if _faces_share_sharp_edge(a, b, node_pos, sharp_keys):
			cuts.append(i)
	if cuts.is_empty():
		return [order]
	if cuts.size() == 1:
		# One cut: the ring becomes a chain. Split off the far end so the faces on
		# the marked edge get their own normals and the rest stays one piece.
		var cut: int = int(cuts[0])
		var straight: Array = []
		for i in range(1, count):
			straight.append(order[(cut + i) % count])
		var head: Array = [order[cut]]
		return [head, straight]
	var out: Array = []
	for ci in cuts.size():
		var from_i: int = (int(cuts[ci]) + 1) % count
		var to_i: int = int(cuts[(ci + 1) % cuts.size()])
		var piece: Array = []
		var i: int = from_i
		while true:
			piece.append(order[i])
			if i == to_i:
				break
			i = (i + 1) % count
		if not piece.is_empty():
			out.append(piece)
	return out

## True when the two faces share an edge that ends at this corner AND that edge
## carries the sharp mark.
func _faces_share_sharp_edge(fi: int, fj: int, node_pos: Vector3, sharp_keys: Dictionary) -> bool:
	var corner := _pos_key_v(node_pos)
	var face_a: MBFace = faces[fi]
	var face_b: MBFace = faces[fj]
	if face_a == null or face_b == null:
		return false
	for ea in face_a.get_edges():
		if ea.a < 0 or ea.a >= positions.size() or ea.b < 0 or ea.b >= positions.size():
			continue
		if _pos_key_v(positions[ea.a]) != corner and _pos_key_v(positions[ea.b]) != corner:
			continue
		if not sharp_keys.has(sharp_key(positions[ea.a], positions[ea.b])):
			continue
		var key := sharp_key(positions[ea.a], positions[ea.b])
		for eb in face_b.get_edges():
			if eb.a < 0 or eb.a >= positions.size() or eb.b < 0 or eb.b >= positions.size():
				continue
			if sharp_key(positions[eb.a], positions[eb.b]) == key:
				return true
	return false

## Order-independent key of an edge built from POSITIONS, not indices:## Order-independent key of an edge built from POSITIONS, not indices:## Order-independent key of an edge built from POSITIONS, not indices: index
## pairs die on every topology rebuild (and a welded corner has many indices),
## while the two points on screen survive a move.
static func sharp_key(p_a: Vector3, p_b: Vector3) -> String:
	var ka := Vector3i(roundi(p_a.x * 10000.0), roundi(p_a.y * 10000.0), roundi(p_a.z * 10000.0))
	var kb := Vector3i(roundi(p_b.x * 10000.0), roundi(p_b.y * 10000.0), roundi(p_b.z * 10000.0))
	var sa := "%d,%d,%d" % [ka.x, ka.y, ka.z]
	var sb := "%d,%d,%d" % [kb.x, kb.y, kb.z]
	return sa + "|" + sb if sa < sb else sb + "|" + sa

func has_sharp_edges() -> bool:
	return not sharp_edges.is_empty()

## Sharp edges as a set of position keys — what the normal pass and Auto Smooth
## ask "may smoothing cross here?".
func sharp_edge_keys() -> Dictionary:
	var keys := {}
	var i := 0
	while i + 1 < sharp_edges.size():
		var a: int = sharp_edges[i]
		var b: int = sharp_edges[i + 1]
		if a >= 0 and a < positions.size() and b >= 0 and b < positions.size():
			keys[sharp_key(positions[a], positions[b])] = true
		i += 2
	return keys

func is_sharp_edge(a: int, b: int) -> bool:
	if a < 0 or a >= positions.size() or b < 0 or b >= positions.size():
		return false
	var key := sharp_key(positions[a], positions[b])
	for k in sharp_edge_keys():
		if k == key:
			return true
	return false

## Adds or removes the mark on one edge (order of the two corners does not
## matter). Returns true when the mark is ON afterwards.
func set_sharp_edge(a: int, b: int, on: bool) -> bool:
	var key := sharp_key(positions[a], positions[b])
	var keep := PackedInt32Array()
	var found := false
	var i := 0
	while i + 1 < sharp_edges.size():
		var ea: int = sharp_edges[i]
		var eb: int = sharp_edges[i + 1]
		if ea >= 0 and ea < positions.size() and eb >= 0 and eb < positions.size():
			if sharp_key(positions[ea], positions[eb]) == key:
				found = true
				i += 2
				continue
			keep.append(ea)
			keep.append(eb)
		i += 2
	if on and not found:
		keep.append(a)
		keep.append(b)
	sharp_edges = keep
	return on

func clear_sharp_edges() -> void:
	sharp_edges = PackedInt32Array()

## Drops pairs whose indices no longer exist — cheap guard after deletes.
func prune_sharp_edges() -> void:
	var keep := PackedInt32Array()
	var i := 0
	var changed := false
	while i + 1 < sharp_edges.size():
		var a: int = sharp_edges[i]
		var b: int = sharp_edges[i + 1]
		if a >= 0 and a < positions.size() and b >= 0 and b < positions.size() and a != b:
			keep.append(a)
			keep.append(b)
		else:
			changed = true
		i += 2
	if changed:
		sharp_edges = keep

## Returns cached normals, calculating them on demand if empty or size mismatch.
func get_normals() -> PackedVector3Array:
	if _normals.is_empty() or _normals.size() != positions.size():
		calculate_normals()
	return _normals


## Godot's per-mesh surface limit (RenderingServer MAX_MESH_SURFACES = 256).
## The engine refuses a 257th surface with only a logged error, and the faces
## on it vanish — a mesh with more than 255 painted faces (each painted face
## is its own material, so its own surface) lost faces in the editor and in
## the shipped scene. to_array_meshes() splits past this into chunks.
const MAX_SURFACES_PER_MESH := 256
## From this many surfaces on, each surface carries only the vertices its own
## faces index. Below it every surface takes the whole vertex arrays (a cheap
## C++ copy; the duplication is at most 3x). Above it the duplication was
## surfaces x vertices: 400 painted faces on a 1,600-vertex floor uploaded
## 409,600 vertices and spent 152 ms per rebuild.
const COMPACT_SURFACES_FROM := 4

## Compiles this MBMeshData into a Godot ArrayMesh.
## If existing is provided, clears its surfaces and reuses it; otherwise instantiates a new ArrayMesh.
## Faces are grouped by submesh_index into distinct surfaces.
## A mesh needing more than MAX_SURFACES_PER_MESH surfaces only fits partly
## in one ArrayMesh: this returns the FIRST chunk — renderers use
## to_array_meshes() (MBMesh draws every chunk).
func to_array_mesh(existing: ArrayMesh = null, use_cached_indices: bool = false) -> ArrayMesh:
	return to_array_meshes(use_cached_indices, existing)[0]

## Compiles this MBMeshData into one or more ArrayMeshes of at most
## MAX_SURFACES_PER_MESH surfaces each (always at least one, possibly empty).
## `existing`, when given, is cleared and reused as the first chunk.
func to_array_meshes(use_cached_indices: bool = false, existing: ArrayMesh = null) -> Array[ArrayMesh]:
	var mesh: ArrayMesh = existing if existing != null else ArrayMesh.new()
	mesh.clear_surfaces()
	var chunks: Array[ArrayMesh] = [mesh]

	if positions.is_empty() or faces.is_empty():
		return chunks

	# Internal data is CCW-from-outside (Unity/ProBuilder convention), so
	# calculate_normals() cross products point OUTWARD. Godot front faces are
	# CW-from-outside (see ArrayMesh docs), hence the index reversal below.
	# The reversal only flips which side is culled — the outward direction is
	# a property of the geometry, so normals must NOT be negated.
	# Ground truth: Godot's own BoxMesh stores CW tris whose cross(v1-v0,
	# v2-v0) points inward, with attribute normals pointing outward.
	# get_normals() (not calculate_normals() directly): the cache may be hot
	# (incremental drag updates keep it fresh) — recompute only when stale.
	var normals: PackedVector3Array = get_normals()
	# Ensure UVs are up-to-date and non-stretching
	if textures0.size() != positions.size():
		MBUv.refresh_mesh_uvs(self)
	else:
		var needs_uv_refresh := false
		for face in faces:
			if face != null and not face.manual_uv:
				needs_uv_refresh = true
				break
		if needs_uv_refresh:
			MBUv.refresh_mesh_uvs(self)

	# MeshBuilder carries no splat masks, so no CUSTOM0 vertex channel is
	# emitted; the plumbing stays for later custom channels.
	var use_custom0 := false
	var custom0 := PackedFloat32Array()


	var src_vc: int = positions.size()
	var mirror_on: bool = mirror_enabled and src_vc > 0
	var out_positions := positions
	var out_normals := normals
	var out_uv1 := textures0
	var out_uv2 := textures1
	var out_colors := colors
	var out_tangents := tangents
	if mirror_on:
		var total: int = src_vc * 2
		out_positions = PackedVector3Array()
		out_positions.resize(total)
		out_normals = PackedVector3Array()
		out_normals.resize(total)
		for i in src_vc:
			out_positions[i] = positions[i]
			out_positions[src_vc + i] = _mirror_point(positions[i])
			out_normals[i] = normals[i]
			out_normals[src_vc + i] = _mirror_direction(normals[i])
		if textures0.size() == src_vc:
			out_uv1 = PackedVector2Array()
			out_uv1.resize(total)
			for i in src_vc:
				out_uv1[i] = textures0[i]
				out_uv1[src_vc + i] = textures0[i]
		if textures1.size() == src_vc:
			out_uv2 = PackedVector2Array()
			out_uv2.resize(total)
			for i in src_vc:
				out_uv2[i] = textures1[i]
				out_uv2[src_vc + i] = textures1[i]
		if colors.size() == src_vc:
			out_colors = PackedColorArray()
			out_colors.resize(total)
			for i in src_vc:
				out_colors[i] = colors[i]
				out_colors[src_vc + i] = colors[i]
		if tangents.size() == src_vc * 4:
			out_tangents = PackedFloat32Array()
			out_tangents.resize(total * 4)
			for i in src_vc:
				for k in 4:
					out_tangents[i * 4 + k] = tangents[i * 4 + k]
				var dir := Vector3(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2])
				var mdir := _mirror_direction(dir)
				out_tangents[(src_vc + i) * 4] = mdir.x
				out_tangents[(src_vc + i) * 4 + 1] = mdir.y
				out_tangents[(src_vc + i) * 4 + 2] = mdir.z
				# A reflection flips handedness, so the bitangent sign flips too.
				out_tangents[(src_vc + i) * 4 + 3] = -tangents[i * 4 + 3]

	var vc: int = out_positions.size()
	var has_uv1: bool = not out_uv1.is_empty() and out_uv1.size() == vc
	var has_uv2: bool = not out_uv2.is_empty() and out_uv2.size() == vc
	var has_colors: bool = not out_colors.is_empty() and out_colors.size() == vc
	var has_tangents: bool = not out_tangents.is_empty() and out_tangents.size() == vc * 4

	if not use_cached_indices or _submesh_indices_cache.is_empty():
		# Group faces by submesh_index and compile triangle index buffers
		var submesh_faces: Dictionary = {}
		var submesh_indices: Array[int] = []

		for face in faces:
			if face == null:
				continue
			var s_idx: int = face.submesh_index
			if not submesh_faces.has(s_idx):
				submesh_faces[s_idx] = [] as Array[MBFace]
				submesh_indices.append(s_idx)
			submesh_faces[s_idx].append(face)

		submesh_indices.sort()
		_submesh_keys_cache = submesh_indices
		# Mirror keeps the plain path: the compacted surface map names source
		# vertices, and the reflection lives past the source array.
		var compact := submesh_indices.size() >= COMPACT_SURFACES_FROM and not mirror_on

		for s_idx in submesh_indices:
			var group_faces: Array = submesh_faces[s_idx]
			var indices := PackedInt32Array()
			for face in group_faces:
				if face != null:
					var fi: PackedInt32Array = face.get_indexes()
					# Reverse each triangle's winding: internal data is CCW-from-outside
					# (Unity convention), Godot front faces are CW-from-outside.
					for tri_i in range(0, fi.size() - 2, 3):
						indices.append(fi[tri_i + 2])
						indices.append(fi[tri_i + 1])
						indices.append(fi[tri_i])
			# Reflection: same triangles on vertices past the source block, with
			# the winding swapped back (a reflection inverts the facing).
			if mirror_on:
				var mirrored := PackedInt32Array()
				for tri_i in range(0, indices.size() - 2, 3):
					mirrored.append(indices[tri_i] + src_vc)
					mirrored.append(indices[tri_i + 2] + src_vc)
					mirrored.append(indices[tri_i + 1] + src_vc)
				indices.append_array(mirrored)
			# Compacted surfaces index their own vertex list: `map` holds the
			# source vertex for each local one (empty = the whole arrays).
			var map := PackedInt32Array()
			if compact:
				var local_of: Dictionary = {}
				for k in range(indices.size()):
					var src: int = indices[k]
					if not local_of.has(src):
						local_of[src] = map.size()
						map.append(src)
					indices[k] = local_of[src]
			_submesh_indices_cache[s_idx] = {"indices": indices, "map": map}

	# A custom vertex channel must declare its own format through the
	# surface flags; RG_FLOAT = two full floats per vertex (the mask UV).
	var surface_flags: int = (Mesh.ARRAY_CUSTOM_RG_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
			if use_custom0 else 0
	for s_idx in _submesh_keys_cache:
		var entry: Dictionary = _submesh_indices_cache.get(s_idx, {})
		var indices: PackedInt32Array = entry.get("indices", PackedInt32Array())
		if indices.is_empty():
			continue
		var map: PackedInt32Array = entry.get("map", PackedInt32Array())

		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		if map.is_empty():
			arrays[Mesh.ARRAY_VERTEX] = out_positions
			arrays[Mesh.ARRAY_NORMAL] = out_normals
			if has_uv1:
				arrays[Mesh.ARRAY_TEX_UV] = out_uv1
			if has_uv2:
				arrays[Mesh.ARRAY_TEX_UV2] = out_uv2
			if use_custom0:
				arrays[Mesh.ARRAY_CUSTOM0] = custom0
			if has_colors:
				arrays[Mesh.ARRAY_COLOR] = out_colors
			if has_tangents:
				arrays[Mesh.ARRAY_TANGENT] = out_tangents
		else:
			_fill_compacted_arrays(arrays, map, normals, custom0, use_custom0,
					has_uv1, has_uv2, has_colors, has_tangents)
		arrays[Mesh.ARRAY_INDEX] = indices

		if mesh.get_surface_count() >= MAX_SURFACES_PER_MESH:
			mesh = ArrayMesh.new()
			chunks.append(mesh)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, surface_flags)
		var surf_idx: int = mesh.get_surface_count() - 1
		var mat: Material = null
		if s_idx >= 0 and s_idx < materials.size():
			mat = materials[s_idx]
		if mat == null and not materials.is_empty():
			mat = materials[0]
		if mat == null:
			mat = get_default_material()
		if mat != null:
			mesh.surface_set_material(surf_idx, mat)

	# Authored lightmap metadata rides on the generated ArrayMesh: the
	# LightmapGI baker reads the size hint off the mesh it bakes.
	if lightmap_size_hint != Vector2i.ZERO:
		for chunk in chunks:
			chunk.lightmap_size_hint = lightmap_size_hint

	return chunks

## Reflects a point across the object's origin on the mirror axis.
func _mirror_point(p: Vector3) -> Vector3:
	match mirror_axis:
		1:
			return Vector3(p.x, -p.y, p.z)
		2:
			return Vector3(p.x, p.y, -p.z)
	return Vector3(-p.x, p.y, p.z)

## Reflects a DIRECTION (normal, tangent) — same flip, no origin involved.
func _mirror_direction(d: Vector3) -> Vector3:
	return _mirror_point(d)

## How many surfaces the build makes: one per material slot in use.
func surface_count() -> int:
	var seen: Dictionary = {}
	for face in faces:
		if face != null:
			seen[face.submesh_index] = true
	return seen.size()

## Every triangle of the mesh as a flat position list (3 per triangle), in
## the RENDERED winding (the reversal to_array_mesh applies) — what picking
## and collision consumers need without going through the render chunks.
func get_triangle_soup() -> PackedVector3Array:
	var out := PackedVector3Array()
	var n := positions.size()
	for face in faces:
		if face == null:
			continue
		var idx: PackedInt32Array = face.get_indexes()
		for t in range(0, idx.size() - 2, 3):
			if idx[t] < n and idx[t + 1] < n and idx[t + 2] < n:
				out.append(positions[idx[t + 2]])
				out.append(positions[idx[t + 1]])
				out.append(positions[idx[t]])
	return out

## Gathers one compacted surface's vertex attributes: element i is the source
## vertex map[i] (custom0 is the flattened RG pair, two floats per vertex).
func _fill_compacted_arrays(arrays: Array, map: PackedInt32Array, normals: PackedVector3Array,
		custom0: PackedFloat32Array, use_custom0: bool, has_uv1: bool, has_uv2: bool,
		has_colors: bool, has_tangents: bool) -> void:
	var n := map.size()
	var pos := PackedVector3Array()
	pos.resize(n)
	var nrm := PackedVector3Array()
	nrm.resize(n)
	for i in range(n):
		pos[i] = positions[map[i]]
		nrm[i] = normals[map[i]]
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	if has_uv1:
		var uv := PackedVector2Array()
		uv.resize(n)
		for i in range(n):
			uv[i] = textures0[map[i]]
		arrays[Mesh.ARRAY_TEX_UV] = uv
	if has_uv2:
		var uv2 := PackedVector2Array()
		uv2.resize(n)
		for i in range(n):
			uv2[i] = textures1[map[i]]
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
	if use_custom0:
		var c0 := PackedFloat32Array()
		c0.resize(n * 2)
		for i in range(n):
			c0[i * 2] = custom0[map[i] * 2]
			c0[i * 2 + 1] = custom0[map[i] * 2 + 1]
		arrays[Mesh.ARRAY_CUSTOM0] = c0
	if has_colors:
		var col := PackedColorArray()
		col.resize(n)
		for i in range(n):
			col[i] = colors[map[i]]
		arrays[Mesh.ARRAY_COLOR] = col
	if has_tangents:
		var tan := PackedFloat32Array()
		tan.resize(n * 4)
		for i in range(n):
			for f in range(4):
				tan[i * 4 + f] = tangents[map[i] * 4 + f]
		arrays[Mesh.ARRAY_TANGENT] = tan


## Cached default material reference.
static var _cached_default_material: Material = null

## Returns the default MeshBuilder material (from EditorSettings, or the bundled checkerboard fallback).
static func get_default_material() -> Material:
	if _cached_default_material != null:
		return _cached_default_material

	var path := ""
	if Engine.is_editor_hint():
		var iface := EditorInterface
		if iface != null:
			var settings = iface.get_editor_settings()
			if settings != null and settings.has_setting("meshbuilder/materials/default_material_path"):
				path = String(settings.get_setting("meshbuilder/materials/default_material_path"))

	if path.is_empty():
		path = "res://addons/meshbuilder/materials/mb_default_material.tres"

	_cached_default_material = load_material_or_texture(path)
	return _cached_default_material

## Helper: loads a Material from path, or if path is a Texture2D, creates a StandardMaterial3D wrapping it.
static func load_material_or_texture(path: String) -> Material:
	if path.is_empty() or not ResourceLoader.exists(path):
		var fallback_path := "res://addons/meshbuilder/materials/mb_default_material.tres"
		if path != fallback_path and ResourceLoader.exists(fallback_path):
			return load(fallback_path) as Material
		return null

	var res = ResourceLoader.load(path)
	if res is Material:
		return res as Material
	elif res is Texture2D:
		var mat := StandardMaterial3D.new()
		mat.resource_name = path.get_file().get_basename().capitalize()
		mat.set_meta("source_texture_path", path)
		mat.albedo_texture = res as Texture2D
		mat.roughness = 0.8
		mat.vertex_color_use_as_albedo = true
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		# Same rule as the palette scan: a texture with transparent pixels
		# draws transparent (the retro exporters always did this from pixels).
		MBAlphaDetect.ensure_transparency(mat)
		return mat

	return null

## The face's distinct corner positions (one per weld group corner, face order).
func get_face_positions(face_index: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	if face_index < 0 or face_index >= faces.size() or faces[face_index] == null:
		return out
	for idx in faces[face_index].get_distinct_indexes():
		if idx >= 0 and idx < positions.size():
			out.append(positions[idx])
	return out

## The face's corner positions along its OUTLINE (winding order). Positions
## whose first-appearance order zigzags (generator faces built from sliver
## triangles, e.g. stair sides) need this for anything edge-based.
func get_face_outline_positions(face_index: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	if face_index < 0 or face_index >= faces.size() or faces[face_index] == null:
		return out
	for idx in faces[face_index].get_outline_indexes():
		if idx >= 0 and idx < positions.size():
			out.append(positions[idx])
	return out

## Returns the material assigned to a face, falling back to materials[0] or default material.
func get_face_material(face: MBFace) -> Material:
	if face == null:
		return null
	var idx: int = face.submesh_index
	if idx >= 0 and idx < materials.size() and materials[idx] != null:
		return materials[idx]
	# Fallback matching to_array_mesh(): use slot 0 or default material
	if not materials.is_empty() and materials[0] != null:
		return materials[0]
	return get_default_material()

## Assigns a material to multiple faces. Allocates or reuses a submesh slot.
func set_faces_material(target_faces: Array, mat: Material) -> void:
	if target_faces.is_empty():
		return

	if materials.is_empty():
		var def := get_default_material()
		materials.append(def)

	var idx := -1
	if mat != null:
		var all_faces_changing: bool = true
		for f in faces:
			if f != null and not target_faces.has(f):
				all_faces_changing = false
				break

		if all_faces_changing:
			materials = [mat]
			idx = 0
		else:
			idx = materials.find(mat)
			if idx == -1:
				var used_slots: Dictionary = {}
				for f in faces:
					if f != null and not target_faces.has(f):
						used_slots[f.submesh_index] = true
				for i in range(materials.size()):
					if not used_slots.has(i):
						materials[i] = mat
						idx = i
						break
				if idx == -1:
					idx = materials.size()
					materials.append(mat)
	else:
		idx = 0

	for f in target_faces:
		if f is MBFace:
			f.submesh_index = idx

	invalidate_caches()

## Drops the material slot at `slot` from the mesh. Faces on that slot fall back
## to slot 0 (or the default material when nothing is left), faces on later
## slots move down with it, so submesh indices stay contiguous.
func remove_material_slot(slot: int) -> bool:
	if slot < 0 or slot >= materials.size():
		return false
	materials.remove_at(slot)

	var last := materials.size()
	for f in faces:
		if f == null:
			continue
		if f.submesh_index == slot:
			f.submesh_index = 0
		elif f.submesh_index > slot:
			f.submesh_index -= 1
		if f.submesh_index >= last:
			f.submesh_index = 0

	invalidate_caches()
	return true

# ==============================================================================
# Utility: Clear
# ==============================================================================

## Clears all mesh data and invalidates caches.
func clear() -> void:
	positions.clear()
	textures0.clear()
	textures1.clear()
	lightmap_size_hint = Vector2i.ZERO
	colors.clear()
	tangents.clear()
	faces.clear()
	shared_vertices.clear()
	shared_textures.clear()
	_normals.clear()
	invalidate_caches()

# ==============================================================================
# Utility: Cube Builder
# ==============================================================================

## Creates a MBMeshData representing a unit cube centered at origin.
## 8 shared vertex positions, 6 faces (quads, each as 2 triangles = 6 indices per face).
## Total: 24 distinct vertices (4 per face), 36 indices, 6 faces.
static func create_cube(size: float = 1.0) -> MBMeshData:
	var mesh_data := MBMeshData.new()
	var h: float = size * 0.5

	# 24 vertex positions (4 per face, 6 faces)
	# Right-handed Y-up coordinates, CCW winding looking from outside at face:
	mesh_data.positions = PackedVector3Array([
		# Face 0: Front (Z = -h)
		Vector3(h, -h, -h), Vector3(-h, -h, -h), Vector3(-h, h, -h), Vector3(h, h, -h),
		# Face 1: Back (Z = +h)
		Vector3(-h, -h, h), Vector3(h, -h, h), Vector3(h, h, h), Vector3(-h, h, h),
		# Face 2: Left (X = -h)
		Vector3(-h, -h, -h), Vector3(-h, -h, h), Vector3(-h, h, h), Vector3(-h, h, -h),
		# Face 3: Right (X = +h)
		Vector3(h, -h, h), Vector3(h, -h, -h), Vector3(h, h, -h), Vector3(h, h, h),
		# Face 4: Top (Y = +h)
		Vector3(-h, h, -h), Vector3(-h, h, h), Vector3(h, h, h), Vector3(h, h, -h),
		# Face 5: Bottom (Y = -h)
		Vector3(-h, -h, h), Vector3(-h, -h, -h), Vector3(h, -h, -h), Vector3(h, -h, h),
	])

	# 24 UVs (4 per face, matching 0..3 local quad vertex order)
	var face_uvs: PackedVector2Array = PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(1.0, 0.0),
		Vector2(1.0, 1.0),
		Vector2(0.0, 1.0),
	])
	# Face 1 (Back, Z = +h) is flipped horizontally (1.0 - u) so it lines up with Top, Left, and Right
	var back_uvs: PackedVector2Array = PackedVector2Array([
		Vector2(1.0, 0.0),
		Vector2(0.0, 0.0),
		Vector2(0.0, 1.0),
		Vector2(1.0, 1.0),
	])
	mesh_data.textures0 = PackedVector2Array()
	for f in range(6):
		if f == 1:
			mesh_data.textures0.append_array(back_uvs)
		else:
			mesh_data.textures0.append_array(face_uvs)

	# 6 Faces (each 2 triangles = 6 indices)
	mesh_data.faces = []
	for i in range(6):
		var base: int = i * 4
		var face := MBFace.new(PackedInt32Array([
			base + 0, base + 1, base + 2,
			base + 2, base + 3, base + 0
		]))
		mesh_data.faces.append(face)

	# 8 Shared vertex groups (one per 3D corner, each containing 3 vertices from adjacent faces)
	mesh_data.shared_vertices = [
		MBSharedVertex.new(PackedInt32Array([1, 8, 21])),   # Corner (-h, -h, -h)
		MBSharedVertex.new(PackedInt32Array([0, 13, 22])),  # Corner (+h, -h, -h)
		MBSharedVertex.new(PackedInt32Array([2, 11, 16])),  # Corner (-h, +h, -h)
		MBSharedVertex.new(PackedInt32Array([3, 14, 19])),  # Corner (+h, +h, -h)
		MBSharedVertex.new(PackedInt32Array([4, 9, 20])),   # Corner (-h, -h, +h)
		MBSharedVertex.new(PackedInt32Array([5, 12, 23])),  # Corner (+h, -h, +h)
		MBSharedVertex.new(PackedInt32Array([7, 10, 17])),  # Corner (-h, +h, +h)
		MBSharedVertex.new(PackedInt32Array([6, 15, 18])),  # Corner (+h, +h, +h)
	]

	mesh_data.shared_textures = []
	mesh_data.texture_anchor = Vector3(-h, -h, -h)
	mesh_data.has_texture_anchor = true
	mesh_data.invalidate_caches()
	return mesh_data
