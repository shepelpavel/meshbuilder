@tool
extends EditorPlugin
class_name MeshBuilderPlugin

# ==============================================================================
# Core Systems
# ==============================================================================

var logger: MBLogger = MBLogger.new()
var editor: MBEditor = MBEditor.new()
var gizmo_plugin: MBGizmoPlugin = MBGizmoPlugin.new()
var tool_bridge: MBToolBridge = MBToolBridge.new()

## Snapping state: element drags, the extrude gesture and shape creation snap
## to the editor's grid (MeshBuilder no longer draws a grid of its own).
var grid: MBGrid = MBGrid.new()

## Live EditorSettings instance (null in headless test runs) — shortcut
## rebinds and grid persistence go through it.
var _settings: Object = null


## Shape creation and interactive polygon drawing controllers
var shape_creator: MBShapeCreator = MBShapeCreator.new()
var ngon_drawer: MBNgonDrawer = MBNgonDrawer.new()
## Trim Walls session: click wall faces, live preview, one committed object.
var trim_walls_tool: MBTrimWallsTool = MBTrimWallsTool.new()
## The preview node shown while a Trim Walls session is armed (world-space
## data, node transform stays identity). Owned by the plugin like the
## shape-creation preview.
var _trim_walls_preview: MBMesh = null
var _trim_walls_last_click_msec: int = -10000
var _trim_walls_last_click_pos: Vector2 = Vector2.ZERO

# ==============================================================================
# UI Components
# ==============================================================================

var tool_overlay: MBToolOverlay
var toolbar: MBToolbar

## X-Ray (translucent) view mode of the edited mesh.
var xray_on: bool = false
var _xray_node: GeometryInstance3D = null
var material_dock: MBMaterialDock = null
## Bottom-panel host and tab button for the Material & UV panel (it used to be
## a right-slot dock, which ate the editor's right column).
var _material_panel: Control = null
var _material_bottom_button: Button = null
var uv_editor_panel: MBUvEditorPanel = null
var _uv_bottom_button: Button = null
var material_drop_overlay: MBMaterialDropOverlay = null
var _cursor_extents_label: Label = null
## Top-center hint banner over the 3D scene (shape / trim / n-gon mode
## modes and their exit route). Pure readout, never consumes input.
var mode_banner: MBModeBanner = null
## The shape the Shapes dock tab keeps armed (re-armed after every placement).
## Hover id already reflected in the last gizmo redraw (avoids redundant
## update_gizmos calls on every motion event).
var _hover_drawn_last: int = -1

## Last cursor position + camera seen in the 3D viewport (presses AND motion).
## Lets a selection change (clicking another object) auto-pick the element
## under the exact click position.
var _last_mouse_pos: Vector2 = Vector2.ZERO
var _last_mouse_camera: Camera3D = null
## Screen position of the previous motion event of the ACTIVE paint stroke
## (INF while no stroke runs): the anchor the dab-along interpolator walks from.
## Cap on dabs interpolated per motion event: a flick across the whole level
## must not walk hundreds of re-picks in one event (the stroke then simply
## dabs at 64 spacings and the real endpoint).
## Time of the last press seen in the viewport, for click-recency checks.
var _last_press_msec: int = -10000

## Toolbar host in the bottom panel and its tab button (the same panel the
## 2D UV Editor uses) — keeps the 3D view free of plugin rows.
var _toolbar_panel: Control = null
var _toolbar_bottom_button: Button = null

# ==============================================================================
# Plugin Lifecycle
# ==============================================================================

func _get_plugin_name() -> String:
	return "MeshBuilder"


func _enter_tree():
	logger.info("plugin", "MeshBuilder entering tree")

	# Receive 3D viewport input even with NOTHING selected: shape creation is
	# armed from the New Shape menu and must work before any MBMesh is in the
	# editing context (the engine otherwise only forwards viewport input to
	# plugins whose _handles() matches the currently edited object).
	set_input_event_forwarding_always_enabled()
	var ep_settings: EditorSettings = get_editor_interface().get_editor_settings() if get_editor_interface() != null else null


	# Wire up subsystems
	editor.logger = logger
	gizmo_plugin.editor = editor
	gizmo_plugin.logger = logger
	gizmo_plugin.element_editor.editor = editor
	gizmo_plugin.element_editor.undo = get_undo_redo()
	gizmo_plugin.element_editor.grid = grid
	gizmo_plugin.shape_creator = shape_creator
	shape_creator.grid = grid
	gizmo_plugin.ngon_drawer = ngon_drawer
	ngon_drawer.grid = grid
	_wire_creation_vertex_snap()
	tool_bridge.logger = logger
	tool_bridge.on_tool_selected = _on_engine_tool_selected

	# Register every plugin action into the editor's shortcut store (rebinds
	# live in Editor Settings → Shortcuts like native editor commands) and
	# load the persisted grid settings.
	_settings = get_editor_interface().get_editor_settings()
	MBActions.register(_settings, logger)
	set_process(true)

	# Connect editor signals
	editor.active_mesh_changed.connect(_on_active_mesh_changed)
	editor.select_mode_changed.connect(_on_select_mode_changed)
	editor.element_selection_changed.connect(_on_element_selection_changed)
	editor.orientation_space_changed.connect(_on_orientation_space_changed)
	editor.tool_mode_changed.connect(_on_tool_mode_changed)
	gizmo_plugin.element_editor.element_drag_updated.connect(_on_drag_updated)
	gizmo_plugin.element_editor.drag_topology_committed.connect(_on_drag_topology_committed)

	# Register custom type
	add_custom_type(
		"MBMesh",
		"MeshInstance3D",
		preload("res://addons/meshbuilder/core/mb_mesh.gd"),
		preload("res://addons/meshbuilder/icons/mb_mesh_icon.svg") if FileAccess.file_exists("res://addons/meshbuilder/icons/mb_mesh_icon.svg") else null
	)

	# Register the node gizmo plugin — this is the native editor integration:
	# element picking, rubber-band selection, transform drags, snapping, and
	# undo are all driven by the editor through the subgizmo API.
	add_node_3d_gizmo_plugin(gizmo_plugin)

	# Persistent toolbar row UNDER the 3D scene toolbar (not inside it)
	toolbar = MBToolbar.new()
	toolbar.editor = editor
	toolbar.set_editing_active(false)
	toolbar.shape_requested.connect(_on_shape_requested)
	toolbar.operation_requested.connect(_on_operation_requested)
	toolbar.edit_params_requested.connect(_on_edit_params_requested)
	toolbar.trim_walls_requested.connect(_on_trim_walls_requested)
	toolbar.snap_toggled.connect(_on_toolbar_snap_toggled)
	toolbar.overlay_toggled.connect(_on_overlay_toggled)
	toolbar.reset_panel_requested.connect(_on_reset_panel_requested)
	toolbar.materials_dock_requested.connect(focus_material_dock)
	toolbar.uv_editor_requested.connect(focus_uv_editor)
	toolbar.settings_panel_toggled.connect(_on_settings_panel_toggled)
	toolbar.vertex_snap_toggled.connect(func(on: bool):
		gizmo_plugin.element_editor.vertex_snap_enabled = on
		if editor.active_mesh != null:
			editor.active_mesh.update_gizmos()
	)
	toolbar.proportional_toggled.connect(func(on: bool):
		gizmo_plugin.element_editor.proportional_enabled = on
		if editor.active_mesh != null:
			editor.active_mesh.update_gizmos()
	)
	toolbar.proportional_radius_changed.connect(func(rad: float):
		gizmo_plugin.element_editor.proportional_radius = rad
		if editor.active_mesh != null:
			editor.active_mesh.update_gizmos()
	)
	toolbar.object_lit_toggled.connect(_on_object_lit_toggled)
	toolbar.object_shadow_toggled.connect(_on_object_shadow_toggled)
	toolbar.xray_toggled.connect(_on_xray_toggled)
	_mount_toolbar_in_bottom_panel()
	# Tool overlay panel floating in the 3D viewport (readouts + params
	# modal; logging goes to the Godot console via MBLogger).
	tool_overlay = MBToolOverlay.new()
	tool_overlay.editor = editor
	tool_overlay.element_editor = gizmo_plugin.element_editor
	tool_overlay.visible = false
	tool_overlay.params_applied.connect(_on_params_applied)
	tool_overlay.params_canceled.connect(_on_params_canceled)
	tool_overlay.param_changed.connect(_on_param_changed)
	tool_overlay.edit_params_requested.connect(_on_edit_params_requested)
	tool_overlay.display_setting_changed.connect(_on_display_setting_changed)
	tool_overlay.display_reset_pressed.connect(_on_display_reset)
	_load_display_settings()
	_add_overlay_to_3d_viewport(tool_overlay)

	# Live (x, y, z) cursor extents label next to mouse during shape creation
	_cursor_extents_label = Label.new()
	_cursor_extents_label.name = "MeshBuilderCursorExtents"
	_cursor_extents_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_extents_label.add_theme_color_override("font_color", Color.WHITE)
	_cursor_extents_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_cursor_extents_label.add_theme_constant_override("outline_size", 8)
	_cursor_extents_label.add_theme_font_size_override("font_size", 14)
	_cursor_extents_label.visible = false
	_cursor_extents_label.z_index = 100
	_add_overlay_to_3d_viewport(_cursor_extents_label)
	# Top-center mode banner (shape / trim / n-gon mode readout)
	mode_banner = MBModeBanner.new()
	mode_banner.z_index = 90
	_add_overlay_to_3d_viewport(mode_banner)
	# Material drag-and-drop overlay in the 3D viewport
	material_drop_overlay = MBMaterialDropOverlay.new()
	material_drop_overlay.plugin = self
	_add_overlay_to_3d_viewport(material_drop_overlay)
	# Material & UV panel: bottom-panel tab next to the toolbar and the UV
	# Editor (a right-slot dock would take the editor's right column).
	material_dock = MBMaterialDock.new()
	material_dock.plugin = self
	material_dock.editor = editor
	material_dock.visible = true
	# The bottom panel draws its own background — no second frame around it.
	material_dock.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var dock_scroller := ScrollContainer.new()
	dock_scroller.name = "MaterialScroll"
	dock_scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	dock_scroller.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	dock_scroller.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dock_scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dock_scroller.add_child(material_dock)
	_material_panel = dock_scroller
	if Engine.is_editor_hint():
		_material_bottom_button = add_control_to_bottom_panel(dock_scroller, "Materials")
	# Dedicated 2D UV Editor Panel (Bottom dock)
	uv_editor_panel = MBUvEditorPanel.new()
	uv_editor_panel.editor = editor
	uv_editor_panel.plugin = self
	if Engine.is_editor_hint():
		_uv_bottom_button = add_control_to_bottom_panel(uv_editor_panel, "UV Editor")
	uv_editor_panel.pop_out_toggled.connect(_on_uv_pop_out_toggled)
	# Half-size manipulator gizmos by default (the engine default of 80px is
	# huge next to MeshBuilder's element work). Respect user customization:
	# only applied while the setting still sits at the engine default.
	var editor_settings: EditorSettings = get_editor_interface().get_editor_settings()
	if editor_settings != null and editor_settings.has_setting("editors/3d/manipulator_gizmo_size") \
			and int(editor_settings.get_setting("editors/3d/manipulator_gizmo_size")) == 80:
		editor_settings.set_setting("editors/3d/manipulator_gizmo_size", 40)
		logger.info("plugin", "Manipulator gizmo size set 80 → 40 (Editor Settings > Editors > 3D to change)")

	# Bridge onto the editor's tool buttons (own tool modes; never the
	# universal gizmo). Needs the Node3DEditor, located via the toolbar walk.
	if toolbar_has_3d_editor():
		if tool_bridge.setup(_n3d_editor):
			logger.info("plugin", "Tool bridge attached to the editor's Move/Rotate/Scale buttons; Q/V pin out while editing")
		else:
			logger.warn("plugin", "Engine tool buttons not found — plugin tool modes will not drive the editor gizmo")
		# The engine's View-Grid menu + Snap Settings dialog live under the
		# editor's main tree, not the Node3DEditor subtree.
		tool_bridge.find_editor_menus(get_editor_interface().get_base_control())
	else:
		logger.warn("plugin", "Node3DEditor not found — tool bridge inactive")

	# Listen for selection changes
	var selection: EditorSelection = get_editor_interface().get_selection()
	selection.selection_changed.connect(_on_selection_changed)

	logger.info("plugin", "MeshBuilder plugin initialized")

func _exit_tree():
	if xray_on:
		set_xray(false)
	if logger:
		logger.info("plugin", "MeshBuilder plugin exiting tree")

	# Drop a half-created shape preview (it never entered the undo history).
	if ngon_drawer.is_active():
		var node := ngon_drawer.preview_node
		ngon_drawer.reset()
		if node != null and is_instance_valid(node) and node.get_parent() != null:
			node.get_parent().remove_child(node)
			node.queue_free()

	if shape_creator.is_active():
		var node := shape_creator.preview_node
		shape_creator.reset()
		if node != null and is_instance_valid(node) and node.get_parent() != null:
			node.get_parent().remove_child(node)
			node.queue_free()


	# Disconnect selection
	var selection: EditorSelection = get_editor_interface().get_selection()
	if selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.disconnect(_on_selection_changed)

	# Unregister the gizmo plugin
	remove_node_3d_gizmo_plugin(gizmo_plugin)

	# Restore the editor's tool buttons to stock behavior
	tool_bridge.teardown()

	# Remove toolbar
	if toolbar:
		if is_instance_valid(toolbar) and toolbar.get_parent() != null:
			toolbar.get_parent().remove_child(toolbar)
			toolbar.queue_free()
		toolbar = null
	if _toolbar_panel != null and _toolbar_bottom_button != null:
		if is_instance_valid(_toolbar_panel):
			if Engine.is_editor_hint():
				remove_control_from_bottom_panel(_toolbar_panel)
			if _toolbar_panel.get_parent() != null:
				_toolbar_panel.get_parent().remove_child(_toolbar_panel)
			_toolbar_panel.queue_free()
		_toolbar_panel = null
		_toolbar_bottom_button = null
	# Remove overlay panel
	if tool_overlay:
		if is_instance_valid(tool_overlay):
			tool_overlay.get_parent().remove_child(tool_overlay)
			tool_overlay.queue_free()
		tool_overlay = null
	# Remove mode banner
	if mode_banner != null:
		if is_instance_valid(mode_banner):
			if mode_banner.get_parent() != null:
				mode_banner.get_parent().remove_child(mode_banner)
			mode_banner.queue_free()
		mode_banner = null

	# Remove material dock and drop overlay
	if material_dock != null:
		if _material_panel != null and _material_bottom_button != null and Engine.is_editor_hint():
			remove_control_from_bottom_panel(_material_panel)
		if is_instance_valid(material_dock):
			material_dock.queue_free()
		_material_panel = null
		_material_bottom_button = null
	# Remove UV editor panel
	if uv_editor_panel != null:
		if not uv_editor_panel._is_floating and Engine.is_editor_hint():
			remove_control_from_bottom_panel(uv_editor_panel)
		if is_instance_valid(uv_editor_panel):
			uv_editor_panel.queue_free()
		uv_editor_panel = null
		_uv_bottom_button = null


	if material_drop_overlay != null:
		if is_instance_valid(material_drop_overlay):
			material_drop_overlay.queue_free()
		material_drop_overlay = null
	if _cursor_extents_label != null:
		if is_instance_valid(_cursor_extents_label) and _cursor_extents_label.get_parent() != null:
			_cursor_extents_label.get_parent().remove_child(_cursor_extents_label)
			_cursor_extents_label.queue_free()
		_cursor_extents_label = null
	# Remove custom type
	remove_custom_type("MBMesh")

# ==============================================================================
# 3D Editor UI Placement
# ==============================================================================

var _n3d_editor: Node = null

func toolbar_has_3d_editor() -> bool:
	return _n3d_editor != null and is_instance_valid(_n3d_editor)

## Mounts the toolbar as a tab in the editor's BOTTOM panel (the same place the
## 2D UV Editor lives) instead of a row under the 3D scene toolbar: a full
## plugin toolbar above the viewport ate three or four rows of the 3D view.
##
## The tab is opened once on startup so the tools are visible right away; after
## that the editor remembers the panel state like any other bottom panel.
func _mount_toolbar_in_bottom_panel() -> void:
	_n3d_editor = _find_3d_editor()
	if _n3d_editor == null:
		logger.warn("plugin", "Node3DEditor not found — the tool bridge will stay inactive")

	var host := MarginContainer.new()
	host.name = "MeshBuilderToolbar"
	host.add_theme_constant_override("margin_left", 6)
	host.add_theme_constant_override("margin_right", 6)
	host.add_theme_constant_override("margin_top", 2)
	host.add_theme_constant_override("margin_bottom", 2)
	# A narrow bottom panel would clip the rows: let them scroll sideways
	# instead of squeezing the viewport-sized toolbar into the panel width.
	var scroller := ScrollContainer.new()
	scroller.name = "ToolbarScroll"
	scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroller.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroller.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroller.add_child(toolbar)
	host.add_child(scroller)
	_toolbar_panel = host
	if not Engine.is_editor_hint():
		return
	_toolbar_bottom_button = add_control_to_bottom_panel(host, "MeshBuilder")
	if _toolbar_bottom_button != null:
		_toolbar_bottom_button.tooltip_text = "MeshBuilder: инструменты моделинга"
	make_bottom_panel_item_visible.call_deferred(host)
	logger.info("plugin", "Toolbar mounted in the bottom panel")

## Finds the Node3DEditor that owns the 3D viewports, by walking the editor's
## base control. Returns the first one (the main screen); the tool bridge only
## needs it to hijack the Move/Rotate/Scale buttons.
func _find_3d_editor() -> Node:
	var base := get_editor_interface().get_base_control()
	if base == null:
		return null
	var queue: Array[Node] = [base]
	while not queue.is_empty():
		var node: Node = queue.pop_front()
		if node.get_class() == "Node3DEditor":
			return node
		for child in node.get_children():
			queue.append(child)
	return null

## Parents `control` to the first 3D editor viewport so it floats over the
## scene. The Node3DEditorViewport is a plain Control (no container sort), so
## anchored children keep their place; being the last child, it also receives
## mouse events over its own rect before the viewport surface does.
func _add_overlay_to_3d_viewport(control: Control) -> void:
	var viewport: SubViewport = get_editor_interface().get_editor_viewport_3d(0)
	if viewport == null:
		logger.warn("plugin", "No 3D editor viewport — tool overlay not created")
		return
	var host := viewport.get_parent().get_parent()
	if host == null or not (host is Control):
		logger.warn("plugin", "Unexpected 3D viewport layout — tool overlay not created")
		return
	host.add_child(control)

# ==============================================================================
# EditorPlugin Overrides
# ==============================================================================

func _handles(object: Object) -> bool:
	return object is MBMesh

func _edit(object: Object) -> void:
	if object is MBMesh:
		editor.active_mesh = object as MBMesh
	# A non-MBMesh primary (mixed selection, plain GLB mesh) does NOT clear the
	# active mesh here — _on_selection_changed owns that decision and runs after
	# this (the engine's selection_changed signal is deferred), so clearing
	# would only race the authoritative update.

func _make_visible(visible: bool) -> void:
	if not visible:
		editor.active_mesh = null

## Keyboard + hover handling. Clicks pass through UNTOUCHED: the native editor
## viewport decides input priority itself — the transform gizmo wins over
## element picking (its hit test runs first), and presses that miss the gizmo
## fall through to subgizmo selection / rubber-band. Interception here is what
## broke gizmo drags in earlier rounds.
func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	# Feed the live cursor to the element editor — the extrude gesture drives
	# the cap distance from the mouse (see MBElementEditor.track_mouse).
	if event is InputEventMouseMotion:
		gizmo_plugin.element_editor.track_mouse(camera, event.position)

	# Interactive N-gon drawing / Knife tool owns the mouse while active
	if ngon_drawer.is_active():
		return _ngon_drawer_input(camera, event)

	# Trim Walls session owns the mouse while armed (wall picking + preview)
	if trim_walls_tool.is_active():
		return _trim_walls_input(camera, event)

	# Shape creation owns the mouse while armed/dragging/modal (checked even
	# when nothing is selected — creation needs no editing context).
	if shape_creator.is_active():
		return _creation_input(camera, event)

	# If an Edit Params or Bevel session modal is open, handle its modal lifecycle:
	if _params_session_kind == "edit" or _params_session_kind == "bevel":
		if event is InputEventKey and event.pressed:
			var k := event as InputEventKey
			if k.keycode == KEY_ESCAPE:
				_on_params_canceled()
				return AFTER_GUI_INPUT_STOP
			elif k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
				_on_params_applied()
				return AFTER_GUI_INPUT_STOP
			else:
				_on_params_applied()
				return AFTER_GUI_INPUT_PASS
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if _params_session_kind == "bevel":
				_on_params_applied()
				return AFTER_GUI_INPUT_STOP
			if logger:
				logger.info("plugin", "Params modal cancelled (viewport press)")
			_on_params_canceled()
			return AFTER_GUI_INPUT_PASS
	# Godot's fly mode (RMB + WASD) and MMB pan feed their keys through the same
	# viewport input, so every plugin shortcut fired mid-flight (WASD itself hit
	# nothing, but K/D/X/1-4 and Ctrl+R pulled the camera out of navigation).
	# While a navigation button is held, keys belong to the editor.
	if event is InputEventKey and _is_navigating_view():
		return AFTER_GUI_INPUT_PASS

	# Everything key-driven funnels through the rebindable action table BEFORE
	# the editing gate: grid keys work with nothing selected (the grid must be
	# adjustable before use), while action-internal context gates keep unbound
	# keys passing through as before.
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.keycode == KEY_V and not k.ctrl_pressed and not k.alt_pressed and not k.meta_pressed:
			gizmo_plugin.element_editor.vertex_snap_held = k.pressed
		if k.pressed:
			if ngon_drawer.mode == MBNgonDrawer.Mode.KNIFE and ngon_drawer.is_active() \
					and (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER) \
					and ngon_drawer.state != MBNgonDrawer.State.DRAWING:
				_op_hint("Knife: click two points on the mesh first (Esc cancels)")
			return _handle_action_key(k)

	if not editor.is_editing():
		return AFTER_GUI_INPUT_PASS

	# Remember press positions: a following selection change (clicking another
	# object) auto-picks the element under this exact position.
	if event is InputEventMouseButton and event.pressed:
		_last_mouse_pos = event.position
		_last_mouse_camera = camera
		_last_press_msec = Time.get_ticks_msec()

	# Hover highlight: observe motion WITHOUT consuming it. The engine keeps
	# processing (camera nav, marquee, gizmo drags). Picking is skipped while
	# a button is held or a subgizmo drag is in flight.
	if event is InputEventMouseMotion and event.button_mask == 0 \
			and not gizmo_plugin.element_editor.drag_active:
		var node := editor.active_mesh
		if node != null and node.mb_mesh_data != null:
			_last_mouse_pos = event.position
			_last_mouse_camera = camera
			# Hover must never re-record the pick-side face (the element gizmo
			# stays locked to the side it was selected from).
			var id: int = gizmo_plugin.element_editor.pick_ray(
				node.mb_mesh_data, node.global_transform, camera, event.position, false)
			editor.hover_id = id
			if editor.hover_id != _hover_drawn_last:
				_hover_drawn_last = editor.hover_id
				node.update_gizmos()
			return AFTER_GUI_INPUT_PASS

	return AFTER_GUI_INPUT_PASS

