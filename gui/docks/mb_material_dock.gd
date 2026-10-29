## MBMaterialDock — палитра материалов ВЫДЕЛЕННОГО меша.
##
## Карточки — это материалы самого меша (его слоты `materials`), а не скан
## проекта: у каждого меша свой набор, и в палитре нет ничего, чего он не
## использует. `+ Add` добавляет материал в этот меш, клик по карточке
## назначает его выделенным граням (в Object-режиме — всем).
@tool
class_name MBMaterialDock
extends PanelContainer

const CARD_SIZE := 64

var plugin: Object = null
var editor: MBEditor = null:
	set = set_editor

var _vbox: VBoxContainer
var _material_grid: HFlowContainer
var _status_label: Label
var _file_dialog: EditorFileDialog
var _context_menu: PopupMenu
var _context_material: Material = null
var _syncing: bool = false
var _hint_timer: Timer = null

## Materials of the mesh the palette is showing (mirrors its `materials`).
var _mesh_materials: Array[Material] = []
## Instance id of the mesh the cards belong to (rebuild trigger).
var _shown_mesh_id: int = 0

# ==============================================================================
# Lifecycle
# ==============================================================================

func _init() -> void:
	name = "MaterialPalette"
	custom_minimum_size = Vector2(250, 200)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

func _ready() -> void:
	_build_ui()
	refresh_materials()
	sync_selection()

func set_editor(val: MBEditor) -> void:
	if editor == val:
		return
	if editor != null and editor.selection != null:
		if editor.selection.selection_changed.is_connected(sync_selection):
			editor.selection.selection_changed.disconnect(sync_selection)
	editor = val
	if editor != null and editor.selection != null:
		if not editor.selection.selection_changed.is_connected(sync_selection):
			editor.selection.selection_changed.connect(sync_selection)
	refresh_materials()
	sync_selection()

# ==============================================================================
# UI
# ==============================================================================

func _build_ui() -> void:
	for c in get_children():
		c.queue_free()

	_vbox = VBoxContainer.new()
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_vbox)

	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "Mesh Materials"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.tooltip_text = "Materials of the selected mesh — every mesh keeps its own set"
	header.add_child(title)

	var btn_add := Button.new()
	btn_add.text = "+ Add"
	btn_add.tooltip_text = "Add a material to the selected mesh…"
	btn_add.pressed.connect(_on_add_material_pressed)
	header.add_child(btn_add)

	var btn_refresh := Button.new()
	btn_refresh.text = "↺"
	btn_refresh.tooltip_text = "Re-read the material list from the selected mesh"
	btn_refresh.pressed.connect(refresh_materials)
	header.add_child(btn_refresh)
	_vbox.add_child(header)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 100)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_vbox.add_child(scroll)

	_material_grid = HFlowContainer.new()
	_material_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_material_grid)

	_vbox.add_child(HSeparator.new())

	_status_label = Label.new()
	_status_label.text = "No MBMesh selected"
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	_vbox.add_child(_status_label)

# ==============================================================================
# Palette contents: the ACTIVE MESH's materials
# ==============================================================================

## Rebuilds the cards from the active mesh's own material list. Nothing is
## scanned or pulled from the project — a mesh shows exactly the materials it
## carries, and `+ Add` appends to that list.
func refresh_materials() -> void:
	var mesh := _active_mesh()
	_mesh_materials.clear()
	_shown_mesh_id = mesh.get_instance_id() if mesh != null else 0
	if mesh != null and mesh.mb_mesh_data != null:
		for mat in mesh.mb_mesh_data.materials:
			if mat != null and not _mesh_materials.has(mat):
				_mesh_materials.append(mat)
	_rebuild_material_grid()
	if _hint_timer == null or _hint_timer.is_stopped():
		_update_status()

func _active_mesh() -> MBMesh:
	if editor == null:
		return null
	return editor.active_mesh

func _rebuild_material_grid() -> void:
	if _material_grid == null:
		return
	for c in _material_grid.get_children():
		_material_grid.remove_child(c)
		c.queue_free()
	for mat in _mesh_materials:
		if mat != null:
			_material_grid.add_child(_create_material_card(mat))

func _create_material_card(mat: Material) -> Control:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(CARD_SIZE, CARD_SIZE)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.clip_text = true

	var mat_name := _material_name(mat)
	btn.tooltip_text = "%s\nLeft-click: apply to selected face(s)\nRight-click: menu" % mat_name

	var tex := _extract_texture(mat)
	if tex != null:
		btn.icon = tex
		btn.expand_icon = true
	elif mat is StandardMaterial3D:
		btn.text = mat_name
		btn.modulate = (mat as StandardMaterial3D).albedo_color
	else:
		btn.text = mat_name

	btn.pressed.connect(func(): _apply_material_to_selection(mat))
	btn.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			_show_context_menu(mat, btn.get_global_mouse_position())
	)
	btn.set_script(preload("res://addons/meshbuilder/gui/docks/mb_material_card_drag.gd"))
	btn.set("material_resource", mat)
	return btn

