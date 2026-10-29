## MBToolbar — MeshBuilder's persistent toolbar row.
##
## Lives as its own full-width row directly BELOW the 3D scene toolbar (not
## inside it) and stays visible at all times. When no MBMesh is selected the
## context buttons are disabled but the row remains.
##
## Groups (icon-driven; simple SVG glyphs, see icons/):
## - Tool (Move/Rotate/Scale): the plugin's OWN transform tool. While editing
##   we never follow the editor's Q/V universal/select tool state.
## - Mode (Object/Vertex/Edge/Face): element selection mode. OBJECT is a real
##   mode: whole-object transforms happen only there; clicking between
##   objects in an element mode auto-picks the element under the cursor.
## - Space button: cycles the gizmo orientation space (same as X).
## - Operations: mesh ops acting on the current selection, enabled per
##   selection context (greyed out otherwise). The overlay panel does NOT
##   carry op buttons.
## - Shape actions: New Shape menu (always enabled), Edit Params (enabled
##   while the selected mesh is a pristine, unedited factory shape).
## - Panel toggle: pins the overlay panel on/off (it otherwise auto-hides).
@tool
class_name MBToolbar
extends VBoxContainer
# ==============================================================================
# Signals
# ==============================================================================

## Emitted when the user clicks a mode button.
signal mode_button_pressed(mode: MBEditor.SelectMode)

## Emitted when the user clicks a tool button.
signal tool_button_pressed(tool: MBEditor.ToolMode)

## Emitted when the user picks a shape from the New Shape menu. Works with
## NOTHING selected — shape creation is the toolbar's always-on entry point.
signal shape_requested(shape_id: StringName)

## Emitted when the user clicks a mesh operation button. The plugin performs
## the op — selection reading and undo live there.
signal operation_requested(op_name: String)

## Emitted when the user asks to re-edit the selected mesh's shape params.
signal edit_params_requested
signal trim_walls_requested

## Emitted when the user toggles the overlay panel pin.
signal overlay_toggled(pinned: bool)

## Emitted when the user clicks the explicit Reset Panel button on the toolbar.
signal reset_panel_requested

## Grid settings moved out of the toolbar into the overlay panel (opened by
## this button); the toolbar keeps only a lightweight grid-status readout
## that mirrors MBGrid.
signal grid_panel_toggled(open: bool)

## Emitted when the user clicks the Material & UV dock button to focus it.

## Emitted when the user toggles the Display Settings section in the overlay.
signal settings_panel_toggled(open: bool)
signal materials_dock_requested
## Emitted when the user clicks the UV Editor button to focus the 2D UV panel.
signal uv_editor_requested

## Emitted when the user selects a Time of Day environment preset from the toolbar.
signal env_preset_requested(preset_name: String)

## Emitted when the user toggles the Lit / Cast Shadows object-state buttons
## (row 3). They apply to the whole current scene selection.
signal object_lit_toggled(pressed: bool)
signal object_shadow_toggled(pressed: bool)
signal xray_toggled(pressed: bool)
# Icons
# ==============================================================================

const ICON_DIR := "res://addons/meshbuilder/icons/"

# ==============================================================================
# Internal UI & Layout
# ==============================================================================

var _btn_vertex_snap: Button
var _btn_proportional: Button
var _spin_prop_radius: SpinBox

signal vertex_snap_toggled(pressed: bool)
signal proportional_toggled(pressed: bool)
signal proportional_radius_changed(radius: float)
var _btn_move: Button
var _btn_rotate: Button
var _btn_scale: Button
var _btn_object: Button
var _btn_vertex: Button
var _btn_edge: Button
var _btn_face: Button
var _btn_texture: Button
var _btn_space: Button
var _btn_new_shape: MenuButton
var _btn_ngon: Button
var _btn_edit_params: Button
var _btn_trim_walls: Button
var _btn_overlay: Button
var _btn_recover_overlay: Button
var _btn_materials: Button
var _btn_uv_editor: Button
var _op_buttons: Dictionary = {}
var _btn_settings: Button
var _btn_env: MenuButton
var _btn_grid_panel: Button
var _lbl_grid_state: Label
var _btn_obj_lit: Button
var _btn_obj_shadow: Button
var _btn_xray: Button

var _tool_group: ButtonGroup = ButtonGroup.new()
var _mode_group: ButtonGroup = ButtonGroup.new()

var editor: MBEditor = null:
	set = set_editor

# ==============================================================================
# Lifecycle
# ==============================================================================

func _init() -> void:
	name = "MBToolbar"
	size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_FILL
	add_theme_constant_override("separation", 2)
	_build_ui()