## Maps a viewport keypress to a rebindable MeshBuilder action. Actions with
## an editing context consume the event (STOP); everything else PASSES so
## the engine's own shortcuts keep working untouched.
## Vertex weld tolerance for a knife cut, scaled to the mesh: a body panel gets
## a couple of millimetres, a 2 cm prop a fraction of one.
func _knife_weld_tolerance(md: MBMeshData) -> float:
	if md == null or md.positions.size() < 2:
		return 0.0015
	var mn: Vector3 = md.positions[0]
	var mx: Vector3 = md.positions[0]
	for p in md.positions:
		mn = Vector3(minf(mn.x, p.x), minf(mn.y, p.y), minf(mn.z, p.z))
		mx = Vector3(maxf(mx.x, p.x), maxf(mx.y, p.y), maxf(mx.z, p.z))
	return clampf(mn.distance_to(mx) * 0.004, 0.0015, 0.02)

## True while the editor is navigating the 3D view (RMB fly mode, MMB pan).
## Plugin shortcuts are ignored then — otherwise pressing W/A/S/D plus a tool
## key mid-flight triggers a mesh op instead of flying.
## `test_navigating` exists because headless tests cannot press a mouse button.
var test_navigating: bool = false

## Toolbar Snap button: same switch as the Y shortcut.
func _on_toolbar_snap_toggled(enabled: bool) -> void:
	grid.enabled = enabled
	if logger:
		logger.info("tools", "Snapping %s (toolbar)" % ("ON" if enabled else "OFF"))

## Keeps the toolbar button in step with the snapping state (Y, plugin logic).
func _sync_snap_button() -> void:
	if toolbar != null:
		toolbar.sync_snap(grid.enabled)

func _is_navigating_view() -> bool:
	if test_navigating:
		return true
	return Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) \
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE)

func _handle_action_key(key_event: InputEventKey) -> int:
	if _is_navigating_view():
		return AFTER_GUI_INPUT_PASS
	var action := MBActions.action_for(key_event, _settings)
	if action == &"":
		return AFTER_GUI_INPUT_PASS
	var editing := editor.is_editing()
	var mb_context := editing or editor.active_mesh != null or shape_creator.is_active() or ngon_drawer.is_active()
	var node_selected := editor.active_mesh != null
	match action:
		# Selection modes only when a MeshBuilder mesh is selected (H/J/K/1/2/3
		# with nothing selected must reach the scene tree and other fields).
		&"select_vertex":
			if not node_selected:
				return AFTER_GUI_INPUT_PASS
			editor.select_mode = MBEditor.SelectMode.VERTEX
		&"select_edge":
			if not node_selected:
				return AFTER_GUI_INPUT_PASS
			editor.select_mode = MBEditor.SelectMode.EDGE
		&"select_face":
			if not node_selected:
				return AFTER_GUI_INPUT_PASS
			editor.select_mode = MBEditor.SelectMode.FACE
		&"select_texture":
			if not node_selected:
				return AFTER_GUI_INPUT_PASS
			editor.select_mode = MBEditor.SelectMode.TEXTURE
		&"select_object":
			if not node_selected:
				return AFTER_GUI_INPUT_PASS
			editor.select_mode = MBEditor.SelectMode.OBJECT
		&"toggle_snap":
			if not (editing or editor.active_mesh != null or shape_creator.is_active() or ngon_drawer.is_active()):
				return AFTER_GUI_INPUT_PASS
			grid.enabled = not grid.enabled
			_sync_snap_button()
			if logger:
				logger.info("tools", "Snapping %s" % ("ON" if grid.enabled else "OFF"))
		&"toggle_xray":
			if not node_selected:
				return AFTER_GUI_INPUT_PASS
			set_xray(not xray_on)
		&"tool_move":
			if not node_selected:
				return AFTER_GUI_INPUT_PASS
			editor.tool_mode = MBEditor.ToolMode.MOVE
		&"tool_rotate":
			if not node_selected:
				return AFTER_GUI_INPUT_PASS
			editor.tool_mode = MBEditor.ToolMode.ROTATE
		&"tool_scale":
			if not node_selected:
				return AFTER_GUI_INPUT_PASS
			editor.tool_mode = MBEditor.ToolMode.SCALE
		&"cycle_space":
			if not editing:
				return AFTER_GUI_INPUT_PASS
			editor.cycle_orientation_space()
		&"snap_selection":
			if not editing:
				return AFTER_GUI_INPUT_PASS
			_on_snap_selection_to_grid()
		&"select_all":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_select_all()
		&"invert_selection":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_invert_selection()
		&"grow_selection":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_grow_selection()
		&"shrink_selection":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_shrink_selection()
		&"select_coplanar":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_select_coplanar()
		&"select_similar":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_select_similar()
		&"select_boundary":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_select_boundary()
		&"select_face_loop":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_select_face_loop(false)
		&"select_face_ring":
			if not editing or editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_perform_select_face_loop(true)
		&"toggle_vertex_snap":
			gizmo_plugin.element_editor.vertex_snap_enabled = not gizmo_plugin.element_editor.vertex_snap_enabled
			if toolbar != null:
				toolbar.sync_snapping(
					gizmo_plugin.element_editor.vertex_snap_enabled,
					gizmo_plugin.element_editor.proportional_enabled,
					gizmo_plugin.element_editor.proportional_radius)
			if logger:
				logger.info("tools", "Vertex Snap %s" % ["ON" if gizmo_plugin.element_editor.vertex_snap_enabled else "OFF"])
		&"op_knife":
			# The knife is the one op that belongs in OBJECT mode too (it picks
			# its own face), so it must not fall into the edit-mode gate below.
			# Pressing it again cancels, like every other modal tool.
			if ngon_drawer.is_active():
				_ngon_drawer_abort("Knife cancelled")
				return AFTER_GUI_INPUT_STOP
			if editor.active_mesh == null:
				return AFTER_GUI_INPUT_PASS
			_on_operation_requested("knife_tool")
		&"toggle_proportional":
			gizmo_plugin.element_editor.proportional_enabled = not gizmo_plugin.element_editor.proportional_enabled
			if logger:
				logger.info("tools", "Proportional Editing %s (radius=%.2f)" % [
					"ON" if gizmo_plugin.element_editor.proportional_enabled else "OFF",
					gizmo_plugin.element_editor.proportional_radius])
		_:
			# Mesh operation keys route into the toolbar ops pipeline; the
			# op itself validates the selection context.
			if not MBActions.OP_ACTION_TO_OPERATION.has(action):
				return AFTER_GUI_INPUT_PASS
			if not editing:
				# Object mode with a mesh selected: the ops edit elements only.
				_op_hint("%s: switch to vertex / edge / face mode first (1 / 2 / 3)"
					% String(MBActions.ACTIONS[action].get("label", action)).replace("Mesh Op: ", ""))
				return AFTER_GUI_INPUT_PASS
			_on_operation_requested(MBActions.OP_ACTION_TO_OPERATION[action])
	return AFTER_GUI_INPUT_STOP

# ==============================================================================
# Snapping
# ==============================================================================

func _on_snap_selection_to_grid() -> void:
	if not editor.is_editing() or editor.active_mesh == null:
		return
	var mesh := editor.active_mesh
	var mesh_data: MBMeshData = mesh.mb_mesh_data
	if mesh_data == null:
		return
	var indices := PackedInt32Array()
	match editor.select_mode:
		MBEditor.SelectMode.VERTEX:
			for group_idx in editor.selection.selected_vertices:
				if group_idx >= 0 and group_idx < mesh_data.shared_vertices.size():
					var sv: MBSharedVertex = mesh_data.shared_vertices[group_idx]
					if sv != null:
						for idx: int in sv.indices:
							indices.append(idx)
		MBEditor.SelectMode.EDGE:
			indices = mesh_data.get_coincident_vertices_from_edges(editor.selection.selected_edges)
		MBEditor.SelectMode.FACE, MBEditor.SelectMode.TEXTURE:
			indices = mesh_data.get_coincident_vertices_from_faces(editor.selection.selected_faces)
	if indices.is_empty():
		return
	var cmd := CmdMeshOp.new(mesh_data, "Snap Selection To Grid", mesh)
	if logger:
		cmd.logger = logger
	var basis := mesh.global_transform.basis
	var inv := basis.inverse()
	var moved := false
	for idx: int in indices:
		if idx < 0 or idx >= mesh_data.positions.size():
			continue
		var world: Vector3 = mesh.global_transform.origin + basis * mesh_data.positions[idx]
		var snapped := grid.snap_point(world)
		var local: Vector3 = inv * (snapped - mesh.global_transform.origin)
		if not (mesh_data.positions[idx] as Vector3).is_equal_approx(local):
			mesh_data.positions[idx] = local
			moved = true
	if not moved:
		return
	mesh_data.invalidate_caches()
	mesh_data.calculate_normals()
	cmd.capture_after()
	if not cmd.is_noop():
		cmd.add_to_undo_manager(get_undo_redo())
	_finish_mesh_op(mesh, "snap_selection", 0)

# ==============================================================================
# Object Selection Handling
# ==============================================================================

func _on_selection_changed() -> void:
	var selection: EditorSelection = get_editor_interface().get_selection()
	var nodes: Array[Node] = selection.get_selected_nodes()

	var mb_mesh: MBMesh = null
	for node in nodes:
		if node is MBMesh:
			mb_mesh = node as MBMesh
	# The LAST MBMesh in the list wins: get_selected_nodes() is in click order,
	# so this is the node the user clicked most recently — the same "primary"
	# object the engine hands _edit(). (Taking the first used to make a
	# two-mesh selection edit the OLDER mesh while the gizmo sat on the newer
	# one.) A mixed selection (MBMesh + plain MeshInstance3D, e.g. while
	# picking a CSG cutter) keeps the MBMesh active.
	# Unconditionally update active_mesh: if a non-MBMesh (or nothing) is selected,
	# active_mesh becomes null so MeshBuilder mode deactivates cleanly.
	# While a knife / n-gon session is running the target MUST stay selected:
	# the editor only forwards viewport input to a plugin whose object is edited,
	# so one stray click on the background used to deselect the mesh and the tool
	# went dead mid-session ("cannot hit anything with the knife").
	if ngon_drawer != null and ngon_drawer.is_active():
		var session_mesh := ngon_drawer.target_mesh
		if session_mesh != null and is_instance_valid(session_mesh) and session_mesh.mb_mesh_data != null:
			editor.active_mesh = session_mesh
			if not _session_reselecting and (mb_mesh == null or not nodes.has(session_mesh)):
				_session_reselecting = true
				selection.clear()
				selection.add_node(session_mesh)
				_session_reselecting = false
			return

	editor.active_mesh = mb_mesh

	# While an element mode is active the scene selection stays narrowed to
	# ONE mesh (see _collapse_selection_to_active): ctrl/shift-adding another
	# node while editing therefore SWITCHES the edit target instead of
	# stacking a second whole-object gizmo that swallows element clicks.
	# (Multi-select workflows — moving several objects, CSG booleans, merge —
	# belong to object mode, where nothing is collapsed.)
	if editor.is_editing():
		_collapse_selection_to_active.call_deferred()

	# Selecting something else while a params session is open cancels it:
	# unconfirmed changes are reverted like clicking Cancel.
	# Re-entrant call from _finish_creation_session's own selection
	# change is a no-op (the session kind is already cleared).
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		if _params_session_kind == "create" and mb_mesh == shape_creator.preview_node:
			pass
		elif _params_session_kind == "bevel" and mb_mesh == _bevel_session_node:
			pass
		elif _params_session_kind == "edit" and mb_mesh == _params_edit_node:
			pass
		elif _params_session_kind == "trim_walls":
			# A wall-picking session survives selection changes: stray clicks
			# that miss a wall select scene nodes but must not tear the
			# session down (only Esc / Cancel / Apply end it).
			pass
		else:
			if logger:
				logger.info("plugin", "Params session cancelled (selection changed)")
			_on_params_canceled()
	# Row-3 Lit / Cast Shadows toggles mirror the selection's combined state.
	_update_object_state_buttons()

# ==============================================================================
# Object State Toggles — Lit / Cast Shadows (row 3 + bindable hotkeys)
# ==============================================================================
# The toggles apply to EVERY selected object (MBMesh, MeshInstance3D, CSG
# primitive). Button semantics follow a mixed checkbox: all on = checked,
# all off = unchecked, mixed = unchecked — checking synchronizes the whole
# selection. All decisions live in MBObjectState (headless-testable); the
# plugin only wraps the returned records into undo actions.

func _selected_state_nodes() -> Array[GeometryInstance3D]:
	var selection: EditorSelection = get_editor_interface().get_selection()
	if selection == null:
		return []
	return MBObjectState.applicable_nodes(selection.get_selected_nodes())

func _update_object_state_buttons() -> void:
	if toolbar == null:
		return
	var nodes := _selected_state_nodes()
	if nodes.is_empty():
		toolbar.sync_object_state(0, 0, false)
		return
	toolbar.sync_object_state(
		MBObjectState.lit_state(nodes), MBObjectState.shadow_state(nodes), true)

## Hotkey semantics: flip the whole selection to the opposite of its
## combined state (mixed counts as "lit"/"casting" → all off).
func _toggle_object_lit() -> void:
	var nodes := _selected_state_nodes()
	if nodes.is_empty():
		return
	_apply_object_lit(nodes, MBObjectState.lit_state(nodes) != 1)

func _toggle_object_shadow() -> void:
	var nodes := _selected_state_nodes()
	if nodes.is_empty():
		return
	_apply_object_shadow(nodes, MBObjectState.shadow_state(nodes) != 1)

func _on_object_lit_toggled(pressed: bool) -> void:
	_apply_object_lit(_selected_state_nodes(), pressed)

func _on_object_shadow_toggled(pressed: bool) -> void:
	_apply_object_shadow(_selected_state_nodes(), pressed)

func _on_xray_toggled(pressed: bool) -> void:
	set_xray(pressed)

## Turns the translucent view of the edited mesh on or off. Materials are not
## mutated: MBXray puts surface overrides on the node and takes them back.
func set_xray(on: bool) -> void:
	if on:
		var mesh := editor.active_mesh
		if mesh == null:
			xray_on = false
			if toolbar != null:
				toolbar.set_xray_active(false)
			return
		if _xray_node != null and _xray_node != mesh and is_instance_valid(_xray_node):
			MBXray.disable(_xray_node)
		xray_on = MBXray.enable(mesh)
		_xray_node = mesh if xray_on else null
	else:
		if _xray_node != null and is_instance_valid(_xray_node):
			MBXray.disable(_xray_node)
		_xray_node = null
		xray_on = false
	if gizmo_plugin != null and gizmo_plugin.element_editor != null:
		gizmo_plugin.element_editor.xray = xray_on
	if toolbar != null:
		toolbar.set_xray_active(xray_on)

func _apply_object_lit(nodes: Array[GeometryInstance3D], lit: bool) -> void:
	var records: Array[Dictionary] = []
	for node in nodes:
		var rec := MBObjectState.set_node_lit(node, lit)
		if not rec.is_empty():
			records.append(rec)
	if records.is_empty():
		_update_object_state_buttons()
		return
	var undo := get_undo_redo()
	var context: Node = records[0]["node"] if records[0]["node"].is_inside_tree() else null
	undo.create_action("Toggle Lit" if lit else "Toggle Unlit", UndoRedo.MERGE_DISABLE, context)
	for rec in records:
		undo.add_do_method(self, "_apply_lit_record", rec, true)
		undo.add_undo_method(self, "_apply_lit_record", rec, false)
	undo.commit_action()
	_update_object_state_buttons()
	if logger:
		logger.info("tools", "%s %d object(s)" % ["Lit" if lit else "Unlit", records.size()])

func _apply_object_shadow(nodes: Array[GeometryInstance3D], cast: bool) -> void:
	var records: Array[Dictionary] = []
	for node in nodes:
		var rec := MBObjectState.set_node_shadow(node, cast)
		if not rec.is_empty():
			records.append(rec)
	if records.is_empty():
		_update_object_state_buttons()
		return
	var undo := get_undo_redo()
	var context: Node = records[0]["node"] if records[0]["node"].is_inside_tree() else null
	undo.create_action("Toggle Cast Shadows" if cast else "Toggle No Cast Shadows",
		UndoRedo.MERGE_DISABLE, context)
	for rec in records:
		undo.add_do_method(self, "_apply_shadow_record", rec, true)
		undo.add_undo_method(self, "_apply_shadow_record", rec, false)
	undo.commit_action()
	_update_object_state_buttons()
	if logger:
		logger.info("tools", "%s shadows on %d object(s)" % ["Cast" if cast else "Removed", records.size()])

## Replays one MBObjectState record; `forward` picks the new/old side.
func _apply_lit_record(rec: Dictionary, forward: bool) -> void:
	var node: Node = rec.get("node")
	if node == null or not is_instance_valid(node):
		return
	match rec.get("kind", ""):
		"pbmesh":
			var pb := node as MBMesh
			if pb == null or pb.mb_mesh_data == null:
				return
			var mats: Array = rec.get("new_materials") if forward else rec.get("old_materials")
			var typed: Array[Material] = []
			for m in mats:
				typed.append(m)
			pb.mb_mesh_data.materials = typed
			pb.rebuild()
		"surfaces", "override":
			var mi := node as MeshInstance3D
			if mi == null:
				return
			if rec.get("kind") == "override":
				mi.material_override = rec.get("new_override") if forward else rec.get("old_override")
			else:
				var overrides: Dictionary = rec.get("new_overrides") if forward else rec.get("old_overrides")
				for idx in overrides:
					mi.set_surface_override_material(int(idx), overrides[idx])
		"csg":
			var csg := node as CSGPrimitive3D
			if csg == null:
				return
			csg.material = rec.get("new_material") if forward else rec.get("old_material")

func _apply_shadow_record(rec: Dictionary, forward: bool) -> void:
	var node: Node = rec.get("node")
	if node == null or not is_instance_valid(node):
		return
	node.cast_shadow = rec.get("new") if forward else rec.get("old")

# ==============================================================================
# Editor State Callbacks
# ==============================================================================

func _on_active_mesh_changed(mesh: MBMesh) -> void:
	if gizmo_plugin != null and gizmo_plugin.element_editor != null \
			and gizmo_plugin.element_editor.drag_active:
		gizmo_plugin.element_editor.commit_subgizmos(editor.active_mesh, PackedInt32Array(), true)
	if mesh != null:
		# broken welds make element ids resolve to raw position pairs, which
		# tears corners apart on drag (the "moved those 2 verts" failure).
		if mesh.mb_mesh_data != null and mesh.mb_mesh_data.ensure_welds():
			mesh.rebuild()
			if logger:
				logger.warn("editor", "Mesh '%s' had missing weld groups — rebuilt from coincident positions" % mesh.name)
		if logger:
			var md: MBMeshData = mesh.mb_mesh_data
			if md != null:
				logger.info("editor", "Mesh '%s': V=%d F=%d weld_groups=%d edges=%d" % [
					mesh.name, md.positions.size(), md.faces.size(),
					md.shared_vertices.size(), md.get_common_edges().size()])
		if gizmo_plugin.gizmo_for_node(mesh) == null:
			# A gizmo-less MBMesh can never be picked or element-edited (its
			# first gizmo request ran before it had an owner). Re-request via
			# the editor's own deferred group call.
			get_tree().call_group_flags(SceneTree.GROUP_CALL_DEFERRED,
				"_spatial_editor_group", "_request_gizmo_for_id", mesh.get_instance_id())
		mesh.update_gizmos()
		# Clicking ANOTHER object while in an element mode lands directly on
		# the element under the cursor — no transient whole-object gizmo.
		# (Deferred: the engine is still finishing its own selection change.)
		if editor.is_editing() and _last_mouse_camera != null \
				and Time.get_ticks_msec() - _last_press_msec < 500:
			_auto_pick_element.call_deferred(mesh)
	else:
		editor.hover_id = -1
	_update_editing_context()
	if material_dock != null:
		material_dock.sync_selection()
	_sync_uv_editor_selection()

## Selects the element under the last click position on `mesh` (single-id
## subgizmo selection — the engine's script API) so the element gizmo shows
## up immediately instead of the whole-object one.
func _auto_pick_element(mesh: MBMesh) -> void:
	if not editor.is_editing() or editor.active_mesh != mesh:
		return
	var gizmo := gizmo_plugin.gizmo_for_node(mesh)
	var id: int = gizmo_plugin.element_editor.pick_ray(
		mesh.mb_mesh_data, mesh.global_transform, _last_mouse_camera, _last_mouse_pos)
	if id >= 0 and gizmo != null:
		mesh.set_subgizmo_selection(gizmo, id,
			gizmo_plugin.element_editor.get_subgizmo_transform(mesh.mb_mesh_data, mesh, id))
	mesh.update_gizmos()

