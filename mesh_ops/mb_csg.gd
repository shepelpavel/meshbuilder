## MBCsg — Constructive Solid Geometry Boolean operations for MeshBuilder.
##
## Supports Union, Subtract, and Intersect operations between two MBMeshData operands
## using Godot's CSG kernel with clean conversion back to MBMeshData.
@tool
class_name MBCsg
extends RefCounted

enum BooleanOp {
	UNION,
	INTERSECT,
	SUBTRACT,
}

## Performs a CSG Boolean operation between mesh_a and mesh_b (with relative transform applied to b).
## Returns a Dictionary with:
## - "success": bool
## - "mesh_data": MBMeshData (on success)
## - "error": String (on failure)
static func perform_boolean(mesh_a: MBMeshData, mesh_b: MBMeshData, op: BooleanOp,
		rel_transform_b: Transform3D = Transform3D.IDENTITY,
		tree: SceneTree = null) -> Dictionary:
	if mesh_a == null or mesh_a.faces.is_empty():
		return {"success": false, "error": "Mesh A is empty or null"}
	if mesh_b == null or mesh_b.faces.is_empty():
		return {"success": false, "error": "Mesh B is empty or null"}

	# Pre-flight watertightness on the TRIANGLE MESH, not on the face outlines:
	# faces can join outline-to-outline while the triangles underneath still
	# leave slits (a fan-shaped n-gon, a T-junction). Godot's CSG kernel is a
	# manifold solver — fed a mesh with slits it returns nothing at all, which
	# used to surface as "Subtract left nothing" on perfectly good-looking props.
	var open_a := _mesh_open_edges(mesh_a)
	if open_a > 0:
		return {"success": false, "error": "Mesh A is not watertight: %d open edge(s) in the triangle mesh — CSG needs a closed solid (fix the hole with Fill Hole or Merge by Distance)" % open_a}
	var open_b := _mesh_open_edges(mesh_b)
	if open_b > 0:
		return {"success": false, "error": "Mesh B is not watertight: %d open edge(s) in the triangle mesh — CSG needs a closed solid (fix the hole with Fill Hole or Merge by Distance)" % open_b}
	var boundary_a := MBSelectionOps.select_boundary_edges(mesh_a)
	var boundary_b := MBSelectionOps.select_boundary_edges(mesh_b)
	if not boundary_a.is_empty():
		return {"success": false, "error": "Mesh A is non-manifold (has %d open boundary edges)" % boundary_a.size()}
	if not boundary_b.is_empty():
		return {"success": false, "error": "Mesh B is non-manifold (has %d open boundary edges)" % boundary_b.size()}

	# A CSG operand is ONE mesh, which holds at most 256 surfaces (one per
	# material): past that the extra faces would silently drop out of the
	# result. Refuse instead of returning a mesh with holes.
	for operand in [["A", mesh_a], ["B", mesh_b]]:
		if (operand[1] as MBMeshData).surface_count() > MBMeshData.MAX_SURFACES_PER_MESH:
			return {"success": false, "error": "Mesh %s has more than %d materials (painted faces each count as one) — too many for a boolean" % [operand[0], MBMeshData.MAX_SURFACES_PER_MESH]}

	# Two boxes whose AABBs do not touch cannot intersect, and that is sound for
	# any shape — refuse before paying for the bake. A containment test is NOT
	# sound the same way (a concave target, or a scaled target node that inflates
	# the cutter's box, "contains" without being covered), so Subtract is left to
	# the kernel and only reported afterwards.
	if op == BooleanOp.INTERSECT:
		var box_a := _world_aabb(mesh_a, Transform3D.IDENTITY)
		var box_b := _world_aabb(mesh_b, rel_transform_b)
		if not box_a.intersects(box_b):
			return {"success": false, "error": "Intersect is empty: the two meshes share no volume — they have to overlap"}

	var csg := CSGCombiner3D.new()

	var csg_a := CSGMesh3D.new()
	csg_a.mesh = mesh_a.to_array_mesh()
	csg.add_child(csg_a)

	var csg_b := CSGMesh3D.new()
	csg_b.mesh = mesh_b.to_array_mesh()
	csg_b.transform = rel_transform_b

	match op:
		BooleanOp.UNION:
			csg_b.operation = CSGShape3D.OPERATION_UNION
		BooleanOp.INTERSECT:
			csg_b.operation = CSGShape3D.OPERATION_INTERSECTION
		BooleanOp.SUBTRACT:
			csg_b.operation = CSGShape3D.OPERATION_SUBTRACTION

	csg.add_child(csg_b)

	# CSG shapes require being inside the scene tree to evaluate their brushes
	var cleanup_parent: Node = null
	if tree != null and tree.root != null:
		tree.root.add_child(csg)
		cleanup_parent = tree.root
	elif Engine.get_main_loop() is SceneTree:
		var st := Engine.get_main_loop() as SceneTree
		if st.root != null:
			st.root.add_child(csg)
			cleanup_parent = st.root

	csg._update_shape()
	var baked: ArrayMesh = csg.bake_static_mesh()

	if cleanup_parent != null:
		cleanup_parent.remove_child(csg)
	csg_a.free()
	csg_b.free()
	csg.free()

	if baked == null or baked.get_surface_count() == 0:
		# An empty bake is a real outcome, not a crash: Subtract gone wrong
		# (the cutter swallowed the target) and Intersect with no shared volume
		# both land here. Say which one it is instead of "empty geometry".
		match op:
			BooleanOp.SUBTRACT:
				return {"success": false, "error": "Subtract left nothing — either the cutter covers the whole target, or the target is not a valid solid (self-intersecting geometry from earlier edits or a baked CSG). Re-bake it from its CSG source (MeshBuilderize) and cut that"}
			BooleanOp.INTERSECT:
				return {"success": false, "error": "Intersect is empty: the two meshes share no volume — they have to overlap"}
			_:
				return {"success": false, "error": "Union produced no geometry — check that both meshes are closed"}

	var dummy := MeshInstance3D.new()
	dummy.mesh = baked
	var converted: MBMesh = MBObjectOps.probuilderize(dummy)
	dummy.free()

	if converted == null or converted.mb_mesh_data == null:
		return {"success": false, "error": "Failed to convert CSG result to MBMeshData"}

	var result_data: MBMeshData = converted.mb_mesh_data
	converted.free()
	# The CSG kernel outputs triangles, so every quad of the operands comes back
	# split — on faces the cut never touched too. Put the coplanar pieces back
	# together; whatever the cut really shaped stays as it came out.
	var dissolved := MBMeshOps.rebuild_coplanar_quads(result_data)
	result_data.calculate_normals()
	return {"success": true, "mesh_data": result_data, "faces_merged": int(dissolved.get("merged", 0))}