func _build_ui() -> void:
	# Tools group
	_btn_move = _create_tool_button("Move", MBEditor.ToolMode.MOVE, "icon_move.svg")
	_btn_rotate = _create_tool_button("Rotate", MBEditor.ToolMode.ROTATE, "icon_rotate.svg")
	_btn_scale = _create_tool_button("Scale", MBEditor.ToolMode.SCALE, "icon_scale.svg")
	_btn_scale.tooltip_text = "Scale tool (R) — axis handles scale freely; the CENTER square scales all axes together (Shift + center on faces insets)"

	# Selection modes group
	_btn_object = _create_mode_button("Object", MBEditor.SelectMode.OBJECT, "icon_object.svg")
	_btn_vertex = _create_mode_button("Vertex", MBEditor.SelectMode.VERTEX, "icon_vertex.svg")
	_btn_edge = _create_mode_button("Edge", MBEditor.SelectMode.EDGE, "icon_edge.svg")
	_btn_face = _create_mode_button("Face", MBEditor.SelectMode.FACE, "icon_face.svg")
	_btn_texture = _create_mode_button("Texture", MBEditor.SelectMode.TEXTURE, "icon_texture_mode.svg")
	_btn_texture.tooltip_text = "Texture / Material Mode (6) — transform UVs directly on 3D geometry"

	# Orientation space
	_btn_space = Button.new()
	_btn_space.name = "SpaceButton"
	_btn_space.icon = _load_icon("icon_space.svg")
	_btn_space.text = "Element"
	_btn_space.flat = true
	_btn_space.tooltip_text = "Gizmo orientation space (X to cycle): Element, Object, World"
	_btn_space.pressed.connect(_on_space_button_pressed)

	# Grid settings & readout
	_btn_grid_panel = Button.new()
	_btn_grid_panel.name = "GridPanelToggle"
	_btn_grid_panel.icon = _load_icon("icon_grid.svg")
	if _btn_grid_panel.icon == null:
		_btn_grid_panel.text = "Grid"
	_btn_grid_panel.toggle_mode = true
	_btn_grid_panel.flat = true
	_btn_grid_panel.focus_mode = Control.FOCUS_NONE
	_btn_grid_panel.tooltip_text = "Grid & snapping settings (unit, subdivisions, elevation, draw-on-grid). Keys: =/- subdivisions, Shift+=/- unit, [/] elevation, \\ reset, Y snap, G draw-on-grid"
	_btn_grid_panel.toggled.connect(func(on: bool): grid_panel_toggled.emit(on))

	_lbl_grid_state = Label.new()
	_lbl_grid_state.name = "GridState"
	_lbl_grid_state.text = "0.2m"
	_lbl_grid_state.tooltip_text = "Current snap step (unit / subdivisions) — elevation shown when nonzero"


	_btn_vertex_snap = Button.new()
	_btn_vertex_snap.name = "VertexSnapToggle"
	_btn_vertex_snap.text = "V-Snap"
	_btn_vertex_snap.flat = true
	_btn_vertex_snap.toggle_mode = true
	_btn_vertex_snap.focus_mode = Control.FOCUS_NONE
	_btn_vertex_snap.tooltip_text = "Vertex Snapping: Toggle snapping dragged elements to nearest mesh vertex (or Hold V)"
	_btn_vertex_snap.toggled.connect(func(on: bool): vertex_snap_toggled.emit(on))

	_btn_proportional = Button.new()
	_btn_proportional.name = "ProportionalToggle"
	_btn_proportional.text = "Soft"
	_btn_proportional.flat = true
	_btn_proportional.toggle_mode = true
	_btn_proportional.focus_mode = Control.FOCUS_NONE
	_btn_proportional.tooltip_text = "Proportional Editing (Soft Selection): Move nearby unselected vertices with smooth falloff"
	_btn_proportional.toggled.connect(func(on: bool): proportional_toggled.emit(on))

	_spin_prop_radius = SpinBox.new()
	_spin_prop_radius.name = "PropRadius"
	_spin_prop_radius.min_value = 0.1
	_spin_prop_radius.max_value = 50.0
	_spin_prop_radius.step = 0.1
	_spin_prop_radius.value = 2.0
	_spin_prop_radius.prefix = "r:"
	_spin_prop_radius.tooltip_text = "Proportional Influence Radius (m)"
	_spin_prop_radius.value_changed.connect(func(val: float): proportional_radius_changed.emit(val))
	# Operations group
	_make_op_button("Extrude", "extrude_faces", "Extrude selected faces/edges along their normal (Shift+Move does this live)", "icon_extrude.svg")
	_make_op_button("Inset", "inset_faces", "Inset selected faces (Shift+Scale does this live)", "icon_inset.svg")
	_make_op_button("Bevel", "bevel_edges", "Bevel selected edges or faces (Chamfer or fillet rounding)", "icon_bevel.svg")
	_make_op_button("Bridge", "bridge_edges", "Bridge: Connect two open boundary edges with a face (Alt+B)", "icon_bridge.svg")
	_make_op_button("Connect", "connect_edges", "Connect: Insert edge connecting edge midpoints or vertices (Alt+E)", "icon_connect.svg")
	_make_op_button("Collapse", "collapse_elements", "Collapse selected vertices, edges, or faces to a single point", "icon_collapse.svg")
	_make_op_button("Fill Hole", "fill_hole", "Fill Hole: Cap open boundary loops with a new face", "icon_fill_hole.svg")
	_make_op_button("Knife", "knife_tool", "Knife: Cut faces by placing vertices (Enter to complete cut)", "icon_knife.svg")
	_make_op_button("Loop Cut", "insert_edge_loop", "Insert an edge loop through the ring of quads crossed by the selected edge", "icon_loop_cut.svg")
	_make_op_button("Merge", "merge_faces", "Merge edge-adjacent selected faces into one n-gon", "icon_merge.svg")
	_make_op_button("Subdiv", "subdivide_faces", "Subdivide the selected quads into 4", "icon_subdivide.svg")
	_make_op_button("Merge", "weld_vertices", "Merge the selected vertices into their centroid (M)", "icon_weld.svg")
	_make_op_button("Detach", "detach_faces", "Detach the selected faces into a new MBMesh node", "icon_detach.svg")
	_make_op_button("Del", "delete_selection", "Delete selection: faces, edges or vertices (X)", "icon_delete.svg")


	# Row 3 Extended Tools: Advanced Selection, Object Ops, CSG Booleans, Smoothing
	_make_op_button("All", "select_all", "Select All elements of current mode", "icon_select_all.svg")
	_make_op_button("Invert", "invert_selection", "Invert element selection", "icon_invert_selection.svg")
	_make_op_button("Grow", "grow_selection", "Grow selection by 1 ring", "icon_grow_selection.svg")
	_make_op_button("Shrink", "shrink_selection", "Shrink selection by boundary elements", "icon_shrink_selection.svg")
	_make_op_button("Coplanar", "select_coplanar", "Select adjacent coplanar faces", "icon_select_coplanar.svg")
	_make_op_button("Similar", "select_similar", "Select faces with matching material", "icon_select_similar.svg")
	_make_op_button("Boundary", "select_boundary", "Select open boundary edges", "icon_select_boundary.svg")
	_make_op_button("Loop", "select_face_loop", "Select quad strip face loop", "icon_face_loop.svg")
	_make_op_button("Ring", "select_face_ring", "Select perpendicular quad face ring", "icon_face_ring.svg")

	_make_op_button("Merge Objs", "merge_objects", "Merge selected MBMesh nodes into one", "icon_merge_objects.svg")
	_make_op_button("Mirror", "mirror_object", "Mirror object geometry across X", "icon_mirror.svg")
	_make_op_button("Center Pivot", "center_pivot", "Center pivot to bounding box", "icon_center_pivot.svg")
	_make_op_button("Freeze Xform", "freeze_transform", "Freeze transform into vertex positions", "icon_freeze_transform.svg")
	var p_btn := _make_op_button("MeshBuilderize", "meshbuilderize", "Convert selected MeshInstance3D or CSG to editable MBMesh", "icon_meshbuilderize.svg")
	_op_buttons["probuilderize"] = p_btn

	_make_op_button("CSG Union", "csg_union", "CSG: Solid union of the selected meshes (select target first, cutter last)", "icon_csg_union.svg")
	_make_op_button("CSG Subtract", "csg_subtract", "CSG: Subtract the LAST-selected mesh from the FIRST-selected mesh", "icon_csg_subtract.svg")
	_make_op_button("CSG Intersect", "csg_intersect", "CSG: Solid intersection of the selected meshes (select target first, cutter last)", "icon_csg_intersect.svg")

	_make_op_button("Auto Smooth", "smooth_auto", "Auto-smooth faces by dihedral angle (45 deg)", "icon_auto_smooth.svg")

	# Object state toggles (row 3): Lit + Cast Shadows for the scene selection.
	_btn_obj_lit = Button.new()
	_btn_obj_lit.name = "ObjectLitToggle"
	_btn_obj_lit.icon = _load_icon("icon_lit.svg")
	if _btn_obj_lit.icon == null:
		_btn_obj_lit.text = "Lit"
	_btn_obj_lit.flat = true
	_btn_obj_lit.toggle_mode = true
	_btn_obj_lit.focus_mode = Control.FOCUS_NONE
	_btn_obj_lit.disabled = true
	_btn_obj_lit.tooltip_text = "Lit: shading on/off for the selected objects. All lit = checked, all unlit = unchecked, mixed = unchecked (checking synchronizes every selected object)."
	_btn_obj_lit.toggled.connect(func(on: bool): object_lit_toggled.emit(on))

	_btn_obj_shadow = Button.new()
	_btn_obj_shadow.name = "ObjectShadowToggle"
	_btn_obj_shadow.icon = _load_icon("icon_shadow.svg")
	if _btn_obj_shadow.icon == null:
		_btn_obj_shadow.text = "Shadow"
	_btn_obj_shadow.flat = true
	_btn_obj_shadow.toggle_mode = true
	_btn_obj_shadow.focus_mode = Control.FOCUS_NONE
	_btn_obj_shadow.disabled = true
	_btn_obj_shadow.tooltip_text = "Cast Shadows: shadow casting on/off for the selected objects. All casting = checked, none = unchecked, mixed = unchecked (checking synchronizes every selected object)."
	_btn_obj_shadow.toggled.connect(func(on: bool): object_shadow_toggled.emit(on))

	_btn_xray = Button.new()
	_btn_xray.name = "XRayToggle"
	_btn_xray.icon = _load_icon("icon_xray.svg")
	if _btn_xray.icon == null:
		_btn_xray.text = "X-Ray"
	_btn_xray.flat = true
	_btn_xray.toggle_mode = true
	_btn_xray.focus_mode = Control.FOCUS_NONE
	_btn_xray.disabled = true
	_btn_xray.tooltip_text = "X-Ray: show the edited mesh translucent so back faces are visible (Alt+Z)"
	_btn_xray.toggled.connect(func(on: bool): xray_toggled.emit(on))
	# Shapes group
	_btn_new_shape = MenuButton.new()
	_btn_new_shape.name = "NewShape"
	_btn_new_shape.icon = _load_icon("icon_new_shape.svg")
	if _btn_new_shape.icon == null:
		_btn_new_shape.text = "New Shape"
	_btn_new_shape.flat = true
	_btn_new_shape.tooltip_text = "New Shape: Create a new primitive 3D shape (drag base on any surface, set height)"
	var popup: PopupMenu = _btn_new_shape.get_popup()
	for shape_id in MBShapeFactory.get_shape_ids():
		popup.add_item(String(shape_id).capitalize(), popup.item_count)
	popup.id_pressed.connect(_on_shape_menu_pressed)

	_btn_ngon = Button.new()
	_btn_ngon.name = "NgonTool"
	_btn_ngon.icon = _load_icon("icon_ngon.svg")
	if _btn_ngon.icon == null:
		_btn_ngon.text = "N-Gon"
	_btn_ngon.flat = true
	_btn_ngon.tooltip_text = "N-Gon: Draw custom polygon and extrude into 3D (Enter to size height)"
	_btn_ngon.pressed.connect(func(): shape_requested.emit(&"ngon"))

	_btn_edit_params = Button.new()
	_btn_edit_params.name = "EditParams"
	_btn_edit_params.icon = _load_icon("icon_edit_params.svg")
	if _btn_edit_params.icon == null:
		_btn_edit_params.text = "Edit Params"
	_btn_edit_params.flat = true
	_btn_edit_params.tooltip_text = "Edit Params: Re-edit creation parameters for the selected shape"
	_btn_edit_params.disabled = true
	_btn_edit_params.pressed.connect(func(): edit_params_requested.emit())

	_btn_trim_walls = Button.new()
	_btn_trim_walls.name = "TrimWalls"
	_btn_trim_walls.icon = _load_icon("icon_trim_walls.svg")
	if _btn_trim_walls.icon == null:
		_btn_trim_walls.text = "Trim Walls"
	_btn_trim_walls.flat = true
	_btn_trim_walls.focus_mode = Control.FOCUS_NONE
	_btn_trim_walls.tooltip_text = "Trim Walls: click wall faces to sweep mitred trim along them (teal hover, amber chosen; Enter / double-click applies, Esc cancels)"
	_btn_trim_walls.pressed.connect(func(): trim_walls_requested.emit())

	# Overlay panel group
	_btn_overlay = Button.new()
	_btn_overlay.name = "OverlayToggle"
	_btn_overlay.icon = _load_icon("icon_panel.svg")
	if _btn_overlay.icon == null:
		_btn_overlay.text = "Panel"
	_btn_overlay.flat = true
	_btn_overlay.toggle_mode = true
	_btn_overlay.tooltip_text = "Toggle Overlay Panel: Show or hide the viewport overlay panel"
	_btn_overlay.toggled.connect(func(pressed: bool): overlay_toggled.emit(pressed))

	_btn_recover_overlay = Button.new()
	_btn_recover_overlay.name = "RecoverPanel"
	_btn_recover_overlay.icon = _load_icon("icon_panel_reset.svg")
	if _btn_recover_overlay.icon == null:
		_btn_recover_overlay.text = "↺"
	_btn_recover_overlay.flat = true
	_btn_recover_overlay.focus_mode = Control.FOCUS_NONE
	_btn_recover_overlay.tooltip_text = "Reset Panel: Recover overlay panel and dock to bottom-left corner"
	_btn_recover_overlay.pressed.connect(func(): reset_panel_requested.emit())

	# Docks & settings group
	_btn_materials = Button.new()
	_btn_materials.name = "MaterialsButton"
	_btn_materials.icon = _load_icon("icon_materials.svg")
	if _btn_materials.icon == null:
		_btn_materials.text = "Material"
	_btn_materials.flat = true
	_btn_materials.tooltip_text = "Material & UV: Focus the material picker and UV mapping dock"
	_btn_materials.pressed.connect(func(): materials_dock_requested.emit())

	_btn_uv_editor = Button.new()
	_btn_uv_editor.name = "UvEditorButton"
	_btn_uv_editor.text = "UV"
	_btn_uv_editor.flat = true
	_btn_uv_editor.tooltip_text = "UV Editor: Open the 2D UV canvas panel in the bottom dock"
	_btn_uv_editor.pressed.connect(func(): uv_editor_requested.emit())

	_btn_settings = Button.new()
	_btn_settings.name = "SettingsButton"
	_btn_settings.icon = _load_icon("icon_settings.svg")
	if _btn_settings.icon == null:
		_btn_settings.text = "Settings"
	_btn_settings.flat = true
	_btn_settings.toggle_mode = true
	_btn_settings.focus_mode = Control.FOCUS_NONE
	_btn_settings.tooltip_text = "Display settings (grid, wireframe, selection, hover opacity)"
	_btn_settings.toggled.connect(func(on: bool): settings_panel_toggled.emit(on))
	# Environment group
	_btn_env = MenuButton.new()
	_btn_env.name = "EnvButton"
	_btn_env.icon = _load_icon("icon_env.svg")
	if _btn_env.icon == null:
		_btn_env.text = "Env"
	_btn_env.flat = true
	_btn_env.focus_mode = Control.FOCUS_NONE
	_btn_env.tooltip_text = "Time of Day: Quick environment presets (Dawn, Day, Dusk, Night)"
	var env_popup: PopupMenu = _btn_env.get_popup()
	env_popup.add_item("🌅 Dawn", 0)
	env_popup.add_item("☀️ Day", 1)
	env_popup.add_item("🌇 Dusk", 2)
	env_popup.add_item("🌙 Night", 3)
	env_popup.id_pressed.connect(_on_env_menu_pressed)

	_update_row_layout()