func _on_select_mode_changed(_mode: MBEditor.SelectMode) -> void:
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		_on_params_applied()
	# ProBuilder parity: switching element modes CONVERTS the selection
	# (a face becomes its verts, selected verts become the faces they fully
	# cover, ...). The conversion rides the SAME code path as an ordinary
	# selection: MBSelection holds the converted ids, one seed id represents
	# the set in the engine's subgizmo selection (single-id script API), and
	# the element editor's conversion expansion makes drag/highlight/ops
	# treat it exactly like a hand-picked set. Empty conversions (OBJECT
	# mode, nothing selected, nothing survives) clear, as before.
	var source_faces := editor.selection.selected_faces.duplicate()
	var converted := PackedInt32Array()
	if editor.active_mesh != null and editor.active_mesh.mb_mesh_data != null \
			and editor.select_mode != MBEditor.SelectMode.OBJECT:
		converted = MBSelection.convert_between_modes(
			editor.active_mesh.mb_mesh_data, _last_select_mode, editor.select_mode,
			editor.selection.selected_vertices, editor.selection.selected_edges,
			editor.selection.selected_faces)
	_last_select_mode = editor.select_mode
	editor.selection.clear_all()
	editor.hover_id = -1
	_hover_drawn_last = -1
	gizmo_plugin.element_editor.reset_side_faces()
	if editor.active_mesh != null:
		if converted.is_empty():
			editor.active_mesh.clear_subgizmo_selection()
		else:
			_apply_selection_set(editor.active_mesh, converted, source_faces)
		editor.active_mesh.update_gizmos()
	_update_editing_context()
	# Element modes edit exactly ONE mesh: with several nodes selected the
	# engine keeps a whole-object transform gizmo on every one of them, and
	# that multi-node gizmo swallows the element clicks (faces hover but never
	# select). Entering an element mode therefore narrows the engine
	# selection to the active MBMesh — object mode stays free for the
	# multi-select workflows (move both, CSG booleans, merge).
	if editor.select_mode != MBEditor.SelectMode.OBJECT:
		_collapse_selection_to_active.call_deferred()
	if material_dock != null:
		material_dock.sync_selection()
	_sync_uv_editor_selection()

## Narrows the engine's scene selection to just the active MBMesh (deferred —
## the engine is still finishing its own selection change when the mode
## switch fires). No-op for single/empty selections.
func _collapse_selection_to_active() -> void:
	var mesh := editor.active_mesh
	if mesh == null or not is_instance_valid(mesh):
		return
	var sel: EditorSelection = get_editor_interface().get_selection()
	if sel == null or sel.get_selected_nodes().size() <= 1:
		return
	if not mesh.is_inside_tree():
		return
	if logger:
		logger.info("plugin", "Element mode edits one mesh — selection narrowed to '%s'" % mesh.name)
	sel.clear()
	sel.add_node(mesh)
	_op_hint("Element mode edits one mesh — press 4 for Object mode to select several")

## The element mode the selection currently lives in — the conversion's
## SOURCE when the mode changes (select_mode is already the TARGET by the
## time this handler runs).
var _last_select_mode: MBEditor.SelectMode = MBEditor.SelectMode.OBJECT

## Materializes an element selection set through the ordinary selection path.
## MBSelection gets the ids, and ONE seed id (the element nearest the set's
## centroid) carries the set in the engine via the conversion expansion —
## the seed reports the set's centroid as its pivot so the transform gizmo
## lands on the selection's center. `source_faces` (when coming from a face
## selection) keeps the gizmo oriented to the face the elements were
## selected FROM (ProBuilder pick-side UX). Callers: mode-switch conversion,
## bevel Apply (the new band), bridge/fill (the created faces).
func _apply_selection_set(mesh: MBMesh, ids: PackedInt32Array,
		source_faces: PackedInt32Array) -> void:
	var mesh_data: MBMeshData = mesh.mb_mesh_data
	var ee := gizmo_plugin.element_editor
	var seed := ee.seed_id_nearest_centroid(mesh_data, ids)
	if seed < 0:
		return
	ee.set_conversion_group(seed, ids)
	match editor.select_mode:
		MBEditor.SelectMode.VERTEX:
			editor.selection.set_vertices(ids)
		MBEditor.SelectMode.EDGE:
			var common := mesh_data.get_common_edges()
			var edges: Array[MBEdge] = []
			for eid in ids:
				if eid >= 0 and eid < common.size():
					edges.append(common[eid])
			editor.selection.set_edges(edges)
		MBEditor.SelectMode.FACE, MBEditor.SelectMode.TEXTURE:
			editor.selection.set_faces(ids)
	# Orientation continuity: coming FROM face mode, the seed's gizmo orients
	# to the nearest source face's normal, not an average over the mesh.
	if source_faces.size() > 0 and editor.select_mode != MBEditor.SelectMode.FACE \
			and editor.select_mode != MBEditor.SelectMode.TEXTURE:
		var origin: Vector3 = ee.element_origin(mesh_data, seed)
		var best := -1
		var best_dist := INF
		for fi in source_faces:
			if fi < 0 or fi >= mesh_data.faces.size() or mesh_data.faces[fi] == null:
				continue
			var d: float = ee.element_origin(mesh_data, fi).distance_squared_to(origin)
			if d < best_dist:
				best_dist = d
				best = fi
		if best >= 0:
			ee.pick_side_faces[seed] = best
	var gizmo := gizmo_plugin.gizmo_for_node(mesh)
	if gizmo != null:
		mesh.set_subgizmo_selection(gizmo, seed,
			ee.get_subgizmo_transform(mesh_data, mesh, seed))

func _on_element_selection_changed() -> void:
	if tool_overlay:
		tool_overlay.refresh()
	# Deferred: this fires from inside a gizmo redraw (the engine-selection
	# mirror) — the engine tool must not be flipped re-entrantly.
	_update_engine_tool.call_deferred()
	if material_dock != null:
		material_dock.sync_selection()
	_sync_uv_editor_selection()

func _on_orientation_space_changed(_space: MBEditor.OrientationSpace) -> void:
	# The engine's transform gizmo only adopts a subgizmo's basis while its
	# own local-coords toggle is on (update_transform_gizmo in the engine
	# source) — the bridge flips that toggle, and the engine's `toggled`
	# handler then re-orients the gizmo over the selected subgizmos itself.
	tool_bridge.editor_space = editor.orientation_space
	if editor.is_editing() and tool_bridge.is_ready():
		var applied: bool = tool_bridge.apply_orientation_space(editor.orientation_space)
		if not applied and logger:
			logger.warn("plugin", "Engine local-coords toggle not found — gizmo space cannot be applied")
	# Re-fetch subgizmo transforms so our own gizmo redraw matches too.
	if editor.active_mesh != null:
		editor.active_mesh.update_gizmos()

func _on_tool_mode_changed(_tool: MBEditor.ToolMode) -> void:
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		_on_params_applied()
	_update_engine_tool()
	# The center scale handle lives on the ELEMENT gizmo, which only renders
	# on a redraw — switching MOVE↔SCALE must refresh it or the handle simply
	# does not exist until some unrelated hover change triggers a redraw.
	if editor.active_mesh != null:
		editor.active_mesh.update_gizmos()

## The user switched the engine tool itself (W/E/R or its toolbar buttons)
## while editing — mirror it into the plugin's own tool state.
func _on_engine_tool_selected(tool: int) -> void:
	editor.tool_mode = tool as MBEditor.ToolMode

## Applies the plugin editing context to the editor UI: toolbar buttons,
## engine tool buttons (universal/select disabled while editing, our tool
## forced active), and the overlay panel visibility.
func _update_editing_context() -> void:
	var mesh_selected := editor.active_mesh != null
	if xray_on:
		if editor.active_mesh == null:
			set_xray(false)
		elif editor.active_mesh != _xray_node:
			set_xray(true)
	var editing := editor.is_editing()
	toolbar.set_editing_active(mesh_selected)
	_sync_snap_button()
	tool_overlay.update_visibility()
	if tool_bridge.is_ready():
		grid.set_engine_step(tool_bridge.engine_snap_translate())
		tool_bridge.set_editing_active(editing)
		if editing:
			tool_bridge.editor_space = editor.orientation_space
			tool_bridge.apply_orientation_space(editor.orientation_space)
	else:
		pass
	_update_engine_tool()

func _process(delta: float) -> void:
	_refresh_camera_scaled_gizmos()
## Editor camera position at each node's last camera-driven gizmo refresh.
var _gizmo_cam_pos: Dictionary = {}  # instance id -> Vector3

## Gizmo strokes and face fills are sized by camera distance (the gizmo
## plugin's _live_stroke_offset/_live_fill_offset) and only re-derive on a
## redraw, so the nodes that DRAW such overlays are redrawn while the camera
## moves relative to them. Every MBMesh used to do this from its own
## _process — a script call per mesh per frame, in the editor and in shipped
## games, for meshes that draw nothing camera-scaled at all.
func _refresh_camera_scaled_gizmos() -> void:
	var cam: Camera3D = null
	for i in range(2):
		var vp3: Viewport = get_editor_interface().get_editor_viewport_3d(i)
		if vp3 != null:
			cam = vp3.get_camera_3d()
			if cam != null:
				break
	if cam == null:
		return
	var pos := cam.global_position
	for node in _camera_scaled_gizmo_nodes():
		var id := node.get_instance_id()
		var last: Variant = _gizmo_cam_pos.get(id)
		if last == null or pos.distance_to(last) > maxf(0.02, pos.distance_to(node.global_position) * 0.008):
			_gizmo_cam_pos[id] = pos
			node.update_gizmos()
	if _gizmo_cam_pos.size() > 64:
		for dead in _gizmo_cam_pos.keys().filter(func(k): return not is_instance_id_valid(k)):
			_gizmo_cam_pos.erase(dead)

## The MBMeshes currently drawing camera-scaled overlays: the selection
## (element highlights), the creation preview and hover host, the n-gon
## preview, and the Trim Walls preview / hover / chosen walls.
func _camera_scaled_gizmo_nodes() -> Array[MBMesh]:
	var out: Array[MBMesh] = []
	var sel := get_editor_interface().get_selection()
	if sel != null:
		for n in sel.get_selected_nodes():
			if n is MBMesh:
				out.append(n as MBMesh)
	var extra: Array = []
	if gizmo_plugin != null:
		extra.append(gizmo_plugin.creation_hover_node)
		extra.append(gizmo_plugin.trim_walls_hover_node)
		for w in gizmo_plugin.trim_walls_chosen:
			extra.append(w.get("mesh"))
	if shape_creator != null:
		extra.append(shape_creator.preview_node)
	if ngon_drawer != null:
		extra.append(ngon_drawer.preview_node)
	extra.append(_trim_walls_preview)
	for n in extra:
		if n is MBMesh and is_instance_valid(n) and n.is_inside_tree() and not out.has(n):
			out.append(n as MBMesh)
	return out


func _update_engine_tool() -> void:
	if not tool_bridge.is_ready():
		return
	if not editor.is_editing():
		tool_bridge.apply_tool(editor.tool_mode)
		return
	var sel := editor.selection
	var has_selection := sel != null and (sel.selected_face_count() > 0 \
		or sel.selected_edge_count() > 0 or sel.selected_vertex_count() > 0)
	if has_selection:
		tool_bridge.apply_tool(editor.tool_mode)
	else:
		tool_bridge.press_engine_select_tool()

## Toolbar Panel toggle → overlay pin (and back, keeping both in sync).
func _on_overlay_toggled(pinned: bool) -> void:
	tool_overlay.panel_enabled = pinned
	tool_overlay.pinned = pinned
	if pinned:
		tool_overlay.expand()
		tool_overlay.ensure_visible_and_clamped()
	tool_overlay.update_visibility()

## Explicit toolbar recovery button: resets the panel, forces it visible, uncollapses it.
func _on_reset_panel_requested() -> void:
	if tool_overlay != null:
		tool_overlay.panel_enabled = true
		tool_overlay.pinned = true
		toolbar.set_overlay_pinned(true)
		tool_overlay.expand()
		tool_overlay.reset_to_default_position()
		tool_overlay.update_visibility()
		if logger:
			logger.info("plugin", "Overlay panel recovered to bottom-left corner")

func _on_settings_panel_toggled(open: bool) -> void:
	if tool_overlay == null:
		return
	if open:
		tool_overlay.open_settings()
	else:
		tool_overlay.close_settings()


func _load_display_settings() -> void:
	var grid_op := 0.7
	var wire_op := 0.7
	var sel_op := 0.25
	var hov_op := 0.25
	if _settings != null:
		if _settings.has_setting("meshbuilder/display/wireframe_opacity"):
			wire_op = float(_settings.get_setting("meshbuilder/display/wireframe_opacity"))
		if _settings.has_setting("meshbuilder/display/selection_opacity_v2"):
			sel_op = float(_settings.get_setting("meshbuilder/display/selection_opacity_v2"))
		if _settings.has_setting("meshbuilder/display/hover_opacity_v2"):
			hov_op = float(_settings.get_setting("meshbuilder/display/hover_opacity_v2"))

	gizmo_plugin.apply_display_opacities(wire_op, sel_op, hov_op)
	tool_overlay.sync_display_settings(grid_op, wire_op, sel_op, hov_op)

func _on_display_setting_changed(setting_name: StringName, value: float) -> void:
	match setting_name:
		&"wireframe_opacity":
			gizmo_plugin.apply_display_opacities(value, gizmo_plugin.selection_opacity, gizmo_plugin.hover_opacity)
			if editor.active_mesh != null:
				editor.active_mesh.update_gizmos()
		&"selection_opacity":
			gizmo_plugin.apply_display_opacities(gizmo_plugin.wireframe_opacity, value, gizmo_plugin.hover_opacity)
			if editor.active_mesh != null:
				editor.active_mesh.update_gizmos()
		&"hover_opacity":
			gizmo_plugin.apply_display_opacities(gizmo_plugin.wireframe_opacity, gizmo_plugin.selection_opacity, value)
			if editor.active_mesh != null:
				editor.active_mesh.update_gizmos()
	if _settings != null:
		var key := String(setting_name)
		if key == "selection_opacity" or key == "hover_opacity":
			key += "_v2"
		_settings.set_setting("meshbuilder/display/" + key, value)

func _on_display_reset() -> void:
	_on_display_setting_changed(&"wireframe_opacity", 0.7)
	_on_display_setting_changed(&"selection_opacity", 0.25)
	_on_display_setting_changed(&"hover_opacity", 0.25)
	tool_overlay.sync_display_settings(0.7, 0.7, 0.25, 0.25)

## Focuses the Material & UV dock.
func focus_material_dock() -> void:
	if material_dock == null:
		return
	if _material_panel != null and Engine.is_editor_hint():
		make_bottom_panel_item_visible(_material_panel)
	material_dock.show()
	material_dock.sync_selection()

## Focuses or opens the UV Editor bottom dock panel.
func focus_uv_editor() -> void:
	if uv_editor_panel == null:
		return
	if uv_editor_panel._is_floating:
		if uv_editor_panel._floating_window != null:
			uv_editor_panel._floating_window.show()
			uv_editor_panel._floating_window.grab_focus()
	else:
		if Engine.is_editor_hint():
			make_bottom_panel_item_visible(uv_editor_panel)
	_sync_uv_editor_selection()

func _on_uv_pop_out_toggled(floating: bool) -> void:
	if not Engine.is_editor_hint():
		return
	if floating:
		remove_control_from_bottom_panel(uv_editor_panel)
		_uv_bottom_button = null
	else:
		_uv_bottom_button = add_control_to_bottom_panel(uv_editor_panel, "UV Editor")
		make_bottom_panel_item_visible(uv_editor_panel)

func _sync_uv_editor_selection() -> void:
	if uv_editor_panel == null:
		return
	if uv_editor_panel._syncing_selection:
		return
	if uv_editor_panel.active_mesh != editor.active_mesh:
		uv_editor_panel.active_mesh = editor.active_mesh
	if editor.active_mesh != null and editor.selection != null:
		if uv_editor_panel.has_method("sync_selection_from_3d_state"):
			uv_editor_panel.sync_selection_from_3d_state(editor.select_mode, editor.selection)
		else:
			var sel_faces: Array = []
			for fi in editor.selection.selected_faces:
				sel_faces.append(fi)
			uv_editor_panel.sync_selection_from_3d(sel_faces)

## Programmatically selects a subgizmo element (vertex common_idx, common_edge id, or face index) on `mesh`.
func select_subgizmo_element(mesh: MBMesh, id: int) -> void:
	if mesh == null:
		return
	var gizmo := gizmo_plugin.gizmo_for_node(mesh)
	if gizmo != null:
		if id >= 0:
			var xf := gizmo_plugin.element_editor.get_subgizmo_transform(mesh.mb_mesh_data, mesh, id)
			mesh.set_subgizmo_selection(gizmo, id, xf)
		else:
			mesh.clear_subgizmo_selection()
	mesh.update_gizmos()
func apply_faces_material(mesh: MBMesh, target_faces: Array, material: Material) -> void:
	if mesh == null or mesh.mb_mesh_data == null or target_faces.is_empty() or material == null:
		return

	var previous: Material = mesh.mb_mesh_data.get_face_material(target_faces[0])
	var prepared := MBApplyPrep.prepare(material, previous)
	if prepared != material and logger:
		logger.info("materials", "Applied material prepared: transparency carried from %s"
			% (previous.resource_name if previous != null else "(none)"))

	var before := MBCommand.copy_mesh_data(mesh.mb_mesh_data)
	mesh.mb_mesh_data.set_faces_material(target_faces, prepared)
	var after := MBCommand.copy_mesh_data(mesh.mb_mesh_data)

	var undo := get_undo_redo()
	undo.create_action("Apply Material to Faces", UndoRedo.MERGE_DISABLE, mesh)
	undo.add_do_method(self, "_restore_mesh_snapshot", mesh.get_instance_id(), after)
	undo.add_undo_method(self, "_restore_mesh_snapshot", mesh.get_instance_id(), before)
	undo.commit_action()

	mesh.rebuild()
	mesh.update_gizmos()
	if material_dock != null:
		material_dock.sync_selection()
	if logger:
		var mat_name := prepared.resource_name if not prepared.resource_name.is_empty() else prepared.resource_path.get_file()
		logger.info("materials", "Applied material '%s' to %d face(s) on %s" % [mat_name, target_faces.size(), mesh.name])
## Drag lifecycle signal. Hover is cleared when a drag STARTS; per-update
## refreshes are deliberately NOT done here — the delivery path
## (_set_subgizmo_transform) already redraws the gizmo every motion, and a
## second full redraw per delivery halved the drag frame rate.
var _drag_was_active: bool = false

func _on_drag_updated(active: bool, _t: Vector3, _r: Vector3, _s: Vector3) -> void:
	if active and not _drag_was_active:
		editor.hover_id = -1
		_hover_drawn_last = -1
		if editor.active_mesh != null:
			editor.active_mesh.update_gizmos()
	_drag_was_active = active

## A shift+move / shift+scale gesture committed — face ids shifted, so the
## engine's subgizmo selection and our mirrors are stale. Clear and redraw
## (same dance as an explicit mesh op).
func _on_drag_topology_committed(mesh: MBMesh, new_face_ids: PackedInt32Array = PackedInt32Array()) -> void:
	editor.hover_id = -1
	_hover_drawn_last = -1
	editor.selection.clear_all()
	gizmo_plugin.element_editor.reset_side_faces()
	mesh.clear_subgizmo_selection()
	# Ops that create faces select their output — same rule as the toolbar
	# ops. Without this, a shift+drag extrude of a converted/grouped set
	# (coplanar, similar, mode-switch) left NOTHING selected: the gizmo
	# dropped back to the whole-object pivot and the overlay count went to
	# zero/one even though the whole set had been extruded.
	if not new_face_ids.is_empty() and editor.select_mode == MBEditor.SelectMode.FACE \
			and is_instance_valid(mesh) and mesh.mb_mesh_data != null:
		_apply_selection_set(mesh, new_face_ids, PackedInt32Array())
	mesh.update_gizmos()

# ==============================================================================
# Mesh Operations (overlay OPERATIONS section)
# ==============================================================================

## Numeric params for the toolbar op buttons. The LIVE equivalents are the
## gestures: Shift+Move extrudes, Shift+Scale insets (both drag-driven);
## these buttons use the session defaults.
const OP_EXTRUDE_DISTANCE := 0.25
const OP_INSET_AMOUNT := 0.25
const OP_BEVEL_AMOUNT := 0.1
## Merge by Distance tolerance: 1 mm (exact duplicates and slivers).
const MERGE_BY_DISTANCE_TOLERANCE := 0.001
const OP_BEVEL_SEGMENTS := 1
var op_bevel_amount: float = OP_BEVEL_AMOUNT
var op_bevel_segments: int = OP_BEVEL_SEGMENTS

## Edge ids the gizmo is actually highlighting: engine selection expanded
## through recorded loops. Toolbar clicks must not shrink this to the seed.
func _edge_ids_for_op(mesh_data: MBMeshData) -> PackedInt32Array:
	var seeds := MBMeshOps.common_edge_ids(mesh_data, editor.selection.selected_edges)
	var ee := gizmo_plugin.element_editor if gizmo_plugin != null else null
	if ee == null:
		return seeds
	if seeds.is_empty() and not ee.selected_loops.is_empty():
		seeds = PackedInt32Array()
		for k in ee.selected_loops.keys():
			seeds.append(int(k))
	return ee.expand_edge_ids(mesh_data, seeds)

