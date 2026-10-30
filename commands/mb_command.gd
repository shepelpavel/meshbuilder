## MBCommand — Base class for all undoable MeshBuilder editing commands.
##
## Mesh editing operations extend MBCommand and implement do_it() and undo_it().
## Commands follow the "snapshot-once" pattern:
## 1. The pre-operation mesh state is snapshotted during command construction / setup.
## 2. do_it() applies modifications deterministically from the snapshot + parameters,
##    ensuring that repeated redo operations produce identical, correct results.
## 3. undo_it() restores the pre-operation snapshot into the target mesh resource.
##
## Integration with Godot's UndoRedo system:
## - add_to_undo_manager() accepts an EditorUndoRedoManager (in editor) or duck-typed
##   undo manager object and registers do_it / undo_it actions.
@tool
class_name MBCommand
extends RefCounted

## Human-readable action name displayed in the editor Undo/Redo history.
var command_name: String = "MeshBuilder Command"

## Optional logger for telemetry and debugging undo operations.
var logger: MBLogger = null

## Applies the command action. Subclasses must override this method.
## Should apply modifications deterministically from the initial snapshot.
func do_it() -> void:
	pass

## Reverts the command action. Subclasses must override this method.
## Should restore the target mesh data to its pre-operation snapshot state.
func undo_it() -> void:
	pass

## Registers this command with Godot's undo manager.
## Parameter is typed as Object to avoid compile-time dependency on EditorUndoRedoManager
## in headless / runtime environments.
func add_to_undo_manager(undo: Object) -> void:
	if undo == null:
		return
	undo.create_action(command_name)
	undo.add_do_method(self, "do_it")
	undo.add_undo_method(self, "undo_it")
	undo.commit_action()

## Creates a deep copy of the given MBMeshData resource — an UNDO SNAPSHOT.
## All vertex attributes, faces, and shared vertex groups are cloned. Splat
## materials are cloned COLD so undo snapshots never pin GPU copies of them
## (copy-on-write, so unchanged masks cost nothing) and no GPU texture is
## created. A snapshot is restored through `restore_mesh_data`, which makes
## the materials live again; code that renders a copy directly must use
## `copy_mesh_data_live` instead.
static func copy_mesh_data(source: MBMeshData) -> MBMeshData:
	return _copy_mesh_data(source, true)

## A copy meant to be RENDERED (assigned straight to a MBMesh): splat
## materials get their GPU textures.
static func copy_mesh_data_live(source: MBMeshData) -> MBMeshData:
	return _copy_mesh_data(source, false)

static func _copy_mesh_data(source: MBMeshData, cold: bool) -> MBMeshData:
	if source == null:
		return null

	var copy := MBMeshData.new()
	copy.positions = source.positions.duplicate()
	copy.textures0 = source.textures0.duplicate()
	copy.textures1 = source.textures1.duplicate()
	copy.lightmap_size_hint = source.lightmap_size_hint
	copy.colors = source.colors.duplicate()
	copy.tangents = source.tangents.duplicate()
	copy.materials = source.materials.duplicate()

	var new_faces: Array[MBFace] = []
	for face in source.faces:
		if face != null:
			new_faces.append(face.duplicate_face())
		else:
			new_faces.append(null)
	copy.faces = new_faces

	var new_sv: Array[MBSharedVertex] = []
	for sv in source.shared_vertices:
		if sv != null:
			new_sv.append(sv.duplicate_shared())
		else:
			new_sv.append(null)
	copy.shared_vertices = new_sv

	var new_st: Array[MBSharedVertex] = []
	for st in source.shared_textures:
		if st != null:
			new_st.append(st.duplicate_shared())
		else:
			new_st.append(null)
	copy.shared_textures = new_st

	# Shape bookkeeping travels with snapshots so undo/redo never loses the
	# shape identity / editability of a factory-created mesh.
	copy.shape_id = source.shape_id
	copy.shape_params = source.shape_params.duplicate(true)
	copy.shape_edited = source.shape_edited
	copy.texture_anchor = source.texture_anchor
	copy.has_texture_anchor = source.has_texture_anchor
	copy.mirror_enabled = source.mirror_enabled
	copy.mirror_axis = source.mirror_axis
	copy.invalidate_caches()
	return copy

## Deep copies snapshot data back into an existing target MBMeshData resource.
## Keeps object identity of target intact so references (such as MBMesh.mb_mesh_data) remain valid.
static func restore_mesh_data(target: MBMeshData, snapshot: MBMeshData) -> void:
	if target == null or snapshot == null:
		return

	target.positions = snapshot.positions.duplicate()
	target.textures0 = snapshot.textures0.duplicate()
	target.textures1 = snapshot.textures1.duplicate()
	target.lightmap_size_hint = snapshot.lightmap_size_hint
	target.colors = snapshot.colors.duplicate()
	target.tangents = snapshot.tangents.duplicate()
	target.materials = snapshot.materials.duplicate()

	var new_faces: Array[MBFace] = []
	for face in snapshot.faces:
		if face != null:
			new_faces.append(face.duplicate_face())
		else:
			new_faces.append(null)
	target.faces = new_faces

	var new_sv: Array[MBSharedVertex] = []
	for sv in snapshot.shared_vertices:
		if sv != null:
			new_sv.append(sv.duplicate_shared())
		else:
			new_sv.append(null)
	target.shared_vertices = new_sv

	var new_st: Array[MBSharedVertex] = []
	for st in snapshot.shared_textures:
		if st != null:
			new_st.append(st.duplicate_shared())
		else:
			new_st.append(null)
	target.shared_textures = new_st

	target.shape_id = snapshot.shape_id
	target.shape_params = snapshot.shape_params.duplicate(true)
	target.shape_edited = snapshot.shape_edited
	target.texture_anchor = snapshot.texture_anchor
	target.has_texture_anchor = snapshot.has_texture_anchor
	target.mirror_enabled = snapshot.mirror_enabled
	target.mirror_axis = snapshot.mirror_axis

	target.invalidate_caches()