func _make_sep() -> VSeparator:
	var sep := VSeparator.new()
	sep.custom_minimum_size = Vector2(6, 18)
	return sep

func _update_row_layout() -> void:
	for c in get_children():
		remove_child(c)

	_add_row([
		[_btn_object, _btn_vertex, _btn_edge, _btn_face, _btn_texture],
		[_btn_move, _btn_rotate, _btn_scale],
		[_btn_space],
	])
	_add_row([
		[
			_op_buttons["extrude_faces"], _op_buttons["inset_faces"], _op_buttons["bevel_edges"],
			_op_buttons["subdivide_faces"], _op_buttons["merge_faces"], _op_buttons["delete_selection"],
		],
		[
			_op_buttons["knife_tool"], _op_buttons["insert_edge_loop"], _op_buttons["connect_edges"],
			_op_buttons["bridge_edges"], _op_buttons["collapse_elements"], _op_buttons["fill_hole"],
			_op_buttons["weld_vertices"], _op_buttons["detach_faces"],
		],
	])
	_add_row([
		[
			_op_buttons["select_all"], _op_buttons["invert_selection"], _op_buttons["grow_selection"],
			_op_buttons["shrink_selection"], _op_buttons["select_coplanar"], _op_buttons["select_similar"],
			_op_buttons["select_boundary"], _op_buttons["select_face_loop"], _op_buttons["select_face_ring"],
		],
		[_op_buttons["smooth_auto"]],
	])
	_add_row([
		[_btn_vertex_snap, _btn_proportional, _spin_prop_radius],
		[_btn_grid_panel, _lbl_grid_state],
		[_btn_obj_lit, _btn_obj_shadow, _btn_xray],
	])
	_add_row([
		[_btn_new_shape, _btn_ngon, _btn_edit_params],
		[
			_op_buttons["merge_objects"], _op_buttons["mirror_object"], _op_buttons["center_pivot"],
			_op_buttons["freeze_transform"], _op_buttons["meshbuilderize"],
		],
		[_op_buttons["csg_union"], _op_buttons["csg_subtract"], _op_buttons["csg_intersect"]],
		[_btn_trim_walls],
		[_btn_materials, _btn_uv_editor, _btn_overlay, _btn_recover_overlay, _btn_settings],
		[_btn_env],
	])