## Performs a mesh op from the toolbar on the current selection. Face-mode
## ops read the selected faces; edge extrude reads the selected edges. Undo
## goes through full-mesh snapshots (CmdMeshOp) — ops rewrite topology, so
## per-index payloads don't apply.
func _on_operation_requested(op_name: String) -> void:
	# Object-level ops act on the SCENE selection (plain MeshInstance3D /
	# CSGShape3D nodes, or several MBMeshes at once) — they must run even when
	# nothing is being element-edited: converting a raw GLB mesh happens
	# exactly when NO MBMesh is active, so these sit BEFORE the editing gate.
	if op_name == "meshbuilderize" or op_name == "probuilderize":
		_perform_meshbuilderize()
		return
	if op_name == "csg_union":
		_perform_csg_boolean(MBCsg.BooleanOp.UNION)
		return
	if op_name == "csg_subtract":
		_perform_csg_boolean(MBCsg.BooleanOp.SUBTRACT)
		return
	if op_name == "csg_intersect":
		_perform_csg_boolean(MBCsg.BooleanOp.INTERSECT)
		return
	# Whole-object tools (Row 4 + Auto Smooth): they act on the active mesh,
	# not the element selection, so they must ALSO run in OBJECT mode — the
	# editing gate below would swallow the click (Center Pivot was reported
	# dead: its button enables on has_mesh, which OBJECT mode satisfies).
	if op_name == "merge_objects":
		_perform_merge_objects()
		return
	if op_name == "mirror_object":
		_perform_mirror_object()
		return
	if op_name == "center_pivot":
		_perform_center_pivot()
		return
	if op_name == "freeze_transform":
		_perform_freeze_transform()
		return
	if op_name == "smooth_auto":
		_perform_auto_smooth()
		return
	if op_name == "mirror_model":
		_toggle_model_mirror(false)
		return
	if op_name == "mirror_axis_next":
		_toggle_model_mirror(true)
		return
	if op_name == "mirror_apply":
		_apply_model_mirror()
		return
	# Knife needs a mesh, not an element mode: arming it in Object mode and then
	# clicking a face is a normal way to start a cut, so it sits before the gate.
	if op_name == "knife_tool":
		_start_knife_tool()
		return
	if not editor.is_editing() or editor.active_mesh == null:
		return
	# Extrude is ONE action: face mode extrudes faces, edge mode extrudes
	# fins (both the toolbar button and the op key route here).
	if op_name == "extrude_faces" and editor.select_mode == MBEditor.SelectMode.EDGE:
		op_name = "extrude_edges"
	var mesh := editor.active_mesh
	var mesh_data: MBMeshData = mesh.mb_mesh_data
	if mesh_data == null:
		return

	var distance := OP_EXTRUDE_DISTANCE
	var amount := OP_INSET_AMOUNT
	var selection := editor.selection

	if op_name == "detach_faces":
		_perform_detach(mesh, selection.selected_faces.duplicate())
		return
	if op_name == "select_all":
		_perform_select_all()
		return
	if op_name == "invert_selection":
		_perform_invert_selection()
		return
	if op_name == "grow_selection":
		_perform_grow_selection()
		return
	if op_name == "shrink_selection":
		_perform_shrink_selection()
		return
	if op_name == "select_coplanar":
		_perform_select_coplanar()
		return
	if op_name == "select_similar":
		_perform_select_similar()
		return
	if op_name == "select_boundary":
		_perform_select_boundary()
		return
	if op_name == "select_face_loop":
		_perform_select_face_loop(false)
		return
	if op_name == "select_face_ring":
		_perform_select_face_loop(true)
		return
	if op_name == "toggle_vertex_snap":
		gizmo_plugin.element_editor.vertex_snap_enabled = not gizmo_plugin.element_editor.vertex_snap_enabled
		if toolbar != null:
			toolbar.sync_snapping(
				gizmo_plugin.element_editor.vertex_snap_enabled,
				gizmo_plugin.element_editor.proportional_enabled,
				gizmo_plugin.element_editor.proportional_radius)
		return

	var cmd := CmdMeshOp.new(mesh_data, OP_ACTION_NAMES.get(op_name, "Mesh Operation"), mesh)
	if logger:
		cmd.logger = logger
	var result: Dictionary
	match op_name:
		"extrude_faces":
			result = MBMeshOps.extrude_faces(mesh_data, selection.selected_faces.duplicate(), distance)
		"inset_faces":
			result = MBMeshOps.inset_faces(mesh_data, selection.selected_faces.duplicate(), amount)
		"subdivide_faces":
			# Edge mode splits the selected edges at their midpoints; face mode
			# still cuts quads into 4.
			if editor.select_mode == MBEditor.SelectMode.EDGE and not selection.selected_edges.is_empty():
				result = MBMeshOps.subdivide_edges(mesh_data, _edge_ids_for_op(mesh_data))
				if not result.get("ok", false):
					_op_hint("Subdivide edges: %s"
						% String(result.get("error", "failed")).replace("Subdivide edges: ", ""))
			else:
				result = MBMeshOps.subdivide_faces(mesh_data, selection.selected_faces.duplicate())
		"merge_faces":
			result = MBMeshOps.merge_faces(mesh_data, selection.selected_faces.duplicate())
		"delete_faces":
			result = MBMeshOps.delete_faces(mesh_data, selection.selected_faces.duplicate())
		"delete_selection":
			var del_ids: PackedInt32Array
			match editor.select_mode:
				MBEditor.SelectMode.VERTEX:
					del_ids = selection.selected_vertices.duplicate()
				MBEditor.SelectMode.EDGE:
					del_ids = _edge_ids_for_op(mesh_data)
				_:
					del_ids = selection.selected_faces.duplicate()
			result = MBMeshOps.delete_elements(mesh_data, int(editor.select_mode), del_ids)
		"weld_vertices":
			result = MBMeshOps.weld_vertices(mesh_data, selection.selected_vertices.duplicate())
		"extrude_edges":
			var edge_ids := _edge_ids_for_op(mesh_data)
			result = MBMeshOps.extrude_edges(mesh_data, edge_ids, distance)
		"insert_edge_loop":
			var loop_ids := _edge_ids_for_op(mesh_data)
			result = MBMeshOps.insert_edge_loop(mesh_data, loop_ids)
		"bridge_edges":
			var edge_ids := _edge_ids_for_op(mesh_data)
			result = MBMeshOps.bridge_edges(mesh_data, edge_ids)
		"connect_edges":
			if editor.select_mode == MBEditor.SelectMode.VERTEX:
				result = MBMeshOps.connect_vertices(mesh_data, selection.selected_vertices.duplicate())
			else:
				var edge_ids := _edge_ids_for_op(mesh_data)
				result = MBMeshOps.connect_edges(mesh_data, edge_ids)
		"connect_vertices":
			result = MBMeshOps.connect_vertices(mesh_data, selection.selected_vertices.duplicate())
		"tunnel_faces":
			if editor.select_mode != MBEditor.SelectMode.FACE:
				_op_hint("Tunnel: select two faces first (3 = face mode)")
				return
			if selection.selected_faces.size() != 2:
				_op_hint("Tunnel: select exactly 2 faces on opposite sides of the solid")
				return
			result = MBMeshOps.tunnel_faces(mesh_data, selection.selected_faces.duplicate())
			if not result.get("ok", false):
				_op_hint("Tunnel: %s" % String(result.get("error", "failed")).replace("Tunnel: ", ""))
		"merge_by_distance":
			result = MBMeshOps.merge_by_distance(mesh_data, MERGE_BY_DISTANCE_TOLERANCE)
			if not result.get("ok", false):
				_op_hint("Merge by distance: %s" % result.get("error", "failed"))
				return
			if int(result.get("merged", 0)) == 0:
				_op_hint("Merge by distance: nothing closer than %d mm"
					% int(round(MERGE_BY_DISTANCE_TOLERANCE * 1000.0)))
				return
			_op_hint("Merged vertices by distance: %d" % int(result.get("merged", 0)))
		"fill_hole":
			# Vertex mode caps the SELECTED vertices with a face; edge/face modes
			# cap the open boundary loops (a hole that already exists).
			if editor.select_mode == MBEditor.SelectMode.VERTEX and selection.selected_vertex_count() >= 3:
				var picked := PackedInt32Array()
				for cv in selection.selected_vertices:
					picked.append(int(cv))
				result = MBMeshOps.fill_from_vertices(mesh_data, picked)
			else:
				var edge_ids := _edge_ids_for_op(mesh_data)
				result = MBMeshOps.fill_hole(mesh_data, edge_ids)
			if not result.get("ok", false):
				_op_hint("Fill: %s" % String(result.get("error", "failed")).replace("Fill: ", ""))
		"bevel_edges":
			var is_vertex_bevel := editor.select_mode == MBEditor.SelectMode.VERTEX
			var is_face_bevel := false
			var edge_ids: PackedInt32Array
			if is_vertex_bevel:
				pass
			elif editor.select_mode == MBEditor.SelectMode.FACE:
				if selection.selected_faces.size() == mesh_data.faces.size():
					edge_ids = MBMeshOps.face_edges_common_ids(mesh_data, selection.selected_faces)
				else:
					is_face_bevel = true
			else:
				edge_ids = _edge_ids_for_op(mesh_data)


			if is_vertex_bevel and selection.selected_vertices.is_empty():
				_op_hint("Bevel: select vertices first (1 = vertex mode)")
				return
			if not is_vertex_bevel and not is_face_bevel and edge_ids.is_empty():
				_op_hint("Bevel: select edges first (2 = edge mode)")
				return
			if is_face_bevel and selection.selected_faces.is_empty():
				_op_hint("Bevel: select faces first (3 = face mode)")
				return

			var shortest_l := INF
			if is_face_bevel:
				for fi in selection.selected_faces:
					if fi >= 0 and fi < mesh_data.faces.size():
						var f := mesh_data.faces[fi]
						if f != null:
							for e in f.get_edges():
								var l := mesh_data.positions[e.a].distance_to(mesh_data.positions[e.b])
								if l > 0.0001 and l < shortest_l:
									shortest_l = l
			else:
				var common := mesh_data.get_common_edges()
				for eid in edge_ids:
					if eid >= 0 and eid < common.size():
						var ce := common[eid]
						var l := mesh_data.positions[ce.a].distance_to(mesh_data.positions[ce.b])
						if l > 0.0001 and l < shortest_l:
							shortest_l = l

			var eff_amount := op_bevel_amount
			var pre_snapshot := MBCommand.copy_mesh_data(mesh_data)
			var faces_to_bevel := selection.selected_faces.duplicate()
			var edges_to_bevel: Array[MBEdge] = []
			if not is_face_bevel:
				var common_store := mesh_data.get_common_edges()
				for eid in edge_ids:
					if eid >= 0 and eid < common_store.size():
						edges_to_bevel.append(common_store[eid])
			else:
				edges_to_bevel = selection.selected_edges.duplicate()


			if is_vertex_bevel:
				result = MBMeshOps.bevel_vertices(mesh_data, selection.selected_vertices.duplicate(), eff_amount)
			elif is_face_bevel:
				result = MBMeshOps.bevel_faces(mesh_data, faces_to_bevel, eff_amount, op_bevel_segments)
			else:
				result = MBMeshOps.bevel_edges(mesh_data, edge_ids, eff_amount, op_bevel_segments)

			if result.get("ok", false):
				if tool_overlay != null:
					_start_bevel_modal(mesh, is_face_bevel, faces_to_bevel, edges_to_bevel, float(result.get("max_amount", shortest_l)), eff_amount, result.get("new_face_ids", PackedInt32Array()), pre_snapshot, is_vertex_bevel, selection.selected_vertices.duplicate() if is_vertex_bevel else PackedInt32Array())
					return
				_finish_mesh_op(mesh, op_name, int(result.get("new_face_ids", PackedInt32Array()).size()), result.get("new_face_ids", PackedInt32Array()))
			else:
				_op_hint("Bevel: %s — raise Distance in Bevel Settings"
					% String(result.get("error", "failed")).replace("Bevel edges: ", ""))
		_:
			if logger:
				logger.warn("mesh_ops", "Unknown operation requested: %s" % op_name)
			return

	if not result.get("ok", false):
		if logger:
			logger.warn("mesh_ops", "%s failed: %s" % [op_name, result.get("error", "?")])
		return

	cmd.capture_after()
	if not cmd.is_noop():
		cmd.add_to_undo_manager(get_undo_redo())
	_finish_mesh_op(mesh, op_name, int(result.get("new_face_ids", PackedInt32Array()).size()), result.get("new_face_ids", PackedInt32Array()))
## sibling holding the extracted faces. One undo action covers both (the new
## node is registered as a do-reference so undo keeps it alive for redo).
func _perform_detach(mesh: MBMesh, face_ids: PackedInt32Array) -> void:
	var mesh_data: MBMeshData = mesh.mb_mesh_data
	var before := MBCommand.copy_mesh_data(mesh_data)
	var result := MBMeshOps.detach_faces(mesh_data, face_ids)
	if not result["ok"]:
		if logger:
			logger.warn("mesh_ops", "detach failed: %s" % result.get("error", "?"))
		return
	var after := MBCommand.copy_mesh_data(mesh_data)

	var new_node := MBMesh.new()
	new_node.name = _unique_detached_name(mesh)
	new_node.mb_mesh_data = result["detached"]
	# The detached positions are in the SOURCE's local space — copying the
	# source transform keeps the new object exactly where the faces were
	# (position, rotation, and scale), instead of snapping to identity.
	new_node.transform = mesh.transform

	var undo := get_undo_redo()
	undo.create_action("Detach Faces", UndoRedo.MERGE_DISABLE, mesh)
	undo.add_do_method(self, "_restore_mesh_snapshot", mesh.get_instance_id(), after)
	undo.add_do_method(self, "_attach_detached", new_node, mesh.get_parent())
	undo.add_do_reference(new_node)
	undo.add_undo_method(self, "_detach_node", new_node)
	undo.add_undo_method(self, "_restore_mesh_snapshot", mesh.get_instance_id(), before)
	undo.commit_action()

	_finish_mesh_op(mesh, "detach_faces", int(result["new_face_ids"].size()))
	if logger:
		logger.info("mesh_ops", "Detached faces into new node '%s'" % new_node.name)

## Shared tail of every op: element ids changed, so the engine's subgizmo
## selection and our mirror are both stale — clear them and re-render. Ops
## that CREATE faces (bridge, fill hole) select their output through the
## ordinary selection path so the gizmo lands on the new geometry instead
## of going dead until the next click.
func _finish_mesh_op(mesh: MBMesh, op_name: String, new_face_count: int, created_faces: PackedInt32Array = PackedInt32Array()) -> void:
	editor.hover_id = -1
	_hover_drawn_last = -1
	gizmo_plugin.element_editor.reset_side_faces()
	mesh.rebuild()
	editor.selection.clear_all()
	mesh.clear_subgizmo_selection()
	if (op_name == "bridge_edges" or op_name == "fill_hole" or op_name == "tunnel_faces") and not created_faces.is_empty():
		editor.select_mode = MBEditor.SelectMode.FACE
		_apply_selection_set(mesh, created_faces, PackedInt32Array())
	if mesh.mb_mesh_data != null:
		mesh.mb_mesh_data.shape_edited = true
	mesh.update_gizmos()
	if logger:
		logger.info("mesh_ops", "%s: %d new face(s)" % [op_name, new_face_count])
## Undo-history display names per overlay op.
const OP_ACTION_NAMES := {
	"extrude_faces": "Extrude Faces",
	"inset_faces": "Inset Faces",
	"subdivide_faces": "Subdivide Faces",
	"merge_faces": "Merge Faces",
	"delete_faces": "Delete Faces",
	"delete_selection": "Delete Selection",
	"detach_faces": "Detach Faces",
	"extrude_edges": "Extrude Edges",
	"insert_edge_loop": "Insert Edge Loop",

	"weld_vertices": "Weld Vertices",
	"knife_tool": "Knife Cut",
	"bevel_edges": "Bevel Edges",
	"bridge_edges": "Bridge Edges",
	"connect_edges": "Connect",
	"connect_vertices": "Connect Vertices",
	"tunnel_faces": "Tunnel",
	"fill_hole": "Fill Hole",
}
func _perform_select_all() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null:
		return
	var ids := MBSelectionOps.get_all_ids(mesh.mb_mesh_data, editor.select_mode)
	if not ids.is_empty():
		_apply_selection_set(mesh, ids, PackedInt32Array())
	mesh.update_gizmos()

func _perform_invert_selection() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null:
		return
	var cur_ids := editor.selection.get_selected_ids(editor.select_mode)
	var inv_ids := MBSelectionOps.get_inverted_ids(mesh.mb_mesh_data, cur_ids, editor.select_mode)
	if inv_ids.is_empty():
		editor.selection.clear_all()
		var gizmo := gizmo_plugin.gizmo_for_node(mesh)
		if gizmo != null:
			mesh.clear_subgizmo_selection()
	else:
		_apply_selection_set(mesh, inv_ids, PackedInt32Array())
	mesh.update_gizmos()

func _perform_grow_selection() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null:
		return
	editor.selection.grow_selection(editor.select_mode)
	var ids := editor.selection.get_selected_ids(editor.select_mode)
	if not ids.is_empty():
		_apply_selection_set(mesh, ids, PackedInt32Array())
	mesh.update_gizmos()

func _perform_shrink_selection() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null:
		return
	editor.selection.shrink_selection(editor.select_mode)
	var ids := editor.selection.get_selected_ids(editor.select_mode)
	if ids.is_empty():
		editor.selection.clear_all()
		var gizmo := gizmo_plugin.gizmo_for_node(mesh)
		if gizmo != null:
			mesh.clear_subgizmo_selection()
	else:
		_apply_selection_set(mesh, ids, PackedInt32Array())
	mesh.update_gizmos()

func _perform_select_coplanar() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null or editor.select_mode != MBEditor.SelectMode.FACE:
		return
	editor.selection.select_coplanar()
	var ids := editor.selection.selected_faces.duplicate()
	if not ids.is_empty():
		_apply_selection_set(mesh, ids, PackedInt32Array())
	mesh.update_gizmos()

func _perform_select_similar(criteria: String = "material") -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null or editor.select_mode != MBEditor.SelectMode.FACE:
		return
	editor.selection.select_similar(criteria)
	var ids := editor.selection.selected_faces.duplicate()
	if not ids.is_empty():
		_apply_selection_set(mesh, ids, PackedInt32Array())
	mesh.update_gizmos()

func _perform_select_boundary() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null:
		return
	editor.select_mode = MBEditor.SelectMode.EDGE
	var ids := MBSelectionOps.select_boundary_edge_ids(mesh.mb_mesh_data)
	if not ids.is_empty():
		_apply_selection_set(mesh, ids, PackedInt32Array())
	mesh.update_gizmos()

func _perform_select_face_loop(ring: bool = false) -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null or editor.select_mode != MBEditor.SelectMode.FACE:
		return
	editor.selection.select_face_loop(ring)
	var ids := editor.selection.selected_faces.duplicate()
	if not ids.is_empty():
		_apply_selection_set(mesh, ids, PackedInt32Array())
	mesh.update_gizmos()
func _perform_merge_objects() -> void:
	var ei := get_editor_interface()
	var selected_nodes: Array[Node] = []
	if ei != null and ei.get_selection() != null:
		selected_nodes = ei.get_selection().get_selected_nodes()
	var mb_meshes: Array[MBMesh] = []
	for n in selected_nodes:
		if n is MBMesh and (n as MBMesh).mb_mesh_data != null:
			mb_meshes.append(n as MBMesh)
	if mb_meshes.size() < 2:
		if logger:
			logger.warn("plugin", "Merge Objects requires at least 2 selected MBMesh nodes")
		return
	var target := mb_meshes[0]
	var donors: Array[MBMesh] = []
	for i in range(1, mb_meshes.size()):
		donors.append(mb_meshes[i])
	var success := MBObjectOps.merge_meshes(target, donors)
	if success:
		for d in donors:
			if d.get_parent() != null:
				d.get_parent().remove_child(d)
		if logger:
			logger.info("plugin", "Merged %d objects into %s" % [donors.size(), target.name])

## Mirror modifier (Blender's Mirror): the mesh keeps the half you model and
## the render gets its reflection, so editing one side updates the other.
## Nothing is baked — the reflection is compiled at render time.
func _toggle_model_mirror(cycle_axis: bool) -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null:
		_op_hint("Mirror: select an MBMesh first")
		return
	var data := mesh.mb_mesh_data
	var before := MBCommand.copy_mesh_data(data)

	if cycle_axis:
		data.mirror_axis = (data.mirror_axis + 1) % 3
		if not data.mirror_enabled:
			data.mirror_enabled = true
	else:
		data.mirror_enabled = not data.mirror_enabled

	var after := MBCommand.copy_mesh_data(data)
	var undo := get_undo_redo()
	if undo != null:
		undo.create_action("Mirror Model", UndoRedo.MERGE_DISABLE, mesh)
		undo.add_do_method(self, "_restore_mesh_snapshot", mesh.get_instance_id(), after)
		undo.add_undo_method(self, "_restore_mesh_snapshot", mesh.get_instance_id(), before)
		undo.commit_action()

	mesh.rebuild()
	mesh.update_gizmos()
	if toolbar != null:
		toolbar._on_selection_info_changed()
	_op_hint("Mirror %s (axis %s)" % ["ON" if data.mirror_enabled else "OFF",
		["X", "Y", "Z"][clampi(data.mirror_axis, 0, 2)]])