func _material_name(mat: Material) -> String:
	var mat_name := mat.resource_name
	if mat_name.is_empty():
		mat_name = mat.resource_path.get_file().get_basename()
	if mat_name.is_empty():
		mat_name = "Material"
	return mat_name

func _extract_texture(mat: Material) -> Texture2D:
	if mat is StandardMaterial3D and (mat as StandardMaterial3D).albedo_texture != null:
		return (mat as StandardMaterial3D).albedo_texture
	if mat is ShaderMaterial:
		var tex = (mat as ShaderMaterial).get_shader_parameter("base_texture")
		if tex is Texture2D:
			return tex
	return null

func _show_context_menu(mat: Material, pos: Vector2) -> void:
	_context_material = mat
	if _context_menu == null:
		_context_menu = PopupMenu.new()
		_context_menu.name = "MaterialContextMenu"
		_context_menu.id_pressed.connect(_on_context_menu_id_pressed)
		add_child(_context_menu)
	_context_menu.clear()
	_context_menu.add_item("Apply to Selection", 1)
	_context_menu.add_separator()
	_context_menu.add_item("Remove from Mesh", 3)
	_context_menu.add_item("Copy Path", 2)
	_context_menu.popup(Rect2i(Vector2i(pos), Vector2i(190, 90)))

func _on_context_menu_id_pressed(id: int) -> void:
	if _context_material == null:
		return
	match id:
		1:
			_apply_material_to_selection(_context_material)
		2:
			DisplayServer.clipboard_set(_context_material.resource_path)
		3:
			_remove_material_from_mesh(_context_material)

# ==============================================================================
# Adding a material — to THIS mesh only
# ==============================================================================

func _on_add_material_pressed() -> void:
	if _active_mesh() == null:
		_update_status()
		return
	if _file_dialog == null:
		_file_dialog = EditorFileDialog.new()
		_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.add_filter("*.tres, *.material, *.png, *.jpg, *.jpeg, *.webp", "Materials & Textures")
		_file_dialog.file_selected.connect(_on_file_dialog_selected)
		add_child(_file_dialog)
	_file_dialog.popup_file_dialog()

func _on_file_dialog_selected(path: String) -> void:
	var mesh := _active_mesh()
	if mesh == null or mesh.mb_mesh_data == null:
		return
	var mat := _material_from_path(path)
	if mat == null:
		return
	# The same file must not land in the mesh twice: a `.tres` loads as the very
	# same resource, a texture gets a fresh wrapper each time — match it by texture.
	var existing := _find_same_material(mesh, mat)
	if existing != null:
		_flash_status("%s already has this material — nothing to add" % mesh.name)
		return
	_add_material_to_mesh(mesh, mat)

func _find_same_material(mesh: MBMesh, mat: Material) -> Material:
	for m in mesh.mb_mesh_data.materials:
		if m == mat:
			return m
	if mat is StandardMaterial3D:
		var tex := (mat as StandardMaterial3D).albedo_texture
		if tex != null:
			for m in mesh.mb_mesh_data.materials:
				if m is StandardMaterial3D and (m as StandardMaterial3D).albedo_texture != null:
					if (m as StandardMaterial3D).albedo_texture.resource_path == tex.resource_path:
						return m
	return null

## Drops the material from the mesh (its slot) as one undoable step; faces that
## used it fall back to the first slot.
func _remove_material_from_mesh(mat: Material) -> void:
	var mesh := _active_mesh()
	if mesh == null or mesh.mb_mesh_data == null or mat == null:
		return
	var slot := mesh.mb_mesh_data.materials.find(mat)
	if slot < 0:
		return

	var data := mesh.mb_mesh_data
	var before := MBCommand.copy_mesh_data(data)
	var removed_name := _material_name(mat)
	if not data.remove_material_slot(slot):
		return
	data.emit_changed()
	var after := MBCommand.copy_mesh_data(data)
	_commit_mesh_change("Remove Material", mesh, before, after)
	mesh.rebuild()
	mesh.update_gizmos()
	refresh_materials()
	_flash_status("Removed %s from %s" % [removed_name, mesh.name])

## Appends the material to the mesh as one undoable step: a bare `append` on
## a Resource-owned array neither marks the scene modified nor can be undone.
func _add_material_to_mesh(mesh: MBMesh, mat: Material) -> void:
	var data := mesh.mb_mesh_data
	var before := MBCommand.copy_mesh_data(data)
	data.materials.append(mat)
	data.emit_changed()
	var after := MBCommand.copy_mesh_data(data)
	_commit_mesh_change("Add Material", mesh, before, after)
	mesh.rebuild()
	mesh.update_gizmos()
	refresh_materials()

