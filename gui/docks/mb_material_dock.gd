## MBMaterialDock — палитра материалов проекта для MeshBuilder.
##
## Клик по карточке применяет материал к выбранным граням (в объектном режиме —
## ко всем). Контекстное меню: материал по умолчанию для новых фигур, применение
## к выделению, спрайт-текстура, копирование пути. Тайлинг UV живёт во вкладке
## UV Editor.
@tool
class_name MBMaterialDock
extends PanelContainer

const DEFAULT_MATERIAL_PATH := "res://addons/meshbuilder/materials/mb_default_material.tres"
const SETTING_DEFAULT_MATERIAL := "meshbuilder/materials/default_material_path"

## Reference to the main MeshBuilder plugin.
var plugin: EditorPlugin = null
var editor: MBEditor = null:
	set = set_editor


var _default_material_path: String = DEFAULT_MATERIAL_PATH
var _project_materials: Array[Material] = []

# UI Nodes - Materials Section
var _material_grid: HFlowContainer
var _status_label: Label
var _file_dialog: EditorFileDialog

# Context Menu
var _context_menu: PopupMenu
var _context_material: Material = null

# Flag to prevent recursive updates while syncing from selection
var _syncing: bool = false

# ==============================================================================
# Lifecycle
# ==============================================================================

func _init() -> void:
	name = "Material & UV"
	custom_minimum_size = Vector2(250, 320)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_load_default_material_setting()

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
	sync_selection()

# ==============================================================================
# Settings
# ==============================================================================

func _load_default_material_setting() -> void:
	var settings = EditorInterface.get_editor_settings() if Engine.is_editor_hint() else null
	if settings != null and settings.has_setting(SETTING_DEFAULT_MATERIAL):
		_default_material_path = String(settings.get_setting(SETTING_DEFAULT_MATERIAL))
	else:
		_default_material_path = DEFAULT_MATERIAL_PATH

func _get_material_or_texture_path(mat: Material) -> String:
	if mat == null:
		return ""
	if mat.has_meta("source_texture_path"):
		return str(mat.get_meta("source_texture_path"))
	if mat is StandardMaterial3D and mat.albedo_texture != null and not mat.albedo_texture.resource_path.is_empty():
		return mat.albedo_texture.resource_path
	return mat.resource_path


func _save_default_material_setting(path: String) -> void:
	_default_material_path = path
	var settings = EditorInterface.get_editor_settings() if Engine.is_editor_hint() else null
	if settings != null:
		settings.set_setting(SETTING_DEFAULT_MATERIAL, path)
	MBMeshData.invalidate_default_material()

func get_default_material() -> Material:
	_load_default_material_setting()
	return MBMeshData.load_material_or_texture(_default_material_path)
# ==============================================================================
# UI Construction
# ==============================================================================

func _build_ui() -> void:
	for c in get_children():
		c.queue_free()

	var root_vbox := VBoxContainer.new()
	root_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root_vbox)

	# 2. Materials & Textures Palette Section Header + Actions
	var mat_header := HBoxContainer.new()
	var mat_title := Label.new()
	mat_title.text = "Palette"
	mat_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mat_header.add_child(mat_title)

	var btn_add := Button.new()
	btn_add.text = "+ Add"
	btn_add.tooltip_text = "Add material or texture from project..."
	btn_add.pressed.connect(_on_add_material_pressed)
	mat_header.add_child(btn_add)

	var btn_refresh := Button.new()
	btn_refresh.text = "↺"
	btn_refresh.tooltip_text = "Scan project for materials and textures"
	btn_refresh.pressed.connect(refresh_materials)
	mat_header.add_child(btn_refresh)
	root_vbox.add_child(mat_header)

	# Material Cards Container
	var mat_scroll := ScrollContainer.new()
	mat_scroll.custom_minimum_size = Vector2(0, 130)
	mat_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_vbox.add_child(mat_scroll)

	_material_grid = HFlowContainer.new()
	_material_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mat_scroll.add_child(_material_grid)

	root_vbox.add_child(HSeparator.new())

	_status_label = Label.new()
	_status_label.text = "No MBMesh selected"
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	root_vbox.add_child(_status_label)