func _add_row(groups: Array) -> void:
	var row := HFlowContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_FILL
	row.add_theme_constant_override("h_separation", 4)
	row.add_theme_constant_override("v_separation", 2)
	add_child(row)
	for i in groups.size():
		if i > 0:
			row.add_child(_make_sep())
		for c in groups[i]:
			row.add_child(c)


static func _load_icon(icon_name: String) -> Texture2D:
	var path := ICON_DIR + icon_name
	if ResourceLoader.exists(path):
		return load(path)
	return null

func _create_tool_button(text: String, tool: MBEditor.ToolMode, icon_name: String) -> Button:
	var btn := Button.new()
	btn.name = "Tool" + text
	btn.icon = _load_icon(icon_name)
	if btn.icon == null:
		btn.text = text
	btn.toggle_mode = true
	btn.flat = true
	btn.button_group = _tool_group
	btn.tooltip_text = "%s tool (%s)" % [text, ["W", "E", "R"][tool]]
	btn.pressed.connect(_on_tool_button_pressed.bind(tool))
	return btn

func _create_mode_button(text: String, mode: MBEditor.SelectMode, icon_name: String) -> Button:
	var btn := Button.new()
	btn.name = "Mode" + text
	btn.icon = _load_icon(icon_name)
	if btn.icon == null:
		btn.text = text
	btn.toggle_mode = true
	btn.flat = true
	btn.button_group = _mode_group
	btn.tooltip_text = "%s select mode (%s)" % [text, ["", "H", "J", "K", "6"][mode]]
	btn.pressed.connect(_on_mode_button_pressed.bind(mode))
	return btn