## Snapshot pair -> one editor undo action (same pattern as the plugin's own
## mesh operations).
func _commit_mesh_change(action_name: String, mesh: MBMesh, before: MBMeshData, after: MBMeshData) -> void:
	if plugin == null or not plugin.has_method("get_undo_redo"):
		return
	var undo = plugin.get_undo_redo()
	if undo == null:
		return
	undo.create_action(action_name, UndoRedo.MERGE_DISABLE, mesh)
	undo.add_do_method(plugin, "_restore_mesh_snapshot", mesh.get_instance_id(), after)
	undo.add_undo_method(plugin, "_restore_mesh_snapshot", mesh.get_instance_id(), before)
	undo.commit_action()

## `.tres`/`.material` loads as is; a texture becomes a wrapped
## StandardMaterial3D (alpha read from the image so cut-outs look right).
func _material_from_path(path: String) -> Material:
	if not ResourceLoader.exists(path):
		return null
	var res = ResourceLoader.load(path)
	if res is Material:
		return res
	if res is Texture2D:
		var mat := StandardMaterial3D.new()
		mat.resource_name = path.get_file().get_basename().capitalize()
		mat.albedo_texture = res
		mat.roughness = 0.8
		mat.vertex_color_use_as_albedo = true
		MBAlphaDetect.ensure_transparency(mat)
		return mat
	return null

# ==============================================================================
# Selection state
# ==============================================================================

func sync_selection() -> void:
	if _syncing:
		return
	_syncing = true
	if _palette_is_stale():
		refresh_materials()
	else:
		_update_status()
	_syncing = false

## Cards are stale when another mesh is active or its material list changed
## (an operation, an undo or a drop can add or drop a slot).
func _palette_is_stale() -> bool:
	var mesh := _active_mesh()
	if mesh == null:
		return _shown_mesh_id != 0
	if mesh.get_instance_id() != _shown_mesh_id:
		return true
	if mesh.mb_mesh_data == null:
		return not _mesh_materials.is_empty()
	var mats := mesh.mb_mesh_data.materials
	if mats.size() != _mesh_materials.size():
		return true
	for i in mats.size():
		if mats[i] != _mesh_materials[i]:
			return true
	return false

## Short-lived message that the next `_update_status()` must not swallow.
func _flash_status(text: String) -> void:
	if _status_label == null:
		return
	_status_label.text = text
	if _hint_timer == null:
		_hint_timer = Timer.new()
		_hint_timer.one_shot = true
		_hint_timer.timeout.connect(_on_hint_timeout)
		add_child(_hint_timer)
	_hint_timer.start(3.0)

func _on_hint_timeout() -> void:
	_update_status()

func _update_status() -> void:
	if _status_label == null:
		return
	var mesh := _active_mesh()
	if mesh == null or mesh.mb_mesh_data == null:
		_status_label.text = "No MBMesh selected — materials are added per mesh"
		return
	var slots := _mesh_materials.size()
	var faces := 0
	if editor != null and editor.selection != null:
		faces = editor.selection.selected_faces.size()
	if faces > 0:
		_status_label.text = "%d face(s) · %d material(s) on %s" % [faces, slots, mesh.name]
	elif editor != null and editor.select_mode == MBEditor.SelectMode.OBJECT:
		_status_label.text = "%d material(s) · applies to ALL faces of %s" % [slots, mesh.name]
	else:
		_status_label.text = "%d material(s) on %s · no faces selected" % [slots, mesh.name]

# ==============================================================================
# Applying to faces
# ==============================================================================

func _apply_material_to_selection(mat: Material) -> void:
	var mesh := _active_mesh()
	if mesh == null or mesh.mb_mesh_data == null or mat == null:
		return

	var target_faces: Array[MBFace] = []
	var sel_faces: PackedInt32Array = editor.selection.selected_faces if editor != null and editor.selection != null else PackedInt32Array()
	if not sel_faces.is_empty():
		for fi in sel_faces:
			if fi >= 0 and fi < mesh.mb_mesh_data.faces.size():
				target_faces.append(mesh.mb_mesh_data.faces[fi])
	else:
		for f in mesh.mb_mesh_data.faces:
			if f != null:
				target_faces.append(f)
	if target_faces.is_empty():
		return

	if plugin != null and plugin.has_method("apply_faces_material"):
		plugin.apply_faces_material(mesh, target_faces, mat)
	else:
		mesh.mb_mesh_data.set_faces_material(target_faces, mat)
		mesh.rebuild()
		mesh.update_gizmos()
	refresh_materials()