func _extract_texture(mat: Material) -> Texture2D:
	if mat is StandardMaterial3D and mat.albedo_texture != null:
		return mat.albedo_texture
	elif mat is ShaderMaterial:
		var tex = (mat as ShaderMaterial).get_shader_parameter("base_texture")
		if tex is Texture2D:
			return tex
	var def := get_default_material()
	if def is StandardMaterial3D and def.albedo_texture != null:
		return def.albedo_texture
	return null


# ==============================================================================
# Material Management & Grid Population
# ==============================================================================

func refresh_materials() -> void:
	_project_materials.clear()
	_scanned_texture_paths.clear()
	_seen_material_keys.clear()

	# 1. Always include default material first
	var def_mat := get_default_material()
	if def_mat != null:
		_project_materials.append(def_mat)
		for key in _material_keys(def_mat):
			_seen_material_keys[key] = true

	# 2. Add materials from active mesh if any
	if editor != null and editor.active_mesh != null and editor.active_mesh.mb_mesh_data != null:
		for m in editor.active_mesh.mb_mesh_data.materials:
			_append_material_once(m)

	# 3. The addon's own bundled texture (base checkerboard) registers on every
	# project — a fresh install has no res://materials yet, and the
	# depth-limited scan below never reaches materials/textures (4 levels down).
	_scan_dir_for_materials("res://addons/meshbuilder/materials/textures")

	# 4. Scan the rest of the project for materials and texture images
	_scan_dir_for_materials("res://")

	_collapse_duplicate_materials()
	_rebuild_material_grid()

## Collapse cross-order duplicates: a texture wrapper scanned BEFORE the
## saved material that references the same image must not survive next to
## it. Saved materials (.tres) always win over wrappers; among wrappers,
## the first occurrence wins. (Key registration during the scan is
## order-dependent — the user-visible duplicate was exactly this.)
func _collapse_duplicate_materials() -> void:
	var saved_keys := {}
	for m in _project_materials:
		if m != null and not m.resource_path.is_empty():
			for key in _material_keys(m):
				saved_keys[key] = true
	var kept: Array[Material] = []
	var wrapper_keys := {}
	for m in _project_materials:
		if m == null:
			continue
		if m.resource_path.is_empty():
			var is_dup := false
			for key in _material_keys(m):
				if saved_keys.has(key) or wrapper_keys.has(key):
					is_dup = true
					break
			if is_dup:
				continue
			for key in _material_keys(m):
				wrapper_keys[key] = true
		kept.append(m)
	_project_materials = kept

var _scanned_texture_paths: Dictionary = {}
var _seen_material_keys: Dictionary = {}

## The keys a material occupies: its resource path when saved, its source
## texture, and the path of the texture its albedo points at. Collapses the
## same stock material arriving via the default-material setting, the active
## mesh, the project scan AND plain texture wrappers of the same image into
## one card (the default material used to appear up to three times).
func _material_keys(mat: Material) -> Array[String]:
	var keys: Array[String] = []
	if mat == null:
		return keys
	if not mat.resource_path.is_empty():
		keys.append("path:" + mat.resource_path)
	if mat.has_meta("source_texture_path"):
		keys.append("src:" + str(mat.get_meta("source_texture_path")))
	if mat is StandardMaterial3D:
		var albedo := (mat as StandardMaterial3D).albedo_texture
		if albedo != null and not albedo.resource_path.is_empty():
			keys.append("src:" + albedo.resource_path)
	if keys.is_empty():
		keys.append("name:%s:%s" % [mat.get_class(), mat.resource_name])
	return keys

func _append_material_once(mat: Material) -> bool:
	if mat == null:
		return false
	var keys := _material_keys(mat)
	for key in keys:
		if _seen_material_keys.has(key):
			return false
	for key in keys:
		_seen_material_keys[key] = true
	_project_materials.append(mat)
	return true