func _make_op_button(text: String, op_name: String, tooltip: String, icon_name: String = "") -> Button:
	var btn := Button.new()
	btn.name = "Op" + text
	btn.flat = true
	btn.tooltip_text = "%s: %s" % [text, tooltip]
	btn.disabled = true
	btn.focus_mode = Control.FOCUS_NONE
	if icon_name != "":
		var ico := _load_icon(icon_name)
		if ico != null:
			btn.icon = ico
		else:
			btn.text = text
	else:
		btn.text = text
	btn.pressed.connect(func(): operation_requested.emit(op_name))
	_op_buttons[op_name] = btn
	return btn
# ==============================================================================
# Editor Binding
# ==============================================================================

func set_editor(value: MBEditor) -> void:
	if editor != null:
		if editor.select_mode_changed.is_connected(_on_mode_changed):
			editor.select_mode_changed.disconnect(_on_mode_changed)
		if editor.tool_mode_changed.is_connected(_on_tool_changed):
			editor.tool_mode_changed.disconnect(_on_tool_changed)
		if editor.orientation_space_changed.is_connected(_on_space_changed):
			editor.orientation_space_changed.disconnect(_on_space_changed)
		if editor.element_selection_changed.is_connected(_on_selection_info_changed):
			editor.element_selection_changed.disconnect(_on_selection_info_changed)
		if editor.active_mesh_changed.is_connected(_on_selection_info_changed):
			editor.active_mesh_changed.disconnect(_on_selection_info_changed)
	editor = value
	if editor != null:
		editor.select_mode_changed.connect(_on_mode_changed)
		editor.tool_mode_changed.connect(_on_tool_changed)
		editor.orientation_space_changed.connect(_on_space_changed)
		editor.element_selection_changed.connect(_on_selection_info_changed)
		editor.active_mesh_changed.connect(_on_selection_info_changed)
		_on_mode_changed(editor.select_mode)
		_on_tool_changed(editor.tool_mode)
		_on_space_changed(editor.orientation_space)
		_on_selection_info_changed()