## Bakes the live mirror into real geometry (the modifier then switches off,
## since the reflection is now ordinary faces you can edit).
func _apply_model_mirror() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null:
		_op_hint("Mirror apply: select an MBMesh first")
		return
	var data := mesh.mb_mesh_data
	var has_baked := false
	for f in data.faces:
		if f != null and f.mirror_copy:
			has_baked = true
			break
	if not data.mirror_enabled and not has_baked:
		_op_hint("Mirror apply: turn Mirror Model on first")
		return

	var before := MBCommand.copy_mesh_data(data)
	var axis: int = clampi(data.mirror_axis, 0, 2)
	var res := MBMeshOps.bake_mirror(data, axis)
	if not res.get("ok", false):
		_op_hint("Mirror apply: %s" % String(res.get("error", "failed")).replace("Mirror apply: ", ""))
		return
	# The reflection exists as faces now — a live modifier would double it.
	data.mirror_enabled = false
	var after := MBCommand.copy_mesh_data(data)

	var undo := get_undo_redo()
	if undo != null:
		undo.create_action("Apply Mirror", UndoRedo.MERGE_DISABLE, mesh)
		undo.add_do_method(self, "_restore_mesh_snapshot", mesh.get_instance_id(), after)
		undo.add_undo_method(self, "_restore_mesh_snapshot", mesh.get_instance_id(), before)
		undo.commit_action()

	# Face indices moved: a selection left pointing at them would edit the wrong
	# geometry.
	if editor.selection != null:
		editor.selection.clear_all()
	mesh.rebuild()
	mesh.update_gizmos()
	if toolbar != null:
		toolbar._on_selection_info_changed()
	_op_hint("Mirror applied (%s): %d face(s) baked%s" % [["X", "Y", "Z"][axis], int(res.get("added", 0)),
		", %d old copy(ies) replaced" % int(res.get("removed", 0)) if int(res.get("removed", 0)) > 0 else ""])

func _perform_mirror_object() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null:
		return
	var success := MBObjectOps.mirror_mesh_data(mesh.mb_mesh_data, Vector3.AXIS_X)
	if success:
		mesh.rebuild()
		mesh.update_gizmos()
		if logger:
			logger.info("plugin", "Mirrored %s across X" % mesh.name)

func _perform_center_pivot() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null:
		return
	var success := MBObjectOps.center_pivot(mesh)
	if success:
		mesh.update_gizmos()
		if logger:
			logger.info("plugin", "Centered pivot of %s" % mesh.name)
	elif logger:
		# Factory shapes are built origin-centered: say so instead of the
		# click looking dead.
		logger.info("plugin", "Center Pivot: %s pivot is already at its bounding-box center" % mesh.name)

func _perform_freeze_transform() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null:
		return
	var success := MBObjectOps.freeze_transform(mesh)
	if success:
		mesh.update_gizmos()
		if logger:
			logger.info("plugin", "Froze transform of %s" % mesh.name)

func _collect_convertible_nodes(nodes: Array[Node]) -> Array[Node]:
	var result: Array[Node] = []
	var seen: Dictionary = {}
	for root in nodes:
		if root == null:
			continue
		var stack: Array[Node] = [root]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			if seen.has(n):
				continue
			seen[n] = true
			if (n is MeshInstance3D and not (n is MBMesh)) or (n is CSGShape3D):
				result.append(n)
			for child in n.get_children():
				stack.append(child)
	return result

func _perform_meshbuilderize() -> void:
	var ei := get_editor_interface()
	var selected_nodes: Array[Node] = []
	if ei != null and ei.get_selection() != null:
		selected_nodes = ei.get_selection().get_selected_nodes()
	if selected_nodes.is_empty() and editor.active_mesh != null:
		selected_nodes = [editor.active_mesh]

	var scene_root: Node = ei.get_edited_scene_root() if ei != null else null
	var candidates := _collect_convertible_nodes(selected_nodes)

	if candidates.is_empty():
		if logger:
			logger.warn("plugin", "MeshBuilderize: select a MeshInstance3D, CSGShape3D, or a node with mesh children")
		return

	var undo_mgr := get_undo_redo()
	if undo_mgr != null:
		# Scene-history context (see the CSG action above): scene_root is
		# always in the edited scene; a context-less action would land in the
		# GLOBAL history and interleave with the engine's own scene actions.
		undo_mgr.create_action("MeshBuilderize Meshes", UndoRedo.MERGE_DISABLE,
			scene_root if scene_root != null else candidates[0])

	var created_nodes: Array[MBMesh] = []
	for n in candidates:
		var pb: MBMesh = null
		if n is MeshInstance3D and not (n is MBMesh):
			pb = MBObjectOps.meshbuilderize(n as MeshInstance3D)
		elif n is CSGShape3D:
			pb = MBObjectOps.meshbuilderize_csg(n as CSGShape3D)

		if pb != null:
			var parent := n.get_parent()
			if parent == null and scene_root != null:
				parent = scene_root
			if parent != null:
				pb.transform = n.transform
				created_nodes.append(pb)
				# The whole swap runs through the undo do-methods: adding the
				# MBMesh directly here as well would make the committed
				# add_child a no-op error ("already has a parent") and leave
				# the action's bookkeeping out of sync with the tree.
				if undo_mgr != null:
					undo_mgr.add_do_reference(pb)
					undo_mgr.add_undo_reference(n)
					undo_mgr.add_do_method(parent, "add_child", pb)
					undo_mgr.add_do_method(self, "_own_node", pb)
					undo_mgr.add_do_method(parent, "remove_child", n)
					undo_mgr.add_undo_method(parent, "add_child", n)
					undo_mgr.add_undo_method(parent, "remove_child", pb)
				else:
					parent.add_child(pb)
					pb.owner = scene_root if scene_root != null else parent
					parent.remove_child(n)

	if undo_mgr != null:
		undo_mgr.commit_action()

	if not created_nodes.is_empty():
		if ei != null and ei.get_selection() != null:
			ei.get_selection().clear()
			for pb in created_nodes:
				ei.get_selection().add_node(pb)
			editor.active_mesh = created_nodes[0]
		if logger:
			logger.info("plugin", "MeshBuilderized %d node(s) into editable MBMesh" % created_nodes.size())


func _perform_csg_boolean(op: MBCsg.BooleanOp) -> void:
	var ei := get_editor_interface()
	var selected_nodes: Array[Node] = []
	if ei != null and ei.get_selection() != null:
		selected_nodes = ei.get_selection().get_selected_nodes()

	var candidates: Array[Node] = []
	for n in selected_nodes:
		if (n is MBMesh and (n as MBMesh).mb_mesh_data != null) or (n is CSGShape3D) or (n is MeshInstance3D and not (n is MBMesh)):
			candidates.append(n)

	if candidates.size() < 2:
		if logger:
			logger.warn("plugin", "CSG Booleans require 2 selected objects (Target and Cutter). Select both with Shift/Ctrl.")
		_op_hint("CSG needs 2 objects: press 4 (Object mode), click the target, Shift+click the cutter")
		return

	# The SELECTION ORDER decides the operands — there is no hidden "active
	# mesh" when several nodes are selected: the FIRST-selected node is the
	# target, the LAST-selected node (the one you Shift/Ctrl-clicked last) is
	# the cutter. Select target first, then add the cutter.
	var target_node: Node = candidates[0]
	var cutter_node: Node = candidates[candidates.size() - 1]
	if target_node == cutter_node:
		if logger:
			logger.warn("plugin", "CSG Booleans require 2 different objects (target first, cutter last).")
		return
	if logger:
		logger.info("plugin", "CSG target: %s   cutter: %s" % [target_node.name, cutter_node.name])

	var target_mesh: MBMesh = null
	if target_node is MBMesh:
		target_mesh = target_node as MBMesh
	elif target_node is CSGShape3D:
		target_mesh = MBObjectOps.meshbuilderize_csg(target_node as CSGShape3D)
	elif target_node is MeshInstance3D:
		target_mesh = MBObjectOps.meshbuilderize(target_node as MeshInstance3D)

	if target_mesh == null or target_mesh.mb_mesh_data == null:
		if logger:
			logger.error("plugin", "CSG Error: Target object has no valid mesh")
		return

	var cutter_data: MBMeshData = null
	if cutter_node is MBMesh:
		cutter_data = (cutter_node as MBMesh).mb_mesh_data
	elif cutter_node is CSGShape3D:
		var tmp := MBObjectOps.meshbuilderize_csg(cutter_node as CSGShape3D)
		if tmp != null:
			cutter_data = tmp.mb_mesh_data
			tmp.free()
	elif cutter_node is MeshInstance3D:
		var tmp := MBObjectOps.meshbuilderize(cutter_node as MeshInstance3D)
		if tmp != null:
			cutter_data = tmp.mb_mesh_data
			tmp.free()

	if cutter_data == null:
		if logger:
			logger.error("plugin", "CSG Error: Cutter object has no valid mesh")
		return

	var target_xf: Transform3D = target_node.global_transform if target_node.is_inside_tree() else target_node.transform
	var cutter_xf: Transform3D = cutter_node.global_transform if cutter_node.is_inside_tree() else cutter_node.transform
	var rel_xf := target_xf.affine_inverse() * cutter_xf

	var res := MBCsg.perform_boolean(target_mesh.mb_mesh_data, cutter_data, op, rel_xf, get_tree())
	if not res.get("success", false):
		if logger:
			logger.error("plugin", "CSG Error: %s" % res.get("error", "Unknown error"))
		return

	var before_data := MBCommand.copy_mesh_data(target_mesh.mb_mesh_data)
	var after_data: MBMeshData = res["mesh_data"]

	var op_name_str: String = ["Union", "Intersect", "Subtract"][op]
	var undo_mgr := get_undo_redo()
	if undo_mgr != null:
		# The context object routes this action into the SCENE undo history.
		# Without it the action lands in the GLOBAL history, interleaves with
		# the engine's own scene actions (Translate etc.), and produces
		# "UndoRedo history mismatch" plus resync undos that detached the
		# restored cutter all over again.
		undo_mgr.create_action("CSG %s" % op_name_str, UndoRedo.MERGE_DISABLE, target_node)
		undo_mgr.add_do_method(self, "_restore_csg_mesh", target_mesh, after_data)
		undo_mgr.add_undo_method(self, "_restore_csg_mesh", target_mesh, before_data)
		var cutter_parent := cutter_node.get_parent()
		if cutter_parent != null:
			# The cutter swap follows the engine's own "Remove Node(s)"
			# convention (scene_tree_dock.cpp): a node REMOVED by the do gets
			# an UNDO reference — the detached cutter is freed only if the
			# action falls off the history tail, in its detached state. A DO
			# reference here was a crash: discard_redo() (the very next
			# commit after an undo) deletes do-referenced objects, so it
			# memdeleted the re-attached cutter under the editor — "invalid
			# callable" in add_do_method, then SIGSEGV.
			undo_mgr.add_undo_reference(cutter_node)
			undo_mgr.add_do_method(self, "_detach_node", cutter_node)
			undo_mgr.add_undo_method(self, "_reattach_csg_cutter", cutter_node, cutter_parent)
		undo_mgr.commit_action()
		# The cutter may have been the editor selection — a dangling selection
		# on a detached node breaks viewport picking until the next change.
		if ei != null and ei.get_selection() != null:
			var sel := ei.get_selection()
			sel.clear()
			if target_mesh.is_inside_tree():
				sel.add_node(target_mesh)
		editor.active_mesh = target_mesh
	else:
		target_mesh.mb_mesh_data = after_data
		target_mesh.rebuild()
		target_mesh.update_gizmos()
		if cutter_node.get_parent() != null:
			cutter_node.get_parent().remove_child(cutter_node)

	if logger:
		logger.info("plugin", "CSG %s committed successfully onto %s" % [op_name_str, target_mesh.name])

## Undo half of a CSG boolean: back into the tree, ownership restored to the
## edited scene, gizmo re-requested (a node whose gizmos were torn down on
## detach still renders — but no longer picks or draws its outline — until
## this runs).
func _reattach_csg_cutter(node: Node, parent: Node) -> void:
	if node == null or not is_instance_valid(node) \
			or parent == null or not is_instance_valid(parent):
		return
	if node.get_parent() == parent:
		return
	parent.add_child(node)
	node.owner = get_editor_interface().get_edited_scene_root()
	if node is Node3D:
		(node as Node3D).update_gizmos()

func _restore_csg_mesh(mesh: MBMesh, data: MBMeshData) -> void:
	if mesh != null and is_instance_valid(mesh):
		# A live copy: undo snapshots are cold (no GPU textures) and this one
		# is rendered as-is.
		mesh.mb_mesh_data = MBCommand.copy_mesh_data_live(data)
		mesh.mb_mesh_data.shape_edited = true
		mesh.rebuild()
		mesh.update_gizmos()
func _perform_auto_smooth() -> void:
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null:
		return
	var count := MBSmoothGroups.auto_smooth(mesh.mb_mesh_data, 45.0)
	mesh.rebuild()
	mesh.update_gizmos()
	if logger:
		logger.info("plugin", "Auto-smoothed %s: created %d smoothing groups" % [mesh.name, count])

# ==============================================================================
# Shape Creation (drag base → height → params, ProBuilder-style)
# ==============================================================================


## What the overlay params modal is editing: "create" (a just-placed shape)
## or "edit" (Edit Params on a pristine factory shape).
var _params_session_kind: String = ""
var _params_edit_node: MBMesh = null
var _params_edit_snapshot: MBMeshData = null
var _bevel_session_node: MBMesh = null
var _bevel_session_snapshot: MBMeshData = null
var _bevel_session_mode: MBEditor.SelectMode = MBEditor.SelectMode.OBJECT
var _bevel_session_is_face_bevel: bool = false
var _bevel_session_is_vertex: bool = false
var _bevel_session_vertices: PackedInt32Array = PackedInt32Array()
var _bevel_session_faces: PackedInt32Array = PackedInt32Array()
var _bevel_session_edges: Array[MBEdge] = []
var _bevel_session_last_new_faces: PackedInt32Array = PackedInt32Array()
var _params_edit_values: Dictionary = {}

## A New Shape menu pick ARMS creation: nothing exists yet — the next LMB
## drag on any surface (MBMesh face or grid plane) draws the base. Any open
## params session is committed first (a create session in the modal applies;
## an Edit Params session commits) so the new shape never replaces the node
## a still-open dialog was editing.
func _on_shape_requested(shape_id: StringName) -> void:
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		if not trim_walls_tool.is_active():
			_on_params_applied()
	elif shape_creator.is_active():
		_creation_abort("a new shape was picked")
	elif ngon_drawer.is_active():
		_ngon_drawer_abort("a new shape was picked")
	if trim_walls_tool.is_active():
		_trim_walls_disarm("a new shape was picked")

	if shape_id == &"ngon" or shape_id == &"ngon_draw":
		_start_ngon_shape_tool()
		return
	# Arming must never decide snapping: whatever the user's snap state is,
	# it survives the arm unchanged (a stale apply/restore inside the context
	# update must not get the last word).
	var snap_state_before_arm := grid.enabled
	shape_creator.arm(shape_id)
	# Trim depth carries across the project: a trim "starts at the last Depth
	# you set in this project (5 cm before you set one)" — it is never dragged,
	# so the typed value is the one thing that persists between trims.
	if shape_id == &"trim":
		_seed_trim_project_values()
	# Arming is a MeshBuilder context change too: the engine grid hides and
	# the elevated MeshBuilder grid shows while drawing (engine-bridge a no-op).
	_update_editing_context()
	if grid.enabled != snap_state_before_arm:
		grid.enabled = snap_state_before_arm

	if MBShapeParams.commits_on_base_release(shape_id):
		_set_creation_hint("Trim — drag base along wall, release to commit (Esc cancels)")
	elif MBShapeParams.height_drags_offset(shape_id):
		_set_creation_hint("%s — drag out a sheet on any surface, then move to offset it (Ctrl: lock direction, Esc cancels)"
			% String(shape_id).capitalize())
	else:
		_set_creation_hint("%s — drag a base on any surface (Ctrl: lock direction, Esc cancels)" % String(shape_id).capitalize())
	if logger:
		logger.info("plugin", "Creating '%s' — drag on a surface to draw the base" % shape_id)

## Feeds the overlay's creation row so an armed/dragging session is never
## invisible (a sticky armed state used to swallow clicks "silently").
func _set_creation_hint(text: String) -> void:
	if tool_overlay != null:
		tool_overlay.set_creation_hint(text)

func _creation_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventWithModifiers:
		shape_creator.lock_direction = event.ctrl_pressed or Input.is_key_pressed(KEY_CTRL)
		if shape_creator.state == MBShapeCreator.State.HEIGHT:
			var alt_down: bool = event.alt_pressed or Input.is_key_pressed(KEY_ALT)
			if shape_creator.show_height_plane != alt_down:
				shape_creator.show_height_plane = alt_down
				_refresh_preview()
	elif event is InputEventKey:
		if shape_creator.state == MBShapeCreator.State.HEIGHT:
			var alt_down: bool = event.alt_pressed or Input.is_key_pressed(KEY_ALT)
			if shape_creator.show_height_plane != alt_down:
				shape_creator.show_height_plane = alt_down
				_refresh_preview()

	if event is InputEventMouseMotion:
		_last_mouse_pos = event.position
		_last_mouse_camera = camera
		_creation_motion(camera, event.position)
		return AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			match shape_creator.state:
				MBShapeCreator.State.ARMED:
					if _creation_begin_from_surface(camera, event.position):
						# Consume the press so the engine never starts a
						# marquee / selection under the creation drag.
						return AFTER_GUI_INPUT_STOP
					return AFTER_GUI_INPUT_PASS
				MBShapeCreator.State.HEIGHT, MBShapeCreator.State.OFFSET:
					_creation_confirm()
					return AFTER_GUI_INPUT_STOP
				MBShapeCreator.State.PARAMS:
					# Clicking elsewhere cancels the uncommitted modal changes
					# (reverts to placement values), exactly like clicking Cancel.
					if logger:
						logger.info("plugin", "Params modal cancelled (viewport press)")
					_on_params_canceled()
					return AFTER_GUI_INPUT_PASS
		else:
			if shape_creator.state == MBShapeCreator.State.BASE:
				_creation_end_base()
				return AFTER_GUI_INPUT_STOP

	if event is InputEventKey and event.pressed:
		var k := event as InputEventKey
		if shape_creator.state == MBShapeCreator.State.PARAMS:
			if event.keycode == KEY_ESCAPE:
				_on_params_canceled()
				return AFTER_GUI_INPUT_STOP
			elif event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
				_on_params_applied()
				return AFTER_GUI_INPUT_STOP
			else:
				if logger:
					logger.info("plugin", "Params modal cancelled (key press)")
				_on_params_canceled()
				return AFTER_GUI_INPUT_PASS
		if event.keycode == KEY_ESCAPE:
			# ESC before confirming click: nothing is created at all.
			_creation_abort("cancelled with Escape")
			return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS
## Nearest surface under the cursor: MBMesh faces (world space) with the
## editor grid plane (y = 0) as the fallback. Returns {point, normal} or {} on
## a miss.
func _pick_creation_surface(camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	var ray_o: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_d: Vector3 = camera.project_ray_normal(screen_pos)
	var best_t := INF
	var best := {}
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root != null:
		var mb_hit := MBPicking.scene_ray_pick(MBPicking.collect_pbmeshes(scene_root),
				ray_o, ray_d, [shape_creator.preview_node])
		if not mb_hit.is_empty():
			best_t = mb_hit["distance"]
			best = {"point": mb_hit["point"], "normal": mb_hit["normal"]}

		var plain := MBPicking.pick_plain_mesh_surface(scene_root, ray_o, ray_d, best_t)
		if not plain.is_empty():
			best_t = ray_o.distance_to(plain["point"])
			best = plain

		var w3d := camera.get_world_3d()
		if w3d != null and w3d.direct_space_state != null:
			var ray_query := PhysicsRayQueryParameters3D.create(ray_o, ray_o + ray_d * 2000.0)
			var phys_hit := w3d.direct_space_state.intersect_ray(ray_query)
			if not phys_hit.is_empty() and phys_hit.has("position") and phys_hit.has("normal") and phys_hit.has("collider"):
				var col = phys_hit["collider"]
				var is_pbmesh_col := (col is Node and col.get_parent() is MBMesh)
				if not is_pbmesh_col:
					var dist: float = ray_o.distance_to(phys_hit["position"])
					if dist < best_t - 0.001:
						best_t = dist
						best = {
							"point": phys_hit["position"],
							"normal": phys_hit["normal"]
						}
	if best.is_empty():
		var hit := MBShapeCreator.ray_plane_intersect(ray_o, ray_d, grid.origin, Vector3.UP)
		if hit != MBShapeCreator.RAY_MISS:
			best = {"point": hit, "normal": Vector3.UP}
	return best


func _collect_mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root is MeshInstance3D and not (root is MBMesh):
		out.append(root as MeshInstance3D)
	for child in root.get_children():
		out.append_array(_collect_mesh_instances(child))
	return out

func _creation_begin_from_surface(camera: Camera3D, screen_pos: Vector2) -> bool:
	var hit := _pick_creation_surface(camera, screen_pos)
	if hit.is_empty():
		return false
	var view_z: Vector3 = camera.global_transform.basis.z
	# The visible face's normal opposes the viewing ray. A normal pointing
	# WITH the ray belongs to inward-wound geometry (GLB-sourced meshes with
	# the opposite winding) — shapes placed against it would protrude into
	# the surface and read inside-out ("flipped windings"). Face the viewer.
	var forward: Vector3 = -view_z
	if forward.dot(hit["normal"]) > 0.0:
		hit["normal"] = -hit["normal"]
		_clear_creation_hover()
		_set_creation_hint("move off the surface to set the offset, then click to confirm")
		_make_preview_node()
		_refresh_preview()
		return true
	shape_creator.begin(hit["point"], hit["normal"], view_z)
	# The pressed face's hover highlight dies with the drag start (the base
	# outline takes over); hover stays off until the HEIGHT stage.
	_clear_creation_hover()
	_set_creation_hint("release the mouse, then move to set the height")
	_make_preview_node()
	_refresh_preview()
	return true

func _make_preview_node() -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		_creation_abort("no edited scene")
		return
	var node := MBMesh.new()
	node.name = _unique_shape_name(scene_root, shape_creator.shape_id)
	scene_root.add_child(node)
	# THE OWNER MUST BE SET BEFORE ANYTHING DRAWS: the editor attaches node
	# gizmos only to OWNED nodes, and a node whose first gizmo request ran
	# ownerless never re-requests them (Node3D caches gizmos_requested).
	# Without this, the preview has no gizmo — no outline, no picking, no
	# element editing — for its whole life.
	node.owner = scene_root
	shape_creator.preview_node = node

## Rebuilds the preview mesh + placement from the creator's current values.
## During the BASE phase the rendered MESH is hidden but the NODE stays
## visible — an invisible Node3D also loses its gizmo, which would hide the
## cyan base-rect outline. mb_mesh_data is still assigned (the gizmo's
## redraw needs it to pass its data checks); only the render mesh is
## cleared, AFTER the setter's rebuild.
func _refresh_preview() -> void:
	var node := shape_creator.preview_node
	if node == null:
		return
	var data := shape_creator.build_data()
	if data == null:
		return
	node.transform = shape_creator.placement_transform(data)
	node.mb_mesh_data = data
	if shape_creator.state == MBShapeCreator.State.BASE:
		node.mesh = null
	# rebuild alone never redraws it.
	node.update_gizmos()
	if tool_overlay != null:
		tool_overlay.set_creation_extents(shape_creator.get_extents_readout())
func _creation_motion(camera: Camera3D, screen_pos: Vector2) -> void:
	var ray_o: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_d: Vector3 = camera.project_ray_normal(screen_pos)
	match shape_creator.state:
		MBShapeCreator.State.BASE:
			var hit := MBShapeCreator.ray_plane_intersect(ray_o, ray_d,
				shape_creator.plane_point, shape_creator.plane_normal)
			if hit != MBShapeCreator.RAY_MISS:
				shape_creator.update_base(hit)
				_refresh_preview()
				_update_cursor_extents(screen_pos)
			# No hover highlight while the base drag is out — the cursor is
			# busy drawing the rect, not picking a face.
		MBShapeCreator.State.HEIGHT, MBShapeCreator.State.OFFSET:
			var ref := MBShapeCreator.height_reference_point(camera.global_position,
				-camera.global_transform.basis.z, ray_o, ray_d, shape_creator.rect_center)
			shape_creator.update_height_point(ref)
			_refresh_preview()
			_update_cursor_extents(screen_pos)
			_clear_creation_hover()
		MBShapeCreator.State.PARAMS:
			_clear_creation_hover()
		_:
			_update_creation_hover(camera, screen_pos)

## Creation tools (shape creator / n-gon drawer) raise their shapes against
## the same V-snap state and scene vertices the element editor drags use.
func _wire_creation_vertex_snap() -> void:
	var ee := gizmo_plugin.element_editor
	shape_creator.vertex_snap_active_fn = func() -> bool:
		return ee.is_vertex_snap_active()
	shape_creator.vertex_snap_candidates_fn = func() -> PackedVector3Array:
		return _scene_vertex_candidates(shape_creator.preview_node)
	ngon_drawer.vertex_snap_active_fn = func() -> bool:
		return ee.is_vertex_snap_active()
	ngon_drawer.vertex_snap_candidates_fn = func() -> PackedVector3Array:
		return _scene_vertex_candidates(ngon_drawer.preview_node)

## World-space vertices of every MBMesh except `skip` (the live creation
## preview, whose corners ride the drag and must never catch themselves).
func _scene_vertex_candidates(skip: MBMesh) -> PackedVector3Array:
	var out := PackedVector3Array()
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return out
	var seen := {}
	for m in MBPicking.collect_pbmeshes(scene_root):
		if m == skip or m.mb_mesh_data == null:
			continue
		var xf: Transform3D = m.global_transform
		for p in m.mb_mesh_data.positions:
			var w := xf * p
			var key := Vector3i(roundi(w.x * 1000.0), roundi(w.y * 1000.0), roundi(w.z * 1000.0))
			if not seen.has(key):
				seen[key] = true
				out.append(w)
	return out

## Cyan face highlight under the cursor while creating (skips the preview).
func _update_creation_hover(camera: Camera3D, screen_pos: Vector2) -> void:
	var ray_o: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_d: Vector3 = camera.project_ray_normal(screen_pos)
	var best_t := INF
	var best_node: MBMesh = null
	var best_face := -1
	var best_point := Vector3.ZERO
	var best_normal := Vector3.UP
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root != null:
		var mb_hit := MBPicking.scene_ray_pick(MBPicking.collect_pbmeshes(scene_root),
				ray_o, ray_d, [shape_creator.preview_node])
		if not mb_hit.is_empty():
			best_t = mb_hit["distance"]
			best_node = mb_hit["mesh"]
			best_face = mb_hit["face_index"]
			best_point = mb_hit["point"]
			best_normal = mb_hit["normal"]
		var plain := MBPicking.pick_plain_mesh_surface(scene_root, ray_o, ray_d, best_t)
		if not plain.is_empty():
			best_t = ray_o.distance_to(plain["point"])
			best_node = null
			best_face = -1
			best_point = plain["point"]
			best_normal = plain["normal"]
		var w3d := camera.get_world_3d()
		if w3d != null and w3d.direct_space_state != null:
			var ray_query := PhysicsRayQueryParameters3D.create(ray_o, ray_o + ray_d * 2000.0)
			var phys_hit := w3d.direct_space_state.intersect_ray(ray_query)
			if not phys_hit.is_empty() and phys_hit.has("position") and phys_hit.has("collider"):
				var col = phys_hit["collider"]
				var is_pbmesh_col := (col is Node and col.get_parent() is MBMesh)
				if not is_pbmesh_col:
					var dist: float = ray_o.distance_to(phys_hit["position"])
					if dist < best_t - 0.001:
						best_t = dist
						best_node = null
						best_face = -1
						best_point = phys_hit["position"]
						if phys_hit.has("normal"):
							best_normal = phys_hit["normal"]
	if best_point == Vector3.ZERO:
		var hit := MBShapeCreator.ray_plane_intersect(ray_o, ray_d, grid.origin, Vector3.UP)
		if hit != MBShapeCreator.RAY_MISS:
			best_point = hit
			best_normal = Vector3.UP
			best_node = null
			best_face = -1

	# Snap the hover vertex to the exact starting point creation will use when clicked:
	if shape_creator != null and shape_creator.state == MBShapeCreator.State.ARMED:
		best_point = shape_creator.snap_starting_point(best_point, best_normal)
	elif ngon_drawer != null and ngon_drawer.is_active() and ngon_drawer.state == MBNgonDrawer.State.ARMED:
		best_point = ngon_drawer.snap_starting_point(best_point, best_normal, best_node, best_face)
	
	var target_node: MBMesh = best_node
	var target_face: int = best_face
	if target_node == null and editor.active_mesh != null and is_instance_valid(editor.active_mesh):
		target_node = editor.active_mesh
		target_face = -1

	var prev_node := gizmo_plugin.creation_hover_node
	var node_changed := (target_node != prev_node or target_face != gizmo_plugin.creation_hover_face)
	var pt_changed := gizmo_plugin.creation_hover_point.distance_to(best_point) > 0.001
	if node_changed:
		gizmo_plugin.creation_hover_node = target_node
		gizmo_plugin.creation_hover_face = target_face
		if prev_node != null and is_instance_valid(prev_node):
			prev_node.update_gizmos()
		if target_node != null:
			target_node.update_gizmos()
	elif pt_changed and target_node != null:
		target_node.update_gizmos()
	# Always tracked (cheap): the ARMED cursor square sits at this point.
	gizmo_plugin.creation_hover_point = best_point
func _clear_creation_hover() -> void:
	var prev_node := gizmo_plugin.creation_hover_node
	gizmo_plugin.creation_hover_node = null
	gizmo_plugin.creation_hover_face = -1
	gizmo_plugin.creation_hover_point = Vector3.ZERO
	if prev_node != null and is_instance_valid(prev_node):
		prev_node.update_gizmos()

func _creation_end_base() -> void:
	# end_base() rejects by resetting the creator — which NULLS preview_node.
	# Capture the node FIRST and tear it down ourselves, or an undersized /
	# click-only release leaves the BASE-phase preview (a meshless MBMesh with
	# a live gizmo) in the scene forever: the "errored Shape_Cube + persistent
	# vertex overlay" report.
	var abandoned := shape_creator.preview_node
	if not shape_creator.end_base():
		if abandoned != null and is_instance_valid(abandoned):
			if abandoned.get_parent() != null:
				abandoned.get_parent().remove_child(abandoned)
			abandoned.queue_free()
		_creation_abort("base drag too small")
		return
	if MBShapeParams.commits_on_base_release(shape_creator.shape_id):
		_creation_confirm()
		return
	# Rebuild NOW: the solid preview appears immediately as a flat slab ON
	# the surface (height 0) instead of popping in below it with a jump at
	# the first mouse move.
	_refresh_preview()
	if shape_creator.state == MBShapeCreator.State.OFFSET:
		_set_creation_hint("move to lift it off the surface, then click to confirm")
	else:
		_set_creation_hint("move to size it, then click to confirm (Alt: height plane)")

## The confirming click (after the height drag): the shape exists from here
## on (its node-add undo is registered now). Parameterized shapes open the
## params modal; simple size-only shapes finalize immediately (Edit Params
## is always available afterwards).
func _creation_confirm() -> void:
	# "Otherwise invalid" guard beside the undersized-drag rejection: degenerate
	# geometry (no faces, empty/nan positions) must never become a node — that
	# is what produced broken exclamation-mark nodes whose undo poisoned the
	# tree. Abort like a too-small drag instead.
	var preview := shape_creator.preview_node
	if preview == null or not is_instance_valid(preview) or preview.mb_mesh_data == null \
			or preview.mb_mesh_data.faces.is_empty() \
			or preview.mb_mesh_data.positions.size() < 3:
		_creation_abort("degenerate geometry")
		return
	for p in preview.mb_mesh_data.positions:
		if p.x != p.x or p.y != p.y or p.z != p.z:  # NaN check — finite garbage is bounded below by end_base's extents
			_creation_abort("degenerate geometry")
			return
	shape_creator.confirm_height()
	# The BASE phase keeps the render mesh hidden (the outline shows); shapes
	# that commit on base release (trim) go straight to PARAMS — restore the
	# mesh NOW or the trim stays invisible until the first parameter touch.
	_refresh_preview()
	var node := shape_creator.preview_node
	var scene_root := get_editor_interface().get_edited_scene_root()
	var undo := get_undo_redo()
	undo.create_action("Add %s" % String(shape_creator.shape_id).capitalize(),
		UndoRedo.MERGE_DISABLE, node)
	undo.add_do_method(self, "_attach_detached", node, scene_root)
	undo.add_do_method(self, "_own_node", node)
	undo.add_do_reference(node)
	undo.add_undo_method(self, "_detach_node", node)
	undo.commit_action()
	_set_creation_hint("")
	if tool_overlay != null:
		tool_overlay.set_creation_extents("")
	if _cursor_extents_label != null:
		_cursor_extents_label.visible = false
	shape_creator.show_height_plane = false

	# Select the created node immediately so the editor recognises it as active
	# and doesn't treat initial placement as a deselect event
	var editor_selection := get_editor_interface().get_selection()
	if editor_selection != null and node != null and is_instance_valid(node):
		editor_selection.clear()
		editor_selection.add_node(node)
		editor.active_mesh = node

	if MBShapeParams.needs_params_modal(shape_creator.shape_id):
		_params_session_kind = "create"
		tool_overlay.panel_enabled = true
		tool_overlay.open_params("%s Parameters" % String(shape_creator.shape_id).capitalize(),
			MBShapeParams.get_param_defs(shape_creator.shape_id), shape_creator.values)
		if logger:
			logger.info("plugin", "Placed '%s' — adjust parameters, then Apply/Cancel" % node.name)
	else:
		_finalize_created_shape(node)
		_finish_creation_session(node)
		if logger:
			logger.info("plugin", "Created '%s'" % node.name)

## Stamps the creation bookkeeping onto the node's data from the creator's
## current values (shared by Apply and the no-modal fast path).
func _finalize_created_shape(node: MBMesh) -> void:
	if node == null or not is_instance_valid(node) or node.mb_mesh_data == null:
		return
	node.mb_mesh_data.shape_id = shape_creator.shape_id
	if shape_creator.shape_id == &"trim":
		# "On Wall records which way the strip was drawn" — a recorded flag on
		# the created data (not an editable modal row): true when the drag was
		# drawn on a vertical surface, so the strip lies flat on that wall.
		shape_creator.values["on_wall"] = absf(shape_creator.plane_normal.dot(Vector3.UP)) < 0.5
		_persist_trim_project_values(shape_creator.values)
	node.mb_mesh_data.shape_params = shape_creator.values.duplicate()
	node.mb_mesh_data.shape_edited = false
	node._update_collider()

const TRIM_SETTING_PREFIX := "meshbuilder/trim/"

## Seeds a new trim's depth from the project's last committed value.
func _seed_trim_project_values() -> void:
	if _settings == null or not _settings.has_method("has_setting"):
		return
	var path := TRIM_SETTING_PREFIX + "last_depth"
	if _settings.has_setting(path):
		var d := float(_settings.get_setting(path))
		if d >= 0.005:
			shape_creator.values["depth"] = d

## Remembers the depth a trim was committed with.
func _persist_trim_project_values(values: Dictionary) -> void:
	if _settings == null or not _settings.has_method("set_setting"):
		return
	if values.has("depth"):
		_settings.set_setting(TRIM_SETTING_PREFIX + "last_depth", float(values["depth"]))
func _creation_abort(reason: String) -> void:
	var node := shape_creator.preview_node
	shape_creator.reset()
	if node != null and is_instance_valid(node) and node.get_parent() != null:
		# The preview never entered the undo history — removing it fully
		# un-creates the shape.
		node.get_parent().remove_child(node)
		node.queue_free()
	_clear_creation_hover()
	_set_creation_hint("")
	if tool_overlay != null:
		tool_overlay.set_creation_extents("")
	if _cursor_extents_label != null:
		_cursor_extents_label.visible = false
	shape_creator.show_height_plane = false
	_update_editing_context()
	if logger:
		logger.info("plugin", "Shape creation aborted (%s)" % reason)

## Ends a "create" params session: the node stays either way (Apply keeps the
## edited params, Cancel restored the pre-modal ones), and the plugin hands
## the node over to element editing.
func _finish_creation_session(node: MBMesh) -> void:
	shape_creator.reset()
	_clear_creation_hover()
	_set_creation_hint("")
	if tool_overlay != null:
		tool_overlay.set_creation_extents("")
	if _cursor_extents_label != null:
		_cursor_extents_label.visible = false
	shape_creator.show_height_plane = false
	tool_overlay.close_params()
	_params_session_kind = ""
	if node != null and is_instance_valid(node):
		# A stray undo (or a corrupted session) could have detached the node —
		# re-attach before selecting so add_node sees a live tree node.
		if not node.is_inside_tree():
			_attach_detached(node, get_editor_interface().get_edited_scene_root())
	if MBShapeParams.commits_on_base_release(shape_creator.shape_id):
		_creation_confirm()
		return

func _update_cursor_extents(screen_pos: Vector2) -> void:
	if _cursor_extents_label == null:
		return
	# N-gon height drag: same treatment.
	if ngon_drawer != null and ngon_drawer.is_active() and ngon_drawer.state == MBNgonDrawer.State.HEIGHT:
		var ng_text := ngon_drawer.get_extents_readout()
		if not ng_text.is_empty():
			_show_cursor_extents(ng_text, screen_pos)
			return
	if shape_creator == null or not (shape_creator.state == MBShapeCreator.State.BASE or shape_creator.state == MBShapeCreator.State.HEIGHT or shape_creator.state == MBShapeCreator.State.OFFSET):
		_cursor_extents_label.visible = false
		return

	var text := shape_creator.get_cursor_extents_text()
	if text.is_empty():
		_cursor_extents_label.visible = false
		return

	_show_cursor_extents(text, screen_pos)

func _show_cursor_extents(text: String, screen_pos: Vector2) -> void:
	_cursor_extents_label.text = text
	_cursor_extents_label.visible = true

	var pos := screen_pos + Vector2(18, 18)
	var parent_ctrl := _cursor_extents_label.get_parent_control()
	if parent_ctrl != null:
		var vp_size := parent_ctrl.size
		var lbl_size := _cursor_extents_label.get_minimum_size()
		if pos.x + lbl_size.x > vp_size.x - 10:
			pos.x = maxf(10.0, screen_pos.x - lbl_size.x - 10)
		if pos.y + lbl_size.y > vp_size.y - 10:
			pos.y = maxf(10.0, screen_pos.y - lbl_size.y - 10)
	_cursor_extents_label.position = pos

func _forward_3d_draw_over_viewport(viewport_control: Control) -> void:
	if _cursor_extents_label != null and _cursor_extents_label.is_inside_tree() and _cursor_extents_label.visible:
		return
	if shape_creator == null or not (shape_creator.state == MBShapeCreator.State.BASE or shape_creator.state == MBShapeCreator.State.HEIGHT or shape_creator.state == MBShapeCreator.State.OFFSET):
		return
	var text := shape_creator.get_cursor_extents_text()
	if text.is_empty():
		return
	var font := viewport_control.get_theme_default_font()
	if font == null:
		font = ThemeDB.fallback_font
	var font_size := 14
	var outline_size := 8
	var ascent := font.get_ascent(font_size) if font != null else 12.0
	var pos := _last_mouse_pos + Vector2(18, 18 + ascent)
	viewport_control.draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, outline_size, Color.BLACK)
	viewport_control.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)
func _unique_shape_name(scene_root: Node, shape_id: StringName) -> String:
	var base := "Shape_%s" % String(shape_id).capitalize().replace(" ", "")
	if scene_root.get_node_or_null(NodePath(base)) == null:
		return base
	var i := 2
	while scene_root.get_node_or_null(NodePath("%s%d" % [base, i])) != null:
		i += 1
	return "%s%d" % [base, i]

# ==============================================================================
# Interactive N-Gon Drawing & Knife Tool
# ==============================================================================

func _start_knife_tool() -> void:
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		_on_params_applied()
	if shape_creator.is_active():
		_creation_abort("switched to knife tool")
	if ngon_drawer.is_active():
		_ngon_drawer_abort("switched to knife tool")
	_clear_creation_hover()
	var target_m: MBMesh = editor.active_mesh
	if target_m == null or target_m.mb_mesh_data == null:
		_op_hint("Knife: select an MBMesh first")
		return
	var target_f: int = -1
	if editor.selection != null and editor.selection.selected_face_count() > 0:
		target_f = editor.selection.selected_faces[0]
	ngon_drawer.arm(MBNgonDrawer.Mode.KNIFE, target_m, target_f)
	# No preview node for a cut: `begin` re-targets the face under the first
	# click, and a stray mesh in the scene only gets in the way of saving.
	_update_editing_context()
	_set_creation_hint("Knife: click on a face to place vertices, drag to move, Enter to cut (Esc cancels)")
	if target_m != null:
		target_m.update_gizmos()
	if logger:
		logger.info("plugin", "Knife tool active — click on a face to place vertices")

func _start_ngon_shape_tool() -> void:
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		_on_params_applied()
	if shape_creator.is_active():
		_creation_abort("switched to n-gon tool")
	if ngon_drawer.is_active():
		_ngon_drawer_abort("switched to n-gon tool")
	_clear_creation_hover()
	if editor.active_mesh != null:
		var prev: MBMesh = editor.active_mesh
		editor.active_mesh = null
		prev.update_gizmos()
	var ed_sel := get_editor_interface().get_selection()
	if ed_sel != null:
		ed_sel.clear()
	ngon_drawer.arm(MBNgonDrawer.Mode.NGON_EXTRUDE)
	_make_ngon_preview_node()
	_update_editing_context()
	_set_creation_hint("N-Gon: click a surface to place vertices, drag to move, Enter to size height (Esc cancels)")
	if logger:
		logger.info("plugin", "N-Gon Extrude active — click a surface to draw polygon")
