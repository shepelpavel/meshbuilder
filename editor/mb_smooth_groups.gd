## MBSmoothGroups — Surface smoothing group management and auto-smoothing for MeshBuilder.
##
## Manages smoothing groups 1..30 per face (0 = hard/none) and provides dihedral angle
## auto-smoothing and normal line visualization.
@tool
class_name MBSmoothGroups
extends RefCounted

const MIN_GROUP := 0
const MAX_GROUP := 30

## Sets the smoothing group for the specified faces (0 = hard, 1..30 = smooth).
static func set_smoothing_group(mesh_data: MBMeshData, faces: PackedInt32Array, group: int) -> void:
	if mesh_data == null or faces.is_empty():
		return
	var grp := clampi(group, MIN_GROUP, MAX_GROUP)
	for fi in faces:
		if fi >= 0 and fi < mesh_data.faces.size() and mesh_data.faces[fi] != null:
			mesh_data.faces[fi].smoothing_group = grp
	mesh_data.calculate_normals()
	mesh_data.shape_edited = true

## Clears smoothing groups on specified faces (sets to 0 / hard).
static func clear_smoothing_groups(mesh_data: MBMeshData, faces: PackedInt32Array) -> void:
	set_smoothing_group(mesh_data, faces, 0)

## Marks the selected EDGES sharp (or clears the mark). A sharp edge is never
## crossed by Auto Smooth and the faces on its sides never average normals
## through it, whatever the dihedral angle says. Returns true when the mark is ON
## afterwards.
static func set_edges_sharp(mesh_data: MBMeshData, edges: Array[MBEdge], value: bool) -> bool:
	if mesh_data == null or edges.is_empty():
		return false
	for e in edges:
		if e == null or not e.is_valid():
			continue
		mesh_data.set_sharp_edge(e.a, e.b, value)
	mesh_data.calculate_normals()
	mesh_data.shape_edited = true
	return value

## True when AT LEAST ONE of the given edges carries the sharp mark. The Sharp
## button uses this to behave like a real toggle: a mixed selection (some marked,
## some not) gets its marks CLEARED, so pressing the button twice always ends with
## no marks — never with "I pressed it again and it stayed sharp".
static func any_edge_sharp(mesh_data: MBMeshData, edges: Array[MBEdge]) -> bool:
	if mesh_data == null or edges.is_empty():
		return false
	var keys := mesh_data.sharp_edge_keys()
	for e in edges:
		if e == null or not e.is_valid():
			continue
		if keys.has(MBMeshData.sharp_key(mesh_data.positions[e.a], mesh_data.positions[e.b])):
			return true
	return false

## True when every one of the given edges already carries the sharp mark.
static func all_edges_sharp(mesh_data: MBMeshData, edges: Array[MBEdge]) -> bool:
	if mesh_data == null or edges.is_empty():
		return false
	var keys := mesh_data.sharp_edge_keys()
	for e in edges:
		if e == null or not e.is_valid():
			return false
		if not keys.has(MBMeshData.sharp_key(mesh_data.positions[e.a], mesh_data.positions[e.b])):
			return false
	return true

## Smooths EVERYTHING that is not marked sharp: the whole mesh goes into one
## smoothing group and the only thing that ever breaks it is a sharp edge. No
## dihedral-angle threshold any more — a cylinder's side and a bevel ring stay
## smooth whatever their angle, and creases are something you ask for by hand.
## Returns 1 when the mesh got the smooth group, 0 when there was nothing to do.
static func auto_smooth(mesh_data: MBMeshData, _threshold_deg: float = 45.0) -> int:
	if mesh_data == null or mesh_data.faces.is_empty():
		return 0
	for face in mesh_data.faces:
		if face != null:
			face.smoothing_group = 1
	mesh_data.calculate_normals()
	mesh_data.shape_edited = true
	return 1

## Generates preview line segments## Generates preview line segments for vertex/face normals [start, end, start, end, ...].
static func get_normal_preview_lines(mesh_data: MBMeshData, length: float = 0.2) -> PackedVector3Array:
	if mesh_data == null or mesh_data.positions.is_empty():
		return PackedVector3Array()

	var normals := mesh_data.get_normals()
	var lines := PackedVector3Array()
	lines.resize(mesh_data.positions.size() * 2)

	for i in range(mesh_data.positions.size()):
		var p: Vector3 = mesh_data.positions[i]
		var n: Vector3 = normals[i]
		lines[i * 2] = p
		lines[i * 2 + 1] = p + n * length

	return lines