# ==============================================================================
# Button State Sync
# ==============================================================================

func _on_mode_changed(mode: MBEditor.SelectMode) -> void:
	_btn_object.set_pressed_no_signal(mode == MBEditor.SelectMode.OBJECT)
	_btn_vertex.set_pressed_no_signal(mode == MBEditor.SelectMode.VERTEX)
	_btn_edge.set_pressed_no_signal(mode == MBEditor.SelectMode.EDGE)
	_btn_face.set_pressed_no_signal(mode == MBEditor.SelectMode.FACE)
	_btn_texture.set_pressed_no_signal(mode == MBEditor.SelectMode.TEXTURE)

func _on_tool_changed(tool: MBEditor.ToolMode) -> void:
	_btn_move.set_pressed_no_signal(tool == MBEditor.ToolMode.MOVE)
	_btn_rotate.set_pressed_no_signal(tool == MBEditor.ToolMode.ROTATE)
	_btn_scale.set_pressed_no_signal(tool == MBEditor.ToolMode.SCALE)

func _on_space_changed(space: MBEditor.OrientationSpace) -> void:
	_btn_space.text = MBEditor.OrientationSpace.keys()[space].capitalize()

## Op buttons enable per selection context (mode + counts); Edit Params
## enables when the selected mesh is a pristine factory shape. Refreshed on
## every selection/mode/active-mesh change.
func _on_selection_info_changed(_arg = null) -> void:
	var sel := editor.selection if editor != null else null
	var faces_selected: bool = sel != null and sel.selected_face_count() > 0
	var edges_selected: bool = sel != null and sel.selected_edge_count() > 0
	var verts_selected: bool = sel != null and sel.selected_vertex_count() > 1
	var mode: MBEditor.SelectMode = editor.select_mode if editor != null else MBEditor.SelectMode.OBJECT
	var in_face: bool = mode == MBEditor.SelectMode.FACE
	var in_edge: bool = mode == MBEditor.SelectMode.EDGE
	var in_vertex: bool = mode == MBEditor.SelectMode.VERTEX

	if _op_buttons.has("extrude_faces"):
		# Face mode extrudes faces; edge mode extrudes fins — same button and
		# the same key action (the plugin routes by mode).
		_op_buttons["extrude_faces"].disabled = not (in_face and faces_selected) \
			and not (in_edge and edges_selected)
	if _op_buttons.has("inset_faces"):
		_op_buttons["inset_faces"].disabled = not (in_face and faces_selected)
	if _op_buttons.has("bevel_edges"):
		_op_buttons["bevel_edges"].disabled = not (in_edge and edges_selected) \
			and not (in_face and faces_selected)
	if _op_buttons.has("bridge_edges"):
		_op_buttons["bridge_edges"].disabled = not (in_edge and edges_selected)
	if _op_buttons.has("connect_edges"):
		_op_buttons["connect_edges"].disabled = not (in_edge and edges_selected) \
			and not (in_vertex and verts_selected) \
			and not (in_face and faces_selected)
	if _op_buttons.has("collapse_elements"):
		_op_buttons["collapse_elements"].disabled = not (in_vertex and verts_selected) \
			and not (in_edge and edges_selected) \
			and not (in_face and faces_selected)
	if _op_buttons.has("fill_hole"):
		_op_buttons["fill_hole"].disabled = editor == null or editor.active_mesh == null
	if _op_buttons.has("knife_tool"):
		_op_buttons["knife_tool"].disabled = editor == null or editor.active_mesh == null
	if _op_buttons.has("insert_edge_loop"):
		_op_buttons["insert_edge_loop"].disabled = not (in_edge and edges_selected)
		_op_buttons["merge_faces"].disabled = not (in_face and faces_selected)
	if _op_buttons.has("subdivide_faces"):
		_op_buttons["subdivide_faces"].disabled = not (in_face and faces_selected)
	if _op_buttons.has("weld_vertices"):
		_op_buttons["weld_vertices"].disabled = not (in_vertex and verts_selected)
	if _op_buttons.has("detach_faces"):
		_op_buttons["detach_faces"].disabled = not (in_face and faces_selected)
	if _op_buttons.has("delete_selection"):
		_op_buttons["delete_selection"].disabled = not (in_face and faces_selected) \
			and not (in_edge and edges_selected) \
			and not (in_vertex and verts_selected)
	# Extended Tools (Row 3)
	var has_mesh := editor != null and editor.active_mesh != null
	var any_elem_selected := faces_selected or edges_selected or (sel != null and sel.selected_vertex_count() > 0)

	if _op_buttons.has("select_all"):
		_op_buttons["select_all"].disabled = not has_mesh or mode == MBEditor.SelectMode.OBJECT
	if _op_buttons.has("invert_selection"):
		_op_buttons["invert_selection"].disabled = not has_mesh or mode == MBEditor.SelectMode.OBJECT
	if _op_buttons.has("grow_selection"):
		_op_buttons["grow_selection"].disabled = not any_elem_selected
	if _op_buttons.has("shrink_selection"):
		_op_buttons["shrink_selection"].disabled = not any_elem_selected
	if _op_buttons.has("select_coplanar"):
		_op_buttons["select_coplanar"].disabled = not (in_face and faces_selected)
	if _op_buttons.has("select_similar"):
		_op_buttons["select_similar"].disabled = not (in_face and faces_selected)
	if _op_buttons.has("select_boundary"):
		_op_buttons["select_boundary"].disabled = not has_mesh
	if _op_buttons.has("select_face_loop"):
		_op_buttons["select_face_loop"].disabled = not (in_face and faces_selected)
	if _op_buttons.has("select_face_ring"):
		_op_buttons["select_face_ring"].disabled = not (in_face and faces_selected)

	if _op_buttons.has("merge_objects"):
		_op_buttons["merge_objects"].disabled = not has_mesh
	if _op_buttons.has("mirror_object"):
		_op_buttons["mirror_object"].disabled = not has_mesh
	if _op_buttons.has("center_pivot"):
		_op_buttons["center_pivot"].disabled = not has_mesh
	if _op_buttons.has("freeze_transform"):
		_op_buttons["freeze_transform"].disabled = not has_mesh
	if _op_buttons.has("meshbuilderize"):
		_op_buttons["meshbuilderize"].disabled = false
	if _op_buttons.has("probuilderize"):
		_op_buttons["probuilderize"].disabled = false

	# CSG booleans are object-level ops on the scene selection (MBMesh,
	# MeshInstance3D, or CSG nodes) — they never need an active element edit.
	if _op_buttons.has("csg_union"):
		_op_buttons["csg_union"].disabled = false
	if _op_buttons.has("csg_subtract"):
		_op_buttons["csg_subtract"].disabled = false
	if _op_buttons.has("csg_intersect"):
		_op_buttons["csg_intersect"].disabled = false
	if _op_buttons.has("smooth_auto"):
		_op_buttons["smooth_auto"].disabled = not has_mesh
	_btn_edit_params.disabled = not _active_mesh_editable()