func _scan_dir_for_materials(dir_path: String, depth: int = 0) -> void:
	if depth > 3 or _project_materials.size() > 60:
		return
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name_str := d.get_next()
	while name_str != "":
		if not name_str.begins_with(".") and not name_str.begins_with(".godot"):
			var full_path := dir_path.path_join(name_str)
			if d.current_is_dir():
				_scan_dir_for_materials(full_path, depth + 1)
			else:
				var ext := name_str.get_extension().to_lower()
				if ext == "tres" or ext == "material":
					if ResourceLoader.exists(full_path):
						var res = ResourceLoader.load(full_path)
						if res is Material:
							_append_material_once(res)
				elif ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "webp":
					# One card per texture NAME: a project copy of a bundled
					# texture must not show twice in the palette.
					var file_key := name_str.get_file()
					if not _scanned_texture_paths.has(file_key):
						_scanned_texture_paths[file_key] = true
						if ResourceLoader.exists(full_path):
							var tex = ResourceLoader.load(full_path)
							if tex is Texture2D:
								var mat := StandardMaterial3D.new()
								mat.resource_name = name_str.get_basename().capitalize()
								mat.set_meta("source_texture_path", full_path)
								mat.albedo_texture = tex
								mat.roughness = 0.8
								mat.vertex_color_use_as_albedo = true
								mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
								# The palette preview must match the retro bake:
								# alpha is taken from the texture's pixels
								# (water/waterfall sheets blend, foliage cuts),
								# never left opaque until export fixes it.
								MBAlphaDetect.ensure_transparency(mat)
								_append_material_once(mat)
		name_str = d.get_next()
	d.list_dir_end()

func _rebuild_material_grid() -> void:
	if _material_grid == null:
		return
	for c in _material_grid.get_children():
		c.queue_free()

	for mat in _project_materials:
		if mat == null:
			continue
		var card := _create_material_card(mat)
		_material_grid.add_child(card)

func _create_material_card(mat: Material) -> Control:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(64, 64)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.clip_text = true

	var mat_name := mat.resource_name
	if mat_name.is_empty():
		mat_name = mat.resource_path.get_file().get_basename()
	if mat_name.is_empty():
		mat_name = "Material"

	var tooltip := mat_name + "\nLeft-click: Apply to selected face(s)\nRight-click: Set as default"

	var tex := _extract_texture(mat)
	if tex != null:
		btn.icon = tex
		btn.expand_icon = true
	elif mat is StandardMaterial3D:
		btn.text = mat_name
		btn.modulate = mat.albedo_color
	else:
		btn.text = mat_name

	btn.pressed.connect(func(): _apply_material_to_selection(mat))
	# Right-click -> Context Menu
	btn.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			_show_context_menu(mat, btn.get_global_mouse_position())
	)

	# Drag & Drop source
	btn.set_script(preload("res://addons/meshbuilder/gui/docks/mb_material_card_drag.gd"))
	btn.set("material_resource", mat)

	# Default indicator badge
	var is_default := false
	var def_path := _default_material_path
	var card_path := _get_material_or_texture_path(mat)
	if not def_path.is_empty() and not card_path.is_empty() and card_path == def_path:
		is_default = true
	elif mat == get_default_material():
		is_default = true
	if is_default:
		var badge := Label.new()
		badge.text = "★"
		badge.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
		badge.add_theme_font_size_override("font_size", 14)
		badge.position = Vector2(4, 2)
		btn.add_child(badge)
	return btn

func _show_context_menu(mat: Material, pos: Vector2) -> void:
	_context_material = mat
	if _context_menu == null:
		_context_menu = PopupMenu.new()
		_context_menu.name = "MaterialContextMenu"
		_context_menu.id_pressed.connect(_on_context_menu_id_pressed)
		add_child(_context_menu)
	_context_menu.clear()
	var is_def := (mat.resource_path == _default_material_path)
	_context_menu.add_item("★ Set as Default for New Shapes", 1)
	if is_def:
		_context_menu.set_item_disabled(0, true)
	_context_menu.add_item("Apply to Selection", 2)
	_context_menu.add_separator()
	_context_menu.add_item("Copy Path", 3)
	_context_menu.popup(Rect2i(Vector2i(pos), Vector2i(210, 110)))