func _ngon_drawer_input(camera: Camera3D, event: InputEvent) -> int:
	_ngon_snap_camera = camera
	if camera != null:
		# The stroke is drawn in screen space: crossed faces are projected along
		# this direction, so a wall that bends between quads still gets cut.
		ngon_drawer.view_dir = -camera.global_transform.basis.z
	if event is InputEventMouseMotion:
		_last_mouse_pos = event.position
		_last_mouse_camera = camera
		_update_ngon_snap_radii()
		var ray_o: Vector3 = camera.project_ray_origin(event.position)
		var ray_d: Vector3 = camera.project_ray_normal(event.position)

		match ngon_drawer.state:
			MBNgonDrawer.State.HEIGHT:
				var ref := MBShapeCreator.height_reference_point(camera.global_position,
					-camera.global_transform.basis.z, ray_o, ray_d, ngon_drawer.plane_point)
				ngon_drawer.update_height_point(ref)
				_refresh_ngon_preview()
				_update_cursor_extents(event.position)
			MBNgonDrawer.State.ARMED:
				_update_creation_hover(camera, event.position)
				var hit := _pick_creation_surface(camera, event.position)
				if not hit.is_empty():
					var pt: Vector3 = hit["point"]
					var best_m: MBMesh = null
					var best_f: int = -1
					var best_dist := INF
					var scene_root := get_editor_interface().get_edited_scene_root()
					if scene_root != null:
						var mb_hit := MBPicking.scene_ray_pick(MBPicking.collect_pbmeshes(scene_root),
								ray_o, ray_d, [ngon_drawer.preview_node])
						if not mb_hit.is_empty():
							best_dist = mb_hit["distance"]
							best_m = mb_hit["mesh"]
							best_f = mb_hit["face_index"]
					var norm: Vector3 = hit.get("normal", Vector3.UP)
					pt = ngon_drawer.snap_starting_point(pt, norm, best_m, best_f)
					ngon_drawer.live_cursor_point = pt
					if ngon_drawer.preview_node != null:
						ngon_drawer.preview_node.update_gizmos()
					elif best_m != null:
						best_m.update_gizmos()
			MBNgonDrawer.State.DRAWING, MBNgonDrawer.State.DRAGGING_VERT:
				# Knife mode: check if cursor hits an adjacent face to switch to
				if ngon_drawer.mode == MBNgonDrawer.Mode.KNIFE and ngon_drawer.target_mesh != null:
					var tm: MBMesh = ngon_drawer.target_mesh
					if tm.mb_mesh_data != null:
						var pick_res := MBPicking.pick_face(tm.mb_mesh_data, tm.global_transform, ray_o, ray_d)
						if pick_res.face_index >= 0 and pick_res.face_index != ngon_drawer.target_face_index:
							if ngon_drawer.can_transition_to_face(pick_res.face_index):
								ngon_drawer.switch_target_face(pick_res.face_index)

				var hit := MBNgonDrawer.ray_plane_intersect(ray_o, ray_d,
					ngon_drawer.plane_point, ngon_drawer.plane_normal)
				if hit != MBNgonDrawer.RAY_MISS:
					ngon_drawer.update_cursor_plane(hit)
					if ngon_drawer.preview_node != null:
						ngon_drawer.preview_node.update_gizmos()
					elif ngon_drawer.target_mesh != null:
						ngon_drawer.target_mesh.update_gizmos()
					elif editor.active_mesh != null:
						editor.active_mesh.update_gizmos()
		return AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_update_ngon_snap_radii()
			match ngon_drawer.state:
				MBNgonDrawer.State.ARMED:
					if _ngon_drawer_begin_from_surface(camera, event.position):
						return AFTER_GUI_INPUT_STOP
					# A click that lands on nothing used to be silent.
					_op_hint("Knife: click on an MBMesh face to start the cut")
					return AFTER_GUI_INPUT_PASS
				MBNgonDrawer.State.DRAWING:
					if ngon_drawer.hovered_vert_idx >= 0:
						if ngon_drawer.hovered_vert_idx == 0 and ngon_drawer.points.size() >= 3:
							_on_ngon_drawer_complete()
							return AFTER_GUI_INPUT_STOP
						else:
							ngon_drawer.start_drag_vert(ngon_drawer.hovered_vert_idx)
							return AFTER_GUI_INPUT_STOP
					else:
						# Re-snap at click time: the stored point must be exactly
						# what the marker showed, so a GREEN marker (corner) can
						# never turn into an edge point because the last motion
						# event is a frame older than the click.
						var ray_o2: Vector3 = camera.project_ray_origin(event.position)
						var ray_d2: Vector3 = camera.project_ray_normal(event.position)
						var hit2 := MBNgonDrawer.ray_plane_intersect(ray_o2, ray_d2,
							ngon_drawer.plane_point, ngon_drawer.plane_normal)
						if hit2 != MBNgonDrawer.RAY_MISS:
							ngon_drawer.update_cursor_plane(hit2)
						ngon_drawer.add_point(ngon_drawer.live_cursor_point)
						if ngon_drawer.preview_node != null:
							ngon_drawer.preview_node.update_gizmos()
						elif ngon_drawer.target_mesh != null:
							ngon_drawer.target_mesh.update_gizmos()
						elif editor.active_mesh != null:
							editor.active_mesh.update_gizmos()
						return AFTER_GUI_INPUT_STOP
				MBNgonDrawer.State.HEIGHT:
					_on_ngon_drawer_confirm_height()
					return AFTER_GUI_INPUT_STOP
		else:
			if ngon_drawer.state == MBNgonDrawer.State.DRAGGING_VERT:
				ngon_drawer.end_drag_vert()
				if ngon_drawer.preview_node != null:
					ngon_drawer.preview_node.update_gizmos()
				elif ngon_drawer.target_mesh != null:
					ngon_drawer.target_mesh.update_gizmos()
				return AFTER_GUI_INPUT_STOP

	if event is InputEventKey:
		var k_mod := event as InputEventKey
		if k_mod.keycode == KEY_ALT:
			ngon_drawer.snap_disabled = k_mod.pressed
			if ngon_drawer.target_mesh != null:
				ngon_drawer.target_mesh.update_gizmos()
	if event is InputEventKey and event.pressed:
		var k := event as InputEventKey
		if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
			if ngon_drawer.state == MBNgonDrawer.State.DRAWING or ngon_drawer.state == MBNgonDrawer.State.DRAGGING_VERT:
				_on_ngon_drawer_complete()
				return AFTER_GUI_INPUT_STOP
			elif ngon_drawer.state == MBNgonDrawer.State.HEIGHT:
				_on_ngon_drawer_confirm_height()
				return AFTER_GUI_INPUT_STOP
		elif k.keycode == KEY_ESCAPE:
			_ngon_drawer_abort("cancelled with Escape")
			return AFTER_GUI_INPUT_STOP

	return AFTER_GUI_INPUT_PASS

## Converts screen pixels to world units at the cursor's depth — the snap
## magnet has to feel the same at any zoom (fixed metres grabbed everything on
## a 0.5 m prop and nothing on a 20 m wall).
func _ngon_snap_px_to_world(camera: Camera3D, at: Vector3, px: float) -> float:
	if camera == null or not camera.is_inside_tree():
		return 0.15
	var depth: float = maxf(0.05, (at - camera.global_position).dot(-camera.global_transform.basis.z))
	var view_h: float = 2.0 * depth * tan(deg_to_rad(camera.fov) * 0.5)
	var vp := camera.get_viewport()
	var vp_h: float = float(vp.get_visible_rect().size.y) if vp != null else 1080.0
	return view_h * px / maxf(1.0, vp_h)

## Refreshes the drawer's snap radii from the current cursor position.
func _update_ngon_snap_radii() -> void:
	if ngon_drawer == null:
		return
	# Alt held = magnet off (aim freely). Read from the live keyboard state on
	# every motion/click so releasing Alt brings the magnet straight back.
	ngon_drawer.snap_disabled = Input.is_key_pressed(KEY_ALT)
	# Radii are face-relative inside the drawer (auto_radii). Assigning them from
	# screen pixels here overwrote that with a one-frame-stale depth and could
	# collapse the magnet to a millimetre.

var _ngon_snap_camera: Camera3D = null
var _session_reselecting: bool = false

## Face of `mesh` closest to a world point (used when the cursor ray lands on a
## neighbour: the knife must stay on the mesh it was armed for).
func _nearest_face_of(mesh: MBMesh, world_point: Vector3) -> int:
	if mesh == null or mesh.mb_mesh_data == null:
		return -1
	var md: MBMeshData = mesh.mb_mesh_data
	var local := mesh.global_transform.affine_inverse() * world_point
	var best := -1
	var best_d := INF
	for fi in md.faces.size():
		var face: MBFace = md.faces[fi]
		if face == null:
			continue
		var idxs := face.get_indexes()
		if idxs.size() < 3:
			continue
		# distance to the face PLANE, then require the point to fall near the
		# face's own triangle fan (cheap: centroid distance)
		var n := MBMath.normal_from_positions(md.positions, idxs)
		if n.length_squared() < 0.000001:
			continue
		var c := Vector3.ZERO
		for vi in idxs:
			c += md.positions[vi]
		c /= float(idxs.size())
		var d := absf(n.normalized().dot(local - c)) + c.distance_to(local) * 0.001
		if d < best_d:
			best_d = d
			best = fi
	return best

func _ngon_drawer_begin_from_surface(camera: Camera3D, screen_pos: Vector2) -> bool:
	var hit := _pick_creation_surface(camera, screen_pos)
	if hit.is_empty():
		return false

	var ray_o: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_d: Vector3 = camera.project_ray_normal(screen_pos)
	var best_mesh: MBMesh = null
	var best_face: int = -1
	var best_dist := INF

	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root != null:
		var mb_hit := MBPicking.scene_ray_pick(MBPicking.collect_pbmeshes(scene_root), ray_o, ray_d)
		if not mb_hit.is_empty():
			best_dist = mb_hit["distance"]
			best_mesh = mb_hit["mesh"]
			best_face = mb_hit["face_index"]

	if ngon_drawer.mode == MBNgonDrawer.Mode.KNIFE:
		if best_mesh == null or best_face < 0:
			return false
		# The knife belongs to the mesh it was armed on: a ray that grazes a
		# corner often hits the NEIGHBOUR face or even another object, and the
		# cut then starts on the wrong surface. Keep the armed mesh and take its
		# face nearest the clicked point.
		var active := editor.active_mesh
		if active != null and best_mesh != active and active.mb_mesh_data != null:
			var best_idx := _nearest_face_of(active, hit["point"])
			if best_idx >= 0:
				best_mesh = active
				best_face = best_idx
		var start_pt := ngon_drawer.snap_starting_point(hit["point"], hit["normal"], best_mesh, best_face)
		ngon_drawer.begin(start_pt, hit["normal"], best_mesh, best_face)
		_clear_creation_hover()
		_set_creation_hint("Knife: click to place cut vertices, drag to move, Enter to complete cut")
		best_mesh.update_gizmos()
		return true
	else:
		var start_pt := ngon_drawer.snap_starting_point(hit["point"], hit["normal"], best_mesh, best_face)
		ngon_drawer.begin(start_pt, hit["normal"], best_mesh, best_face)
		_set_creation_hint("N-Gon: click to place vertices, drag to move, Enter to extrude")
		_make_ngon_preview_node()
		_refresh_ngon_preview()
		return true

func _make_ngon_preview_node() -> void:
	if ngon_drawer.preview_node != null and is_instance_valid(ngon_drawer.preview_node):
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	var node := MBMesh.new()
	node.name = _unique_shape_name(scene_root, &"ngon")
	node.mb_mesh_data = MBShapeGenerators.create_box(Vector3(0.01, 0.01, 0.01))
	node.mesh = null
	scene_root.add_child(node)
	node.owner = scene_root
	ngon_drawer.preview_node = node
	node.update_gizmos()

func _refresh_ngon_preview() -> void:
	var node := ngon_drawer.preview_node
	if node == null:
		return
	if ngon_drawer.state == MBNgonDrawer.State.HEIGHT:
		var data := ngon_drawer.build_preview_data()
		if data != null:
			node.transform = Transform3D.IDENTITY
			node.mb_mesh_data = data
			node.rebuild()
	else:
		node.mesh = null
	node.update_gizmos()
func _on_ngon_drawer_complete() -> void:
	if ngon_drawer.mode == MBNgonDrawer.Mode.NGON_EXTRUDE:
		if ngon_drawer.points.size() < 3:
			_set_creation_hint("N-Gon requires at least 3 vertices to extrude")
			return
		var res := ngon_drawer.complete()
		if res.get("ok", false):
			if ngon_drawer.preview_node == null:
				_make_ngon_preview_node()
			_refresh_ngon_preview()
			_set_creation_hint("move mouse to size height, click to confirm (Esc cancels)")
	elif ngon_drawer.mode == MBNgonDrawer.Mode.KNIFE:
		var target_m := ngon_drawer.target_mesh
		var target_f := ngon_drawer.target_face_index
		if target_m == null or target_m.mb_mesh_data == null or target_f < 0:
			_ngon_drawer_abort("Knife target face lost")
			return

		var cmd := CmdMeshOp.new(target_m.mb_mesh_data, "Knife Cut", target_m)
		if logger:
			cmd.logger = logger

		# A cut that leaves open edges has torn the mesh (an end slid off the
		# border): take the snapshot back instead of committing the damage.
		var open_before: int = MBSelectionOps.select_boundary_edges(target_m.mb_mesh_data).size()
		var snapshot := MBCommand.copy_mesh_data(target_m.mb_mesh_data)
		# A face that has a twin with the same corners (a wall with a face on
		# each side) must be cut on both sides, or the far one stays under the
		# new faces — visible but impossible to select.
		var twins := MBMeshOps.coincident_faces(target_m.mb_mesh_data, target_f)
		var cut_points_world := PackedVector3Array()
		if not twins.is_empty():
			var xf_cut: Transform3D = target_m.global_transform
			for p in ngon_drawer.points:
				cut_points_world.append(xf_cut.affine_inverse() * p)
		var pos_before_cut: int = target_m.mb_mesh_data.positions.size()
		var res := ngon_drawer.complete()
		if res.get("ok", false) and target_m.mb_mesh_data.positions.size() > pos_before_cut:
			# Belt and braces: a vertex the cut created a hair away from an
			# existing one (a corner the green marker pointed at, a seam point)
			# is snapped onto it, so the result reuses the corner instead of
			# adding a second vertex next to it.
			var welded_new: int = MBMeshOps.weld_recent_positions(target_m.mb_mesh_data,
				pos_before_cut, _knife_weld_tolerance(target_m.mb_mesh_data))
			if welded_new > 0:
				target_m.mb_mesh_data.calculate_normals()
				if logger:
					logger.info("mesh_ops", "Knife: snapped %d new vertex/vertices onto existing ones" % welded_new)
		if res.get("ok", false):
			# A torn cut leaves a vertex sitting inside another face's edge.
			# Counting border edges (the old check) was wrong on open walls: a
			# cut that splits the outline legitimately adds border edges, and a
			# good cut was reverted as a "tear".
			var torn: int = MBMeshOps.count_t_junctions(target_m.mb_mesh_data)
			if torn > 0:
				var healed := MBMeshOps.heal_t_junctions(target_m.mb_mesh_data)
				target_m.mb_mesh_data.calculate_normals()
				torn = MBMeshOps.count_t_junctions(target_m.mb_mesh_data)
				if healed > 0 and logger:
					logger.info("mesh_ops", "Knife: healed %d T-junction(s)" % healed)
			if torn > 0:
				MBCommand.restore_mesh_data(target_m.mb_mesh_data, snapshot)
				target_m.rebuild()
				target_m.update_gizmos()
				ngon_drawer.reset()
				_op_hint("Knife: cut would tear the mesh — click on two different edges")
				return
		if not res.get("ok", false):
			if logger:
				logger.warn("mesh_ops", "Knife cut failed: %s" % res.get("error", "?"))
			# Never silent: a refused cut must say why, otherwise Enter looks dead.
			_set_creation_hint("Knife cut failed: %s" % res.get("error", "?"))
			_op_hint("Knife: %s" % res.get("error", "cut failed"))
			return

		if not twins.is_empty() and cut_points_world.size() >= 2 and ngon_drawer.last_cut_closed:
			# Descending order: cutting a face re-indexes the array.
			twins.sort()
			twins.reverse()
			for fi_double in twins:
				if fi_double >= target_m.mb_mesh_data.faces.size():
					continue
				var twin_res := MBMeshOps.cut_face(target_m.mb_mesh_data, fi_double,
					cut_points_world, false)
				if logger and not twin_res.get("ok", false):
					logger.warn("mesh_ops", "Knife: twin face cut skipped: %s" % twin_res.get("error", "?"))

		cmd.capture_after()
		if not cmd.is_noop():
			cmd.add_to_undo_manager(get_undo_redo())

		# Destroy the preview node immediately so no drawing gizmo can linger
		var preview := ngon_drawer.preview_node
		if preview != null and is_instance_valid(preview):
			if preview.get_parent() != null:
				preview.get_parent().remove_child(preview)
			preview.queue_free()
		ngon_drawer.preview_node = null

		# Reset drawer state BEFORE updating target mesh gizmos
		ngon_drawer.reset()
		_clear_creation_hover()
		_set_creation_hint("")

		# Finish mesh op and rebuild target_m gizmos cleanly (drawer is now inactive)
		_finish_mesh_op(target_m, "knife_tool", int(res.get("new_face_ids", []).size()))
		if logger:
			logger.info("plugin", "Knife cut completed on '%s' face %d" % [target_m.name, target_f])
		_update_editing_context()
func _on_ngon_drawer_confirm_height() -> void:
	var node := ngon_drawer.preview_node
	var res := ngon_drawer.confirm_height()
	if not res.get("ok", false) or node == null:
		_ngon_drawer_abort("Failed to finalize N-Gon")
		return

	var data: MBMeshData = res["data"]
	var xf: Transform3D = res["transform"]
	node.transform = xf
	node.mb_mesh_data = data
	node._update_collider()

	var scene_root := get_editor_interface().get_edited_scene_root()
	var undo := get_undo_redo()
	undo.create_action("Add Custom N-Gon", UndoRedo.MERGE_DISABLE, node)
	undo.add_do_method(self, "_attach_detached", node, scene_root)
	undo.add_do_method(self, "_own_node", node)
	undo.add_do_reference(node)
	undo.add_undo_method(self, "_detach_node", node)
	undo.commit_action()

	_clear_creation_hover()
	_set_creation_hint("")
	var editor_selection := get_editor_interface().get_selection()
	if editor_selection != null and is_instance_valid(node):
		editor_selection.clear()
		editor_selection.add_node(node)
		editor.active_mesh = node

	node.update_gizmos()
	if logger:
		logger.info("plugin", "Created custom N-Gon '%s'" % node.name)
	_update_editing_context()

func _ngon_drawer_abort(reason: String) -> void:
	var node := ngon_drawer.preview_node
	var prev_mesh := ngon_drawer.target_mesh
	ngon_drawer.reset()
	if node != null and is_instance_valid(node) and node.get_parent() != null:
		node.get_parent().remove_child(node)
		node.queue_free()
	if prev_mesh != null and is_instance_valid(prev_mesh):
		prev_mesh.update_gizmos()
	_clear_creation_hover()
	_set_creation_hint("")
	_update_editing_context()
	if logger:
		logger.info("plugin", "N-gon drawing aborted (%s)" % reason)

# ==============================================================================
# ==============================================================================


## The top-center banner: one exit reminder for placement modes. No mode can
## be "sticky" any more (the dock is a palette, not a tab switcher), so the
## banner only echoes what the creation hint already says.
func _update_mode_banner() -> void:
	if mode_banner == null or not is_instance_valid(mode_banner):
		return
	mode_banner.set_hint("")


# ==============================================================================
# Trim Walls — click walls, live preview, one committed object
# ==============================================================================

## Arms the Trim Walls session: the trim's parameters appear in the adjust
## panel STRAIGHT AWAY (Placement, profile, sizes are chosen while picking
## walls), and the trim previews as walls are added.
func _on_trim_walls_requested() -> void:
	if _params_session_kind != "" or (tool_overlay != null and tool_overlay.params_open):
		_on_params_applied()
	if shape_creator.is_active():
		_creation_abort("switched to trim walls")
	if ngon_drawer.is_active():
		_ngon_drawer_abort("switched to trim walls")
	_clear_creation_hover()
	trim_walls_tool.arm()
	_trim_walls_ensure_preview()
	_sync_trim_walls_highlights()
	_update_editing_context()
	_params_session_kind = "trim_walls"
	if tool_overlay != null:
		tool_overlay.panel_enabled = true
		tool_overlay.open_params("Trim Walls Parameters",
			MBShapeParams.get_param_defs(&"trim_walls"), trim_walls_tool.params)
	_set_creation_hint("Trim Walls: click wall faces to trim (click again drops, Backspace undoes, Enter applies, Esc cancels)")
	if logger:
		logger.info("plugin", "Trim Walls armed — click wall faces to place the trim")

func _trim_walls_ensure_preview() -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		if logger:
			logger.warn("plugin", "Trim Walls: no edited scene")
		return
	if _trim_walls_preview != null and is_instance_valid(_trim_walls_preview):
		return
	var node := MBMesh.new()
	node.name = _unique_shape_name(scene_root, &"trim_walls")
	scene_root.add_child(node)
	# Owner BEFORE first draw — the editor attaches gizmos only to owned
	# nodes (see _make_preview_node).
	node.owner = scene_root
	_trim_walls_preview = node

## Tears the session down (Esc, Cancel, commit, or switching tools). Frees
## the un-committed preview.
func _trim_walls_disarm(reason: String) -> void:
	trim_walls_tool.disarm()
	gizmo_plugin.trim_walls_session = false
	gizmo_plugin.trim_walls_hover_node = null
	gizmo_plugin.trim_walls_hover_face = -1
	gizmo_plugin.trim_walls_chosen.clear()
	if _trim_walls_preview != null and is_instance_valid(_trim_walls_preview):
		var node := _trim_walls_preview
		_trim_walls_preview = null
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		node.queue_free()
	_set_creation_hint("")
	if tool_overlay != null and _params_session_kind == "trim_walls":
		tool_overlay.close_params()
		_params_session_kind = ""
	_update_editing_context()
	if logger:
		logger.info("plugin", "Trim Walls session ended (%s)" % reason)

func _trim_walls_input(camera: Camera3D, event: InputEvent) -> int:
	_trim_walls_camera = camera
	if event is InputEventMouseMotion:
		_last_mouse_pos = event.position
		_last_mouse_camera = camera
		var pick := _pick_wall_face(camera, event.position)
		var prev_node := gizmo_plugin.trim_walls_hover_node
		var prev_face := gizmo_plugin.trim_walls_hover_face
		var new_node: MBMesh = pick.get("node")
		var new_face: int = pick.get("face", -1)
		if new_node != prev_node or new_face != prev_face:
			gizmo_plugin.trim_walls_hover_node = new_node
			gizmo_plugin.trim_walls_hover_face = new_face
			if prev_node != null and is_instance_valid(prev_node):
				prev_node.update_gizmos()
			if new_node != null:
				new_node.update_gizmos()
		return AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var pick := _pick_wall_face(camera, event.position)
		var mesh: MBMesh = pick.get("node")
		var face: int = pick.get("face", -1)
		if mesh != null and face >= 0:
			# A double-click commits instead of toggling (spec: Enter,
			# double-click or Apply commits) — but only when something is
			# chosen; the toggle itself still runs for a fresh wall.
			var is_double_click: bool = Time.get_ticks_msec() - _trim_walls_last_click_msec < 400 \
				and event.position.distance_to(_trim_walls_last_click_pos) < 10.0
			_trim_walls_last_click_msec = Time.get_ticks_msec()
			_trim_walls_last_click_pos = event.position
			if is_double_click and trim_walls_tool.is_chosen(mesh, face):
				_trim_walls_commit()
				return AFTER_GUI_INPUT_STOP
			var chosen: bool = trim_walls_tool.toggle_wall(mesh, face,
				pick.get("normal", Vector3.ZERO))
			if logger:
				logger.info("plugin", "Trim Walls: %s face %d (%s)"
					% [mesh.name, face, "chosen" if chosen else "dropped"])
			_sync_trim_walls_highlights()
			_refresh_trim_walls_preview()
			return AFTER_GUI_INPUT_STOP
		_trim_walls_last_click_msec = Time.get_ticks_msec()
		_trim_walls_last_click_pos = event.position
		return AFTER_GUI_INPUT_PASS

	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_ESCAPE:
			_on_params_canceled()
			return AFTER_GUI_INPUT_STOP
		elif k.keycode == KEY_BACKSPACE:
			if trim_walls_tool.drop_last():
				_sync_trim_walls_highlights()
				_refresh_trim_walls_preview()
			return AFTER_GUI_INPUT_STOP
		elif k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
			_trim_walls_commit()
			return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS

## Nearest VERTICAL MBMesh face under the cursor (floors/ceilings are not
## walls). Returns {"node": MBMesh, "face": int} or {}.
func _pick_wall_face(camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	var ray_o: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_d: Vector3 = camera.project_ray_normal(screen_pos)
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return {}
	# Walls only: a floor/ceiling face in front of a wall is looked through.
	var hit := MBPicking.scene_ray_pick(MBPicking.collect_pbmeshes(scene_root), ray_o, ray_d,
			[_trim_walls_preview], func(h: Dictionary) -> bool:
				return absf((h["normal"] as Vector3).dot(Vector3.UP)) <= 0.7)
	if hit.is_empty():
		return {}
	# The visible face's normal opposes the viewing ray; inward-wound
	# geometry (GLB sources) yields the flipped one — face the camera so the
	# trim protrudes into the room, never into the wall.
	var world_n: Vector3 = hit["normal"]
	if world_n.dot(ray_d) > 0.0:
		world_n = -world_n
	return {"node": hit["mesh"], "face": hit["face_index"], "normal": world_n}

## Mirrors the session state into the gizmo plugin (teal hover, amber chosen).
func _sync_trim_walls_highlights() -> void:
	gizmo_plugin.trim_walls_session = trim_walls_tool.is_active()
	gizmo_plugin.trim_walls_chosen.clear()
	for w in trim_walls_tool.walls:
		gizmo_plugin.trim_walls_chosen.append(w)
	for node in MBPicking.collect_pbmeshes(get_editor_interface().get_edited_scene_root()):
		if is_instance_valid(node):
			node.update_gizmos()

## Rebuilds the world-space preview from the chosen walls.
func _refresh_trim_walls_preview() -> void:
	if _trim_walls_preview == null or not is_instance_valid(_trim_walls_preview):
		return
	var data := trim_walls_tool.build(_probe_floor_y, _probe_ceiling_y)
	_trim_walls_preview.mb_mesh_data = data
	_trim_walls_preview.transform = Transform3D.IDENTITY
	_trim_walls_preview.rebuild()
	_trim_walls_preview.update_gizmos()
	# The panel must always SAY what the tool understood — silent empty
	# previews read as "broken".
	var count := trim_walls_tool.wall_count()
	if count == 0:
		_set_creation_hint("Trim Walls: click wall faces to trim (click again drops, Backspace undoes, Enter applies, Esc cancels)")
	elif data == null:
		_set_creation_hint("Trim Walls: %d wall face(s) chosen, but none produced a horizontal run at the trim height — pick wall faces, not floors/ceilings" % count)
	else:
		_set_creation_hint("Trim Walls: %d wall face(s) -> %d trim run(s). Enter applies, Esc cancels"
			% [count, trim_walls_tool.last_paths.size()])

## Enter / double-click / panel Apply: the result is ONE new object; its
## recorded paths keep the parameters live for the same walls (Edit Params).
func _trim_walls_commit() -> void:
	if trim_walls_tool.wall_count() == 0:
		if logger:
			logger.warn("plugin", "Trim Walls: click wall faces before applying")
		return
	var data := trim_walls_tool.build(_probe_floor_y, _probe_ceiling_y)
	if data == null or data.faces.is_empty():
		if logger:
			logger.warn("plugin", "Trim Walls: no wall runs in the selection")
		return
	data.shape_id = &"trim_walls"
	data.shape_edited = false
	var params := trim_walls_tool.params.duplicate()
	var recorded: Array = []
	for p in trim_walls_tool.last_paths:
		recorded.append({"points": p["points"], "closed": p["closed"],
			"floor_y": p.get("floor_y", 0.0), "ceil_y": p.get("ceil_y", 0.0)})
	params["wall_paths"] = recorded
	data.shape_params = params
	if data.materials.is_empty():
		var def := MBMeshData.get_default_material()
		if def != null:
			data.materials.append(def)

	var scene_root := get_editor_interface().get_edited_scene_root()
	var node := MBMesh.new()
	node.name = _unique_shape_name(scene_root, &"trim_walls")
	node.transform = Transform3D.IDENTITY
	node.mb_mesh_data = data
	node.rebuild()
	node._update_collider()
	var undo := get_undo_redo()
	if undo != null:
		# Scene-history context (see the CSG action above).
		undo.create_action("Trim Walls", UndoRedo.MERGE_DISABLE, scene_root)
		undo.add_do_method(self, "_attach_detached", node, scene_root)
		undo.add_do_method(self, "_own_node", node)
		undo.add_do_reference(node)
		undo.add_undo_method(self, "_detach_node", node)
		undo.commit_action()
	else:
		_attach_detached(node, scene_root)

	var editor_selection := get_editor_interface().get_selection()
	if editor_selection != null:
		editor_selection.clear()
		editor_selection.add_node(node)
	editor.active_mesh = node
	var wall_total := trim_walls_tool.wall_count()
	_trim_walls_disarm("applied (%d walls)" % wall_total)
	if logger:
		logger.info("plugin", "Trim Walls committed from %d wall face(s)" % wall_total)

## Physics probes for the room-contact rule: the skirting lands on the slab's
## surface (not the wall cube's buried bottom), the cornice tucks under the
## ceiling slab. Return the hit's Y, or NAN for "nothing" (the tool falls
## back to the wall face's own edge).
func _probe_floor_y(from: Vector3) -> float:
	return _probe_surface_y(from, Vector3.DOWN)
func _probe_ceiling_y(from: Vector3) -> float:
	return _probe_surface_y(from, Vector3.UP)
func _probe_surface_y(from: Vector3, dir: Vector3) -> float:
	var cam := _trim_walls_camera
	if cam == null or not cam.is_inside_tree() or cam.get_world_3d() == null:
		return NAN
	var space := cam.get_world_3d().direct_space_state
	if space == null:
		return NAN
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 500.0)
	# Trims are EXCLUDED from the probe: the probe must measure the room
	# shell. Without this the previous preview's collider feeds back into
	# the next build - drift, smoothing-toggle ping-pong, and placement
	# "applying" only to the newest walls.
	var exclude: Array[RID] = []
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root != null:
		for node in MBPicking.collect_pbmeshes(scene_root):
			var sid: StringName = node.mb_mesh_data.shape_id if node.mb_mesh_data != null else &""
			if node == _trim_walls_preview or sid == &"trim" or sid == &"trim_walls":
				for child in node.get_children():
					if child is StaticBody3D:
						exclude.append((child as StaticBody3D).get_rid())
	query.exclude = exclude
	var hit := space.intersect_ray(query)
	if hit.is_empty() or not hit.has("position"):
		return NAN
	return (hit["position"] as Vector3).y

## The last camera seen by the session (probes need a World3D).
var _trim_walls_camera: Camera3D = null

func _get_viewport_host() -> Control:
	var viewport: SubViewport = get_editor_interface().get_editor_viewport_3d(0)
	if viewport != null and viewport.get_parent() != null and viewport.get_parent().get_parent() is Control:
		return viewport.get_parent().get_parent() as Control
	return null


# ==============================================================================
# Texture Splatting & Stamp Viewport Input
# ==============================================================================

# ==============================================================================
# Shape Params modal (create + edit sessions)
# ==============================================================================

func _on_param_changed(param_name: String, value: float) -> void:
	if _params_session_kind == "create":
		shape_creator.set_param(param_name, value)
		_refresh_preview()
	elif _params_session_kind == "trim_walls":
		trim_walls_tool.params[param_name] = value
		_refresh_trim_walls_preview()
	elif _params_session_kind == "bevel":
		if param_name == "distance":
			op_bevel_amount = maxf(value, 0.005)
		elif param_name == "segments":
			op_bevel_segments = clampi(int(round(value)), 1, 8)
		_update_bevel_preview()
	elif _params_session_kind == "edit" and _params_edit_node != null \
			and is_instance_valid(_params_edit_node):
		_params_edit_values[param_name] = value
		var data := _params_edit_node.mb_mesh_data
		if data != null and data.shape_id == &"trim" and param_name == "depth":
			_persist_trim_project_values(_params_edit_values)
		var old_materials: Array[Material] = data.materials.duplicate() if data != null else []
		var rebuilt := MBShapeParams.build(data.shape_id, _params_edit_values)
		if rebuilt != null:
			rebuilt.shape_id = data.shape_id
			rebuilt.shape_params = _params_edit_values.duplicate()
			rebuilt.shape_edited = false

			_params_edit_node.mb_mesh_data = rebuilt
			_params_edit_node.rebuild()
			_params_edit_node.update_gizmos()

## Re-entrancy guard for the params dispatch: committing or cancelling a
## session switches select_mode, and the mode-change handler's "apply any
## open modal first" rule re-enters the dispatch while it is running. With
## two disagreeing mode assignments that ping-ponged EDGE<->FACE until the
## stack blew (the v0.9.105 bevel-Apply crash).
var _params_dispatch_underway := false

func _on_params_applied() -> void:
	if _params_dispatch_underway:
		return
	_params_dispatch_underway = true
	if _params_session_kind == "create":
		var node := shape_creator.preview_node
		shape_creator.values = tool_overlay.get_param_values()
		_finalize_created_shape(node)
		_finish_creation_session(node)
		if logger:
			logger.info("plugin", "Shape parameters applied")
	elif _params_session_kind == "trim_walls":
		trim_walls_tool.params = tool_overlay.get_param_values()
		_trim_walls_commit()
	elif _params_session_kind == "edit":
		_commit_edit_params()
	elif _params_session_kind == "bevel":
		_commit_bevel_session()
	_params_dispatch_underway = false

func _on_params_canceled() -> void:
	if _params_dispatch_underway:
		return
	_params_dispatch_underway = true
	if _params_session_kind == "create":
		var node := shape_creator.preview_node
		shape_creator.cancel_params()
		var data := shape_creator.build_data()
		if node != null and data != null:
			data.shape_id = shape_creator.shape_id
			data.shape_params = shape_creator.values.duplicate()
			node.mb_mesh_data = data
			node.transform = shape_creator.placement_transform(data)
		_finish_creation_session(node)
		if logger:
			logger.info("plugin", "Shape parameters reverted to placement values")
	elif _params_session_kind == "edit":
		if _params_edit_node != null and is_instance_valid(_params_edit_node) \
				and _params_edit_snapshot != null:
			MBCommand.restore_mesh_data(_params_edit_node.mb_mesh_data, _params_edit_snapshot)
			_params_edit_node.rebuild()
			_params_edit_node.update_gizmos()
		_params_session_kind = ""
		_params_edit_node = null
		_params_edit_snapshot = null
		_params_edit_values = {}
		if logger:
			logger.info("plugin", "Shape parameters edit cancelled")
	elif _params_session_kind == "trim_walls":
		_trim_walls_disarm("cancelled")
	elif _params_session_kind == "bevel":
		_cancel_bevel_session()
	else:
		_params_session_kind = ""
		_params_edit_node = null
		_params_edit_snapshot = null
		_params_edit_values = {}

	if tool_overlay != null:
		tool_overlay.close_params()
	_params_dispatch_underway = false

func _start_bevel_modal(mesh: MBMesh, is_face_bevel: bool, faces: PackedInt32Array, edges: Array[MBEdge], max_amount: float, eff_amount: float, new_face_ids: PackedInt32Array, pre_snapshot: MBMeshData,
		is_vertex_bevel: bool = false, vertices: PackedInt32Array = PackedInt32Array()) -> void:
	_params_session_kind = "bevel"
	_bevel_session_node = mesh
	_bevel_session_snapshot = pre_snapshot
	_bevel_session_is_face_bevel = is_face_bevel
	_bevel_session_is_vertex = is_vertex_bevel
	_bevel_session_vertices = vertices
	_bevel_session_faces = faces
	_bevel_session_edges = edges
	_bevel_session_mode = editor.select_mode
	_bevel_session_last_new_faces = new_face_ids
	# The slider max is the op's own representable clamp, so every position on
	# the slider produces a valid bevel — dragging can never toggle between a
	# proper bevel and a refused/tiny one.
	var max_d := maxf(0.05, max_amount) if max_amount < INF else 1.0
	# A vertex bevel is a single flat cut, so it has no segments: showing the
	# slider only invited "I move it and nothing happens".
	var defs := [
		{"name": "distance", "label": "Distance", "min": 0.005, "max": max_d, "step": 0.01, "suffix": "m"},
	]
	if not is_vertex_bevel:
		defs.append({"name": "segments", "label": "Segments", "min": 1, "max": 8, "step": 1, "kind": "int"})
	var values := {
		"distance": eff_amount,
		"segments": op_bevel_segments
	}
	tool_overlay.open_params("Bevel Settings", defs, values)

## One-off message for an op that refused to run (an op fired with nothing
## selected used to do NOTHING at all — indistinguishable from a broken key).
func _op_hint(text: String) -> void:
	_set_creation_hint(text)
	if logger:
		logger.warn("mesh_ops", text)
	var token := _op_hint_token + 1
	_op_hint_token = token
	await get_tree().create_timer(3.0).timeout
	if token == _op_hint_token:
		_set_creation_hint("")
		_update_mode_banner()

var _op_hint_token: int = 0

func _update_bevel_preview() -> void:
	if _bevel_session_node == null or _bevel_session_snapshot == null:
		return
	var mesh_data := _bevel_session_node.mb_mesh_data
	MBCommand.restore_mesh_data(mesh_data, _bevel_session_snapshot)
	var result: Dictionary
	if _bevel_session_is_vertex:
		result = MBMeshOps.bevel_vertices(mesh_data, _bevel_session_vertices, op_bevel_amount)
	elif _bevel_session_is_face_bevel:
		result = MBMeshOps.bevel_faces(mesh_data, _bevel_session_faces, op_bevel_amount, op_bevel_segments)
	else:
		var edge_ids := MBMeshOps.common_edge_ids(mesh_data, _bevel_session_edges)
		if _bevel_session_mode == MBEditor.SelectMode.FACE and _bevel_session_faces.size() == _bevel_session_snapshot.faces.size():
			edge_ids = MBMeshOps.face_edges_common_ids(mesh_data, _bevel_session_faces)
		result = MBMeshOps.bevel_edges(mesh_data, edge_ids, op_bevel_amount, op_bevel_segments)
	if result.get("ok", false):
		_bevel_session_last_new_faces = result.get("new_face_ids", PackedInt32Array())
	# The preview IS the committed state (the commit snapshots it as-is).
	_bevel_session_node.rebuild()
	_bevel_session_node.update_gizmos()

func _commit_bevel_session() -> void:
	if _bevel_session_node == null or _bevel_session_snapshot == null:
		return
	var node := _bevel_session_node
	var data := node.mb_mesh_data
	var before := _bevel_session_snapshot
	var after := MBCommand.copy_mesh_data(data)
	var session_mode := _bevel_session_mode
	var new_faces := _bevel_session_last_new_faces.duplicate()
	# Tear the session down BEFORE touching mode/selection: the mode switch
	# below fires _on_select_mode_changed, whose "apply any open modal first"
	# rule re-enters this commit while the session is still marked open —
	# and two disagreeing mode assignments (session mode vs FACE) then
	# ping-ponged until the stack blew. (The _params_dispatch_underway guard
	# is the second belt; this ordering is the actual fix.)
	_params_session_kind = ""
	_bevel_session_node = null
	_bevel_session_snapshot = null
	_bevel_session_faces = PackedInt32Array()
	_bevel_session_edges = []
	_bevel_session_last_new_faces = PackedInt32Array()
	_bevel_session_is_vertex = false
	_bevel_session_vertices = PackedInt32Array()

	var cmd := CmdMeshOp.new(data, "Bevel", node)
	cmd.before = before
	cmd.after = after
	if logger:
		cmd.logger = logger
	cmd.add_to_undo_manager(get_undo_redo())

	# Dismissing the dialog does NOT deselect: the bevel's own output (the
	# band/corner faces) becomes the selection, through the same path as an
	# ordinary face selection — provided the op produced a valid band. Clear
	# FIRST so the mode switch's conversion runs from a clean slate, then
	# apply the set (works whether or not the FACE switch fires a signal).
	if not new_faces.is_empty() and is_instance_valid(node):
		editor.selection.clear_all()
		node.clear_subgizmo_selection()
		gizmo_plugin.element_editor.reset_side_faces()
		editor.select_mode = MBEditor.SelectMode.FACE
		_apply_selection_set(node, new_faces, PackedInt32Array())
		node.update_gizmos()
	else:
		editor.select_mode = session_mode
		editor.selection.clear_all()
		if is_instance_valid(node):
			node.clear_subgizmo_selection()
			node.update_gizmos()
	if tool_overlay != null:
		tool_overlay.close_params()
	if logger:
		logger.info("plugin", "Bevel operation committed")

func _cancel_bevel_session() -> void:
	var node := _bevel_session_node
	var snapshot := _bevel_session_snapshot
	var session_mode := _bevel_session_mode
	var faces := _bevel_session_faces
	var edges := _bevel_session_edges
	# Session closed before any state work — same re-entrancy contract as
	# the commit path above.
	_params_session_kind = ""
	_bevel_session_node = null
	_bevel_session_snapshot = null
	_bevel_session_faces = PackedInt32Array()
	_bevel_session_edges = []
	_bevel_session_last_new_faces = PackedInt32Array()
	_bevel_session_is_vertex = false
	_bevel_session_vertices = PackedInt32Array()
	if node != null and is_instance_valid(node) and snapshot != null:
		MBCommand.restore_mesh_data(node.mb_mesh_data, snapshot)
		node.rebuild()
		node.update_gizmos()
		editor.select_mode = session_mode
		if session_mode == MBEditor.SelectMode.FACE:
			editor.selection.set_faces(faces)
		elif session_mode == MBEditor.SelectMode.EDGE:
			editor.selection.set_edges(edges)
	if tool_overlay != null:
		tool_overlay.close_params()
	if logger:
		logger.info("plugin", "Bevel cancelled and reverted")
## Edit Params on a pristine factory shape: live param rebuilds; Apply
## commits a snapshot undo, Cancel restores the pre-session data. Ignored
## while another params session is running.
func _on_edit_params_requested() -> void:
	if _params_session_kind != "":
		return
	var mesh := editor.active_mesh
	if mesh == null or mesh.mb_mesh_data == null:
		return
	var data: MBMeshData = mesh.mb_mesh_data
	if data.shape_id == &"" or data.shape_edited:
		if logger:
			logger.warn("plugin", "Edit Params needs an unedited factory shape")
		return
	_params_session_kind = "edit"
	_params_edit_node = mesh
	_params_edit_snapshot = MBCommand.copy_mesh_data(data)
	_params_edit_values = data.shape_params.duplicate()

	tool_overlay.open_params("%s Parameters" % String(data.shape_id).capitalize(),
		MBShapeParams.get_param_defs(data.shape_id), _params_edit_values)

func _commit_edit_params() -> void:
	var node := _params_edit_node
	if node == null or not is_instance_valid(node) or node.mb_mesh_data == null:
		return
	var data := node.mb_mesh_data
	data.shape_params = _params_edit_values.duplicate()
	data.shape_edited = false

	var before := _params_edit_snapshot
	var after := MBCommand.copy_mesh_data(data)
	var undo := get_undo_redo()
	undo.create_action("Edit %s Params" % String(data.shape_id).capitalize(),
		UndoRedo.MERGE_DISABLE, node)
	undo.add_do_method(self, "_restore_mesh_snapshot", node.get_instance_id(), after)
	undo.add_undo_method(self, "_restore_mesh_snapshot", node.get_instance_id(), before)
	undo.commit_action()
	tool_overlay.close_params()
	_params_session_kind = ""
	_params_edit_node = null
	_params_edit_snapshot = null
	_params_edit_values = {}
	if logger:
		logger.info("plugin", "Shape parameters committed")

func _unique_detached_name(mesh: MBMesh) -> String:
	var parent := mesh.get_parent()
	var base := mesh.name + "_Detached"
	if parent == null or parent.get_node_or_null(NodePath(base)) == null:
		return base
	var i := 2
	while parent.get_node_or_null(NodePath("%s%d" % [base, i])) != null:
		i += 1
	return "%s%d" % [base, i]

## Undo/redo payload: swap a mesh's whole data from a snapshot.
func _restore_mesh_snapshot(target: Variant, snapshot: MBMeshData) -> void:
	var mesh: MBMesh = null
	if target is MBMesh:
		mesh = target as MBMesh
	elif target is int:
		mesh = instance_from_id(target) as MBMesh
	if mesh == null or not is_instance_valid(mesh) or mesh.mb_mesh_data == null:
		return
	MBCommand.restore_mesh_data(mesh.mb_mesh_data, snapshot)
	mesh.rebuild()
	mesh.update_gizmos()
	if logger:
		logger.info("undo", "snapshot restored on %s: V=%d F=%d (render rebuilt)" % [
			mesh.name, mesh.mb_mesh_data.positions.size(), mesh.mb_mesh_data.faces.size()])

func _attach_detached(node: Node, parent: Node) -> void:
	if parent == null or not is_instance_valid(parent):
		return
	if node.get_parent() == parent:
		return  # already attached (creation finalize commits against a live preview)
	parent.add_child(node)
	node.owner = get_editor_interface().get_edited_scene_root()

## Undo "do" half for creation: the preview node is already in the tree when
## the action commits — only ownership is missing.
func _own_node(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.owner = get_editor_interface().get_edited_scene_root()

## Undo of detach: remove the node WITHOUT freeing it — the undo history's
## do-reference keeps it alive so redo can re-attach it.
func _detach_node(node: Node) -> void:
	if node != null and is_instance_valid(node) and node.get_parent() != null:
		node.get_parent().remove_child(node)