func sync_snapping(v_snap: bool, prop: bool, radius: float) -> void:
	if _btn_vertex_snap != null and _btn_vertex_snap.button_pressed != v_snap:
		_btn_vertex_snap.set_pressed_no_signal(v_snap)
	if _btn_proportional != null and _btn_proportional.button_pressed != prop:
		_btn_proportional.set_pressed_no_signal(prop)
	if _spin_prop_radius != null and not is_equal_approx(_spin_prop_radius.value, radius):
		_spin_prop_radius.set_value_no_signal(radius)

## Mirrors the selection's combined Lit / Cast Shadows state onto the row-3
## toggles WITHOUT emitting. `lit_state`/`shadow_state` are MBObjectState
## tri-states: 1 all on, 0 all off, -1 mixed (renders unchecked, like a
## mixed checkbox; checking it synchronizes every selected object).
func sync_object_state(lit_state: int, shadow_state: int, enabled: bool) -> void:
	if _btn_obj_lit != null:
		_btn_obj_lit.disabled = not enabled
		_btn_obj_lit.set_pressed_no_signal(lit_state == 1)
	if _btn_obj_shadow != null:
		_btn_obj_shadow.disabled = not enabled
		_btn_obj_shadow.set_pressed_no_signal(shadow_state == 1)
	if _btn_xray != null:
		_btn_xray.disabled = not enabled