## World-space bounds of a mesh data under `xf`.
static func _world_aabb(mesh_data: MBMeshData, xf: Transform3D) -> AABB:
	var box := AABB()
	var first := true
	for p in mesh_data.positions:
		var w: Vector3 = xf * p
		if first:
			box = AABB(w, Vector3.ZERO)
			first = false
		else:
			box = box.expand(w)
	# A zero-size extent (a flat mesh) would never intersect anything.
	box = box.grow(0.0001)
	return box

## Open edges of the TRIANGLE mesh (each corner welded by position first, since
## the data stores a private copy of a corner per face). 0 = watertight.
static func _mesh_open_edges(mesh_data: MBMeshData) -> int:
	var ids := {}
	var triangles := PackedInt32Array()
	for face in mesh_data.faces:
		if face == null:
			continue
		var idx := face.get_indexes()
		var k := 0
		while k + 2 < idx.size():
			for corner in [idx[k], idx[k + 1], idx[k + 2]]:
				var p: Vector3 = mesh_data.positions[corner]
				# 0.1 mm buckets: sub-micron rounding differences between corners
				# that sit at the same place are welding noise, not holes.
				var key := Vector3i(roundi(p.x * 10000.0), roundi(p.y * 10000.0), roundi(p.z * 10000.0))
				if not ids.has(key):
					ids[key] = ids.size()
				triangles.append(int(ids[key]))
			k += 3
	var edges := {}
	var t := 0
	while t + 2 < triangles.size():
		for pair in [[0, 1], [1, 2], [2, 0]]:
			var a: int = triangles[t + pair[0]]
			var b: int = triangles[t + pair[1]]
			var key := "%d|%d" % [mini(a, b), maxi(a, b)]
			edges[key] = int(edges.get(key, 0)) + 1
		t += 3
	var open := 0
	for key in edges:
		if int(edges[key]) == 1:
			open += 1
	return open