func _on_context_menu_id_pressed(id: int) -> void:
	if _context_material == null:
		return
	match id:
		1:
			var mat_path := _get_material_or_texture_path(_context_material)
			if not mat_path.is_empty():
				_save_default_material_setting(mat_path)
				_rebuild_material_grid()
		2:
			_apply_material_to_selection(_context_material)
		3:
			DisplayServer.clipboard_set(_context_material.resource_path)

func _on_add_material_pressed() -> void:
	if _file_dialog == null:
		_file_dialog = EditorFileDialog.new()
		_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.add_filter("*.tres, *.material, *.png, *.jpg, *.webp", "Materials & Textures")
		_file_dialog.file_selected.connect(_on_file_dialog_selected)
		add_child(_file_dialog)
	_file_dialog.popup_file_dialog()

func _on_file_dialog_selected(path: String) -> void:
	if ResourceLoader.exists(path):
		var res = ResourceLoader.load(path)
		if res is Material:
			if not _project_materials.has(res):
				_project_materials.append(res)
				_rebuild_material_grid()
		elif res is Texture2D:
			var mat := StandardMaterial3D.new()
			mat.resource_name = path.get_file().get_basename().capitalize()
			mat.albedo_texture = res
			mat.roughness = 0.8
			MBAlphaDetect.ensure_transparency(mat)
			_project_materials.append(mat)
			_rebuild_material_grid()

# ==============================================================================
# Selection Synchronization & UI State
# ==============================================================================

func sync_selection() -> void:
	if _syncing:
		return
	_syncing = true
	if _status_label == null:
		_syncing = false
		return

	var mesh: MBMesh = editor.active_mesh if editor != null else null

	if mesh != null and mesh.mb_mesh_data != null and editor != null and editor.selection != null:
		var sel_faces: PackedInt32Array = editor.selection.selected_faces
		if not sel_faces.is_empty():
			_status_label.text = "%d face(s) selected on %s" % [sel_faces.size(), mesh.name]
		elif editor.tool_mode == MBEditor.SelectMode.OBJECT:
			_status_label.text = "Object %s selected (materials apply to all faces)" % mesh.name
		else:
			_status_label.text = "No faces selected on %s" % mesh.name
	else:
		_status_label.text = "No MBMesh selected"

	_syncing = false

# ==============================================================================
# UV & Material Actions
# ==============================================================================

func _apply_material_to_selection(mat: Material) -> void:
	var mesh: MBMesh = editor.active_mesh if editor != null else null
	if mesh == null or mesh.mb_mesh_data == null:
		return

	var target_faces: Array[MBFace] = []
	var sel_faces: PackedInt32Array = editor.selection.selected_faces if editor != null and editor.selection != null else PackedInt32Array()

	if not sel_faces.is_empty():
		for fi in sel_faces:
			if fi >= 0 and fi < mesh.mb_mesh_data.faces.size():
				target_faces.append(mesh.mb_mesh_data.faces[fi])
	else:
		# Object mode or all faces
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







func _get_target_faces(mesh: MBMesh) -> Array[MBFace]:
	var result: Array[MBFace] = []
	if mesh == null or mesh.mb_mesh_data == null:
		return result
	var sel_faces: PackedInt32Array = editor.selection.selected_faces if editor != null and editor.selection != null else PackedInt32Array()
	if not sel_faces.is_empty():
		for fi in sel_faces:
			if fi >= 0 and fi < mesh.mb_mesh_data.faces.size():
				result.append(mesh.mb_mesh_data.faces[fi])
	else:
		for f in mesh.mb_mesh_data.faces:
			if f != null:
				result.append(f)
	return result

func _commit_mesh_action(mesh: MBMesh, action_name: String, before: MBMeshData, after: MBMeshData) -> void:
	mesh.rebuild()
	mesh.update_gizmos()
	if plugin != null and plugin.has_method("get_undo_redo"):
		var undo = plugin.get_undo_redo()
		if undo != null:
			undo.create_action(action_name, UndoRedo.MERGE_DISABLE, mesh)
			undo.add_do_method(plugin, "_restore_mesh_snapshot", mesh.get_instance_id(), after)
			undo.add_undo_method(plugin, "_restore_mesh_snapshot", mesh.get_instance_id(), before)
			undo.commit_action()

# ==============================================================================
# UI Helpers
# ==============================================================================

func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l