## Mirrors the X-Ray mode onto its toggle WITHOUT emitting.
func set_xray_active(on: bool) -> void:
	if _btn_xray != null and _btn_xray.button_pressed != on:
		_btn_xray.set_pressed_no_signal(on)

## A mesh can re-open its params while it is still the pristine factory shape
## it was created as (no element drags, no mesh ops).
func _active_mesh_editable() -> bool:
	if editor == null or editor.active_mesh == null:
		return false
	var data: MBMeshData = editor.active_mesh.mb_mesh_data
	return data != null and data.shape_id != &"" and not data.shape_edited

func _on_mode_button_pressed(mode: MBEditor.SelectMode) -> void:
	if editor != null:
		editor.select_mode = mode
		# Re-clicking the active button toggles it off visually while the
		# editor state is unchanged — restore the pressed look.
		_on_mode_changed(editor.select_mode)
	mode_button_pressed.emit(mode)

func _on_tool_button_pressed(tool: MBEditor.ToolMode) -> void:
	if editor != null:
		editor.tool_mode = tool
		_on_tool_changed(editor.tool_mode)
	tool_button_pressed.emit(tool)

func _on_space_button_pressed() -> void:
	if editor != null:
		editor.cycle_orientation_space()

func _on_shape_menu_pressed(id: int) -> void:
	var ids := MBShapeFactory.get_shape_ids()
	if id >= 0 and id < ids.size():
		shape_requested.emit(ids[id])

# ==============================================================================
# Editing Context
# ==============================================================================

## The toolbar row is persistent: it is ALWAYS visible. Context buttons are
## enabled whenever a MBMesh is selected — including OBJECT mode (Object is
## its own mode; switching back to an element mode must always be possible).
func set_editing_active(active: bool) -> void:
	for btn: Button in [_btn_move, _btn_rotate, _btn_scale, _btn_space,
			_btn_object, _btn_vertex, _btn_edge, _btn_face, _btn_texture, _btn_uv_editor]:
		btn.disabled = not active
	# New Shape stays enabled: creation needs no editing context.
	_on_selection_info_changed()

func set_overlay_pinned(pinned: bool) -> void:
	_btn_overlay.set_pressed_no_signal(pinned)

## Mirrors MBGrid into the one-line readout WITHOUT emitting (the plugin
## owns the state; the overlay panel is the control surface).
func sync_grid(g: MBGrid) -> void:
	if g == null:
		return
	var text: String = "%sm" % str(snappedf(g.step(), 0.0001))
	var elev := g.elevation_summary()
	if elev != "":
		text += "  " + elev
	if not g.enabled:
		text += " (snap off)"
	_lbl_grid_state.text = text




func _on_env_menu_pressed(id: int) -> void:
	var names := MBEnvironment.get_preset_names()
	if id >= 0 and id < names.size():
		set_env_preset(names[id])
		env_preset_requested.emit(names[id])

func set_env_preset(preset_name: String) -> void:
	if _btn_env == null:
		return
	var p := MBEnvironment.get_preset(preset_name)
	_btn_env.tooltip_text = "Time of Day: %s (Click to change: Dawn, Day, Dusk, Night)" % p.get("name", preset_name.capitalize())
	if _btn_env.icon == null:
		_btn_env.text = p.get("label", preset_name.capitalize()) + " ▾"
