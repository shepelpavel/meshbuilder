## MBMaterialDock — Material picker, UV mapping, shapes and sprite placement dock for MeshBuilder.
##
## Docks to the right of the 3D viewport (DOCK_SLOT_RIGHT_UL), to the left of the Inspector.
## Toggleable from the MeshBuilder toolbar.
##
## Modes:
## - Material & UV:
##   - Material Picker: Click a material card -> applies to selected face(s) (or whole mesh in Object mode).
##   - UV Tiling & Mapping: x2, /2, Reset (1m), 45° Diagonal, manual tiling, offset, angle, flips.
##   - Face Tint: ColorPickerButton setting vertex color tint.
## - Shapes: always-armed primitive placement.
## - Sprite: billboard sprite placement.
@tool
class_name MBMaterialDock
extends PanelContainer

enum DockMode { MATERIAL, SPRITE, SHAPE }
const DEFAULT_MATERIAL_PATH := "res://addons/meshbuilder/materials/mb_default_material.tres"
const SETTING_DEFAULT_MATERIAL := "meshbuilder/materials/default_material_path"

## Emitted when the mode row switches tabs. The plugin owns what each mode
## ARMS in the viewport (sprite placement, shape placement) and drives the
## in-scene mode banner; the dock only reflects and reports.
signal dock_mode_changed(new_mode: DockMode)

## Reference to the main MeshBuilder plugin.
var plugin: EditorPlugin = null
var editor: MBEditor = null:
	set = set_editor

var sprite_placer: MBSpritePlacer = null

var dock_mode: DockMode = DockMode.MATERIAL

var _default_material_path: String = DEFAULT_MATERIAL_PATH
var _project_materials: Array[Material] = []

# UI Nodes - Mode Row
var _btn_mode_mat: Button
var _btn_mode_sprite: Button
var _btn_mode_shape: Button
# UI Nodes - Materials Section
var _material_grid: HFlowContainer
var _status_label: Label
var _file_dialog: EditorFileDialog

# UI Nodes - Sections Container
var _uv_and_tint_section: VBoxContainer
var _sprite_tool_section: VBoxContainer
var _shape_tool_section: VBoxContainer

# Sprite Tool Controls
var _active_sprite_drop_box: PanelContainer
var _active_sprite_icon: TextureRect
var _active_sprite_label: Label

var _sprite_hint: Label

# Shape Tool Controls
var _shape_palette_grid: HFlowContainer
var _shape_hint: Label
var _shape_card_buttons: Dictionary = {}  # StringName shape_id -> Button
var _selected_shape_id: StringName = &"cube"
static var _shape_preview_cache: Dictionary = {}  # StringName shape_id -> ImageTexture

# Particle Tool Controls
# UV Controls
var _btn_x2: Button
var _btn_half: Button
var _btn_reset_uv: Button
var _btn_diagonal: Button
var _spin_tiling_u: Range
var _spin_tiling_v: Range
var _spin_offset_u: Range
var _spin_offset_v: Range
var _spin_angle: Range
var _chk_flip_u: CheckBox
var _chk_flip_v: CheckBox

# Tint Controls
var _color_picker: ColorPickerButton
var _btn_reset_tint: Button

# Scrolling Texture (animated UV) Controls

# Paint Tool Controls

# Stamp Tool Controls
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
	_ensure_shape_previews.call_deferred()

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

	# 1. Mode Selector Segmented Row
	var mode_row := HBoxContainer.new()
	mode_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_btn_mode_sprite = Button.new()
	_btn_mode_sprite.text = "Sprite"
	_btn_mode_sprite.tooltip_text = "Billboard Sprites: always-armed sprite placement — pick a sprite, then click any surface to place it"
	_btn_mode_sprite.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_mode_sprite.toggle_mode = true
	_btn_mode_sprite.button_pressed = (dock_mode == DockMode.SPRITE)
	_btn_mode_sprite.pressed.connect(func(): _set_dock_mode(DockMode.SPRITE))
	mode_row.add_child(_btn_mode_sprite)

	_btn_mode_shape = Button.new()
	_btn_mode_shape.text = "Shapes"
	_btn_mode_shape.tooltip_text = "Shape Placement: always-armed primitive creation — pick a shape, then drag on any surface to draw it"
	_btn_mode_shape.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_mode_shape.toggle_mode = true
	_btn_mode_shape.button_pressed = (dock_mode == DockMode.SHAPE)
	_btn_mode_shape.pressed.connect(func(): _set_dock_mode(DockMode.SHAPE))
	mode_row.add_child(_btn_mode_shape)

	root_vbox.add_child(mode_row)
	root_vbox.add_child(HSeparator.new())

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

	# =========================================================================
	# Section A: Material & UV Controls (Visible in MATERIAL mode)
	# =========================================================================
	_uv_and_tint_section = VBoxContainer.new()
	_uv_and_tint_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(_uv_and_tint_section)

	var uv_title := Label.new()
	uv_title.text = "Face UV Tiling"
	_uv_and_tint_section.add_child(uv_title)

	# Quick Scale Row
	var quick_row := HBoxContainer.new()
	_btn_x2 = Button.new()
	_btn_x2.text = "x2"
	_btn_x2.tooltip_text = "Double tiling frequency (x2)"
	_btn_x2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_x2.pressed.connect(func(): _scale_tiling(2.0))
	quick_row.add_child(_btn_x2)

	_btn_half = Button.new()
	_btn_half.text = "/2"
	_btn_half.tooltip_text = "Half tiling frequency (/2)"
	_btn_half.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_half.pressed.connect(func(): _scale_tiling(0.5))
	quick_row.add_child(_btn_half)

	_btn_reset_uv = Button.new()
	_btn_reset_uv.text = "Reset (1m)"
	_btn_reset_uv.tooltip_text = "Reset tiling to default 1x1 meter pattern"
	_btn_reset_uv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_reset_uv.pressed.connect(_on_reset_uv_pressed)
	quick_row.add_child(_btn_reset_uv)
	_uv_and_tint_section.add_child(quick_row)

	# 45° Diagonal Button
	_btn_diagonal = Button.new()
	_btn_diagonal.text = "45° Diagonal Tiling (√2m)"
	_btn_diagonal.tooltip_text = "Scale texture to grid diagonal (1.414m) at 45° angle, cleanly aligned for triangulated quads"
	_btn_diagonal.pressed.connect(_on_diagonal_pressed)
	_uv_and_tint_section.add_child(_btn_diagonal)

	# Grid of Manual UV Controls
	var uv_grid := GridContainer.new()
	uv_grid.columns = 2
	uv_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	uv_grid.add_child(_make_label("Tiling U:"))
	_spin_tiling_u = _make_spinbox(0.01, 100.0, 0.01, 1.0)
	_spin_tiling_u.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_tiling_u)

	uv_grid.add_child(_make_label("Tiling V:"))
	_spin_tiling_v = _make_spinbox(0.01, 100.0, 0.01, 1.0)
	_spin_tiling_v.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_tiling_v)

	uv_grid.add_child(_make_label("Offset U:"))
	_spin_offset_u = _make_spinbox(-100.0, 100.0, 0.01, 0.0)
	_spin_offset_u.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_offset_u)

	uv_grid.add_child(_make_label("Offset V:"))
	_spin_offset_v = _make_spinbox(-100.0, 100.0, 0.01, 0.0)
	_spin_offset_v.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_offset_v)

	uv_grid.add_child(_make_label("Angle:"))
	_spin_angle = _make_spinbox(-360.0, 360.0, 1.0, 0.0, "°")
	_spin_angle.value_changed.connect(func(_v): _on_uv_property_changed())
	uv_grid.add_child(_spin_angle)

	_uv_and_tint_section.add_child(uv_grid)

	# Flips Row
	var flip_row := HBoxContainer.new()
	_chk_flip_u = CheckBox.new()
	_chk_flip_u.text = "Flip U"
	_chk_flip_u.toggled.connect(func(_b): _on_uv_property_changed())
	flip_row.add_child(_chk_flip_u)

	_chk_flip_v = CheckBox.new()
	_chk_flip_v.text = "Flip V"
	_chk_flip_v.toggled.connect(func(_b): _on_uv_property_changed())
	flip_row.add_child(_chk_flip_v)
	_uv_and_tint_section.add_child(flip_row)

	_uv_and_tint_section.add_child(HSeparator.new())

	# Face Tint Section
	var tint_title := Label.new()
	tint_title.text = "Face Tint"
	_uv_and_tint_section.add_child(tint_title)

	var tint_row := HBoxContainer.new()
	_color_picker = ColorPickerButton.new()
	_color_picker.text = "Color"
	_color_picker.color = Color.WHITE
	_color_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_color_picker.color_changed.connect(_on_tint_changed)
	tint_row.add_child(_color_picker)

	_btn_reset_tint = Button.new()
	_btn_reset_tint.text = "Reset"
	_btn_reset_tint.tooltip_text = "Reset face tint to white"
	_btn_reset_tint.pressed.connect(func():
		_color_picker.color = Color.WHITE
		_on_tint_changed(Color.WHITE)
	)
	tint_row.add_child(_btn_reset_tint)
	_uv_and_tint_section.add_child(tint_row)

	# =========================================================================
	# Section D: Sprite Tool Controls (Visible in SPRITE mode)
	# =========================================================================
	_sprite_tool_section = VBoxContainer.new()
	_sprite_tool_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sprite_tool_section.visible = false
	root_vbox.add_child(_sprite_tool_section)

	var sprite_header := Label.new()
	sprite_header.text = "Billboard Sprite Settings"
	_sprite_tool_section.add_child(sprite_header)

	# Active Sprite drop box / card
	_active_sprite_drop_box = MBSpriteDropBox.new()
	_active_sprite_drop_box.dock = self
	_active_sprite_drop_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_active_sprite_drop_box.custom_minimum_size = Vector2(0, 68)
	var db_style := StyleBoxFlat.new()
	db_style.bg_color = Color(0.12, 0.15, 0.20, 0.95)
	db_style.set_corner_radius_all(6)
	db_style.set_border_width_all(1)
	db_style.border_color = Color(0.2, 0.85, 1.0, 0.7)
	db_style.content_margin_left = 8
	db_style.content_margin_right = 8
	db_style.content_margin_top = 6
	db_style.content_margin_bottom = 6
	_active_sprite_drop_box.add_theme_stylebox_override("panel", db_style)

	var db_hbox := HBoxContainer.new()
	db_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	db_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_active_sprite_drop_box.add_child(db_hbox)

	_active_sprite_icon = TextureRect.new()
	_active_sprite_icon.custom_minimum_size = Vector2(56, 56)
	_active_sprite_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_active_sprite_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_active_sprite_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	db_hbox.add_child(_active_sprite_icon)

	var db_vbox := VBoxContainer.new()
	db_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	db_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	db_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	db_hbox.add_child(db_vbox)

	_active_sprite_label = Label.new()
	_active_sprite_label.text = "Active: (Click card below or drop image here)"
	_active_sprite_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.2))
	_active_sprite_label.add_theme_font_size_override("font_size", 12)
	_active_sprite_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	db_vbox.add_child(_active_sprite_label)

	var db_sub := Label.new()
	db_sub.text = "Drop image from FileSystem or click palette card"
	db_sub.add_theme_color_override("font_color", Color(0.65, 0.75, 0.85))
	db_sub.add_theme_font_size_override("font_size", 10)
	db_sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	db_vbox.add_child(db_sub)

	_sprite_tool_section.add_child(_active_sprite_drop_box)

	# Always-armed placement: the mode row arms the tool, the palette card is
	# the sprite. No "Place" button — the viewport click IS the placement.
	_sprite_hint = Label.new()
	_sprite_hint.text = "Placement (always armed with the selected sprite):\n" \
		+ "• Click a surface — places the selected sprite.\n" \
		+ "• Drag horizontally (or wheel) — opens the texture carousel; release confirms.\n" \
		+ "• Move the mouse up/down to raise, then click — then left/right to scale, click to finish.\n" \
		+ "• Esc cancels the current placement. Select the Material & UV tab to exit sprite mode."
	_sprite_hint.add_theme_color_override("font_color", Color(0.65, 0.75, 0.85))
	_sprite_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sprite_tool_section.add_child(_sprite_hint)
	root_vbox.add_child(HSeparator.new())

	# =========================================================================
	# Section E: Shape Placement Controls (Visible in SHAPE mode)
	# =========================================================================
	_shape_tool_section = VBoxContainer.new()
	_shape_tool_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shape_tool_section.visible = false
	root_vbox.add_child(_shape_tool_section)

	var shape_header := Label.new()
	shape_header.text = "Shape Palette"
	_shape_tool_section.add_child(shape_header)

	var shape_scroll := ScrollContainer.new()
	shape_scroll.custom_minimum_size = Vector2(0, 148)
	shape_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shape_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_shape_tool_section.add_child(shape_scroll)

	_shape_palette_grid = HFlowContainer.new()
	_shape_palette_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shape_palette_grid.add_theme_constant_override("h_separation", 4)
	_shape_palette_grid.add_theme_constant_override("v_separation", 4)
	shape_scroll.add_child(_shape_palette_grid)
	_populate_shape_palette()

	_shape_hint = Label.new()
	_shape_hint.text = "Placement (always armed with the selected shape):\n" \
		+ "• Drag on any surface to draw the shape's base, move to set its height, click to confirm.\n" \
		+ "• The selected shape stays armed — keep placing, or pick another card to switch.\n" \
		+ "• Esc cancels the current placement. Select the Material & UV tab to exit shape mode."
	_shape_hint.add_theme_color_override("font_color", Color(0.65, 0.75, 0.85))
	_shape_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_shape_tool_section.add_child(_shape_hint)
	root_vbox.add_child(HSeparator.new())

# ==============================================================================
# Mode Management
# ==============================================================================

## Public entry so the plugin (hotkeys, the old toolbar path) can drive the
## tab; emits dock_mode_changed through the same path as a click.
func set_dock_mode(new_mode: DockMode) -> void:
	_set_dock_mode(new_mode)

func _set_dock_mode(new_mode: DockMode) -> void:
	dock_mode = new_mode
	_btn_mode_mat.button_pressed = (dock_mode == DockMode.MATERIAL)
	_btn_mode_sprite.button_pressed = (dock_mode == DockMode.SPRITE)
	_btn_mode_shape.button_pressed = (dock_mode == DockMode.SHAPE)

	_uv_and_tint_section.visible = (dock_mode == DockMode.MATERIAL)
	_sprite_tool_section.visible = (dock_mode == DockMode.SPRITE)
	_shape_tool_section.visible = (dock_mode == DockMode.SHAPE)

	if dock_mode == DockMode.SPRITE and sprite_placer != null and sprite_placer.last_texture == null:
		_select_first_classified("sprite", _select_sprite_material)
	_rebuild_material_grid()
	_sync_shape_palette_selection()
	_update_tool_labels()
	sync_selection()
	dock_mode_changed.emit(new_mode)

func _update_tool_labels() -> void:
	if _active_sprite_label != null:
		if sprite_placer != null and sprite_placer.last_texture != null:
			var tex := sprite_placer.last_texture
			_active_sprite_label.text = "%s (%dx%d)" % [tex.resource_path.get_file(), tex.get_width(), tex.get_height()]
			if _active_sprite_icon != null:
				_active_sprite_icon.texture = tex
		else:
			_active_sprite_label.text = "Active: (Click card below or drop image here)"


# ==============================================================================
# Shape palette (SHAPE tab) — always-armed primitive placement
# ==============================================================================

## Every drag-creatable primitive EXCEPT sprite (the Sprite tab owns it) and
## ngon (the toolbar's N-Gon draw tool). Order follows MBShapeFactory.
static func shape_palette_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in MBShapeFactory.get_shape_ids():
		if id == &"sprite" or id == &"ngon":
			continue
		out.append(id)
	return out

func _populate_shape_palette() -> void:
	for child in _shape_palette_grid.get_children():
		child.queue_free()
	_shape_card_buttons.clear()
	var ids := shape_palette_ids()
	var idx := 0
	for shape_id in ids:
		var color := _shape_palette_color(idx, ids.size())
		idx += 1
		var card := Button.new()
		card.name = "Shape_%s" % String(shape_id).capitalize()
		card.custom_minimum_size = Vector2(64, 64)
		card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		card.clip_text = true
		card.text = String(shape_id).capitalize()
		card.tooltip_text = "%s — select, then drag on any surface to create" % String(shape_id).capitalize()
		var preview: Texture2D = _shape_preview_cache.get(shape_id)
		if preview != null:
			card.icon = preview
			card.expand_icon = true
			card.text = ""
		card.pressed.connect(func(): _select_shape(shape_id))
		_shape_palette_grid.add_child(card)
		_shape_card_buttons[shape_id] = card
	_sync_shape_palette_selection()

## Each shape gets its OWN bright, high-saturation color (golden-angle hue
## walk) so cards are distinguishable at a glance — the same color is used
## for the preview silhouette and the selected-card border.
static func _shape_palette_color(idx: int, count: int) -> Color:
	var hue := fmod(float(idx) * 0.618, 1.0)
	return Color.from_hsv(hue, 0.85, 1.0)

func _select_shape(shape_id: StringName) -> void:
	_selected_shape_id = shape_id
	_sync_shape_palette_selection()
	if plugin != null and plugin.has_method("_on_shape_palette_selected"):
		plugin._on_shape_palette_selected(shape_id)

func _sync_shape_palette_selection() -> void:
	var ids := shape_palette_ids()
	var idx := 0
	for shape_id in ids:
		var color := _shape_palette_color(idx, ids.size())
		idx += 1
		var card: Button = _shape_card_buttons.get(shape_id)
		if card == null:
			continue
		if shape_id == _selected_shape_id:
			var sel_style := StyleBoxFlat.new()
			sel_style.set_corner_radius_all(6)
			sel_style.set_border_width_all(2)
			sel_style.border_color = color
			sel_style.bg_color = Color(color.r, color.g, color.b, 0.25)
			card.add_theme_stylebox_override("normal", sel_style)
			var hover_style := sel_style.duplicate()
			hover_style.bg_color = Color(color.r, color.g, color.b, 0.4)
			card.add_theme_stylebox_override("hover", hover_style)
		else:
			if card.has_theme_stylebox_override("normal"):
				card.remove_theme_stylebox_override("normal")
				card.remove_theme_stylebox_override("hover")

## Kick off one-time preview rendering (editor session cache, shared across
## dock instances). Called deferred from _build_ui; harmless headless.
func _ensure_shape_previews() -> void:
	if not is_inside_tree() or not Engine.is_editor_hint():
		return
	var missing: Array[StringName] = []
	for shape_id in shape_palette_ids():
		if not _shape_preview_cache.has(shape_id):
			missing.append(shape_id)
	if missing.is_empty():
		_apply_shape_previews()
		return
	_render_shape_previews(missing)

## Renders each palette shape once into a small SubViewport as a flat
## silhouette in the card's unique bright color (transparent background, so
## the card style shows through).
func _render_shape_previews(shape_ids: Array[StringName]) -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(96, 96)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.own_world_3d = true
	add_child(vp)

	var world_root := Node3D.new()
	vp.add_child(world_root)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.current = true
	world_root.add_child(cam)
	var light := DirectionalLight3D.new()
	light.basis = Basis.looking_at(Vector3(-0.5, -0.8, -0.4).normalized(), Vector3.UP)
	world_root.add_child(light)

	var ids := shape_palette_ids()
	for shape_id in shape_ids:
		# Color index must match the card's index in the FULL palette order,
		# not the missing-subset order, or previews and card borders drift.
		var color := _shape_palette_color(ids.find(shape_id), ids.size())
		var data: MBMeshData = MBShapeFactory.create_shape(shape_id, Vector3.ONE)
		if data == null:
			continue
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = data.to_array_mesh()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.albedo_color = color
		mat.roughness = 0.6
		mesh_instance.material_override = mat
		world_root.add_child(mesh_instance)

		# Frame the shape: isometric-ish orbit, orthographic tight to the AABB.
		var aabb := mesh_instance.mesh.get_aabb()
		var center := aabb.get_center()
		var extent := maxf(0.001, aabb.get_longest_axis_size() * 0.72)
		var cam_pos := center + Vector3(1.0, 0.85, 1.0).normalized() * extent * 3.0
		cam.position = cam_pos
		cam.look_at(center, Vector3.UP)
		cam.size = extent * 2.0

		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		if img != null and not img.is_empty():
			var tex := ImageTexture.create_from_image(img)
			_shape_preview_cache[shape_id] = tex
		world_root.remove_child(mesh_instance)
		mesh_instance.queue_free()

	vp.queue_free()
	_apply_shape_previews()

func _apply_shape_previews() -> void:
	for shape_id in _shape_card_buttons:
		var card: Button = _shape_card_buttons[shape_id]
		var preview: Texture2D = _shape_preview_cache.get(shape_id)
		if card != null and preview != null:
			card.icon = preview
			card.expand_icon = true
			card.text = ""


func set_active_sprite_texture(tex: Texture2D) -> void:
	if tex == null:
		return
	if sprite_placer != null:
		sprite_placer.last_texture = tex
		sprite_placer.selected_texture = tex

	if _active_sprite_icon != null:
		_active_sprite_icon.texture = tex
	if _active_sprite_label != null:
		var fn := tex.resource_path.get_file()
		_active_sprite_label.text = "%s (%dx%d)" % [fn, tex.get_width(), tex.get_height()]

	var dims := MBSpritePlacer.compute_texture_dimensions(tex, 1.5)
	if sprite_placer != null:
		sprite_placer.base_width = dims.x
		sprite_placer.base_height = dims.y


	_rebuild_material_grid()
	if plugin != null and plugin.logger != null:
		plugin.logger.info("sprite", "Selected billboard sprite texture: %s" % tex.resource_path.get_file())

func _select_sprite_material(mat: Material) -> void:
	if mat == null:
		return
	var tex := _extract_texture(mat)
	if tex != null:
		set_active_sprite_texture(tex)

func _select_first_classified(category: String, select_fn: Callable) -> void:
	if _project_materials.is_empty():
		return
	for mat in _project_materials:
		if not mat.has_meta("source_texture_path"):
			continue
		if MBAssetCatalog.classify_path(mat.get_meta("source_texture_path")) == category:
			select_fn.call(mat)
			return
	select_fn.call(_project_materials[0])
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
		# Pickers must not cross-populate: billboard sprites are categorized
		# (MBAssetCatalog) and the Sprite tab sees only them. MATERIAL and SHAPE
		# share ONE palette — real materials plus plain paint textures.
		if dock_mode == DockMode.SPRITE:
			if not mat.has_meta("source_texture_path"):
				continue
			var cat: String = MBAssetCatalog.classify_path(mat.get_meta("source_texture_path"))
			if cat != "sprite":
				continue
		elif dock_mode == DockMode.MATERIAL or dock_mode == DockMode.SHAPE:
			if mat.has_meta("source_texture_path") \
					and MBAssetCatalog.classify_path(mat.get_meta("source_texture_path")) != "texture":
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

	var tooltip := mat_name
	match dock_mode:
		DockMode.MATERIAL, DockMode.SHAPE:
			tooltip += "\nLeft-click: Apply to selected face(s)\nRight-click: Set as default"
		DockMode.SPRITE:
			tooltip += "\nLeft-click: Select as active billboard sprite"

	var tex := _extract_texture(mat)
	if tex != null:
		btn.icon = tex
		btn.expand_icon = true
	elif mat is StandardMaterial3D:
		btn.text = mat_name
		btn.modulate = mat.albedo_color
	else:
		btn.text = mat_name

	# Left-click routing based on active dock mode
	btn.pressed.connect(func():
		match dock_mode:
			DockMode.MATERIAL, DockMode.SHAPE:
				_apply_material_to_selection(mat)
			DockMode.SPRITE:
				_select_sprite_material(mat)
	)
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
	# Active selection badge for Sprite mode
	var is_active_sprite := (dock_mode == DockMode.SPRITE and sprite_placer != null and tex != null and sprite_placer.last_texture == tex)
	if is_active_sprite:
		var spbadge := Label.new()
		spbadge.text = "🌲"
		spbadge.position = Vector2(48, 2)
		btn.add_child(spbadge)
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
	_context_menu.add_item("Set as Sprite Texture", 4)
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
		4:
			_select_sprite_material(_context_material)
			_set_dock_mode(DockMode.SPRITE)

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
	var has_selection: bool = false
	var first_face: MBFace = null

	if mesh != null and mesh.mb_mesh_data != null and editor != null and editor.selection != null:
		var sel_faces: PackedInt32Array = editor.selection.selected_faces
		if not sel_faces.is_empty():
			has_selection = true
			var fi: int = sel_faces[0]
			if fi >= 0 and fi < mesh.mb_mesh_data.faces.size():
				first_face = mesh.mb_mesh_data.faces[fi]
			_status_label.text = "%d face(s) selected on %s" % [sel_faces.size(), mesh.name]
		elif editor.tool_mode == MBEditor.SelectMode.OBJECT:
			has_selection = true
			_status_label.text = "Object %s selected (materials apply to all faces)" % mesh.name
		else:
			_status_label.text = "No faces selected on %s" % mesh.name
	else:
		_status_label.text = "No MBMesh selected"

	# Enable / disable UV controls
	_btn_x2.disabled = not has_selection
	_btn_half.disabled = not has_selection
	_btn_reset_uv.disabled = not has_selection
	_btn_diagonal.disabled = not has_selection
	_set_slider_enabled(_spin_tiling_u, has_selection)
	_set_slider_enabled(_spin_tiling_v, has_selection)
	_set_slider_enabled(_spin_offset_u, has_selection)
	_set_slider_enabled(_spin_offset_v, has_selection)
	_set_slider_enabled(_spin_angle, has_selection)
	_chk_flip_u.disabled = not has_selection
	_chk_flip_v.disabled = not has_selection
	_color_picker.disabled = not has_selection
	_btn_reset_tint.disabled = not has_selection

	if first_face != null:
		_spin_tiling_u.value = first_face.uv_scale.x
		_spin_tiling_v.value = first_face.uv_scale.y
		_spin_offset_u.value = first_face.uv_offset.x
		_spin_offset_v.value = first_face.uv_offset.y
		_spin_angle.value = first_face.uv_rotation
		_chk_flip_u.button_pressed = first_face.uv_flip_u
		_chk_flip_v.button_pressed = first_face.uv_flip_v

		# Read vertex color tint if available
		var data: MBMeshData = mesh.mb_mesh_data
		var idxs := first_face.get_distinct_indexes()
		if not idxs.is_empty() and idxs[0] < data.colors.size():
			_color_picker.color = data.colors[idxs[0]]
		else:
			_color_picker.color = Color.WHITE

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

func _scale_tiling(factor: float) -> void:
	var mesh: MBMesh = editor.active_mesh if editor != null else null
	if mesh == null or mesh.mb_mesh_data == null:
		return
	var sel_faces := _get_target_faces(mesh)
	if sel_faces.is_empty():
		return

	var before := MBCommand.copy_mesh_data(mesh.mb_mesh_data)
	for face in sel_faces:
		MBUv.scale_face_tiling(face, factor)
	MBUv.refresh_mesh_uvs(mesh.mb_mesh_data)
	var after := MBCommand.copy_mesh_data(mesh.mb_mesh_data)

	_commit_mesh_action(mesh, "Scale Face Tiling", before, after)
	sync_selection()

func _on_reset_uv_pressed() -> void:
	var mesh: MBMesh = editor.active_mesh if editor != null else null
	if mesh == null or mesh.mb_mesh_data == null:
		return
	var sel_faces := _get_target_faces(mesh)
	if sel_faces.is_empty():
		return

	var before := MBCommand.copy_mesh_data(mesh.mb_mesh_data)
	for face in sel_faces:
		face.uv_scale = Vector2.ONE
		face.uv_offset = Vector2.ZERO
		face.uv_rotation = 0.0
		face.uv_flip_u = false
		face.uv_flip_v = false
	MBUv.refresh_mesh_uvs(mesh.mb_mesh_data)
	var after := MBCommand.copy_mesh_data(mesh.mb_mesh_data)

	_commit_mesh_action(mesh, "Reset Face UVs", before, after)
	sync_selection()

func _on_diagonal_pressed() -> void:
	var mesh: MBMesh = editor.active_mesh if editor != null else null
	if mesh == null or mesh.mb_mesh_data == null:
		return
	var sel_faces := _get_target_faces(mesh)
	if sel_faces.is_empty():
		return

	var before := MBCommand.copy_mesh_data(mesh.mb_mesh_data)
	for face in sel_faces:
		MBUv.set_face_45_degree_diagonal(face)
	MBUv.refresh_mesh_uvs(mesh.mb_mesh_data)
	var after := MBCommand.copy_mesh_data(mesh.mb_mesh_data)

	_commit_mesh_action(mesh, "45° Diagonal UV Tiling", before, after)
	sync_selection()


func _on_uv_property_changed() -> void:
	if _syncing:
		return
	var mesh: MBMesh = editor.active_mesh if editor != null else null
	if mesh == null or mesh.mb_mesh_data == null:
		return
	var sel_faces := _get_target_faces(mesh)
	if sel_faces.is_empty():
		return

	var before := MBCommand.copy_mesh_data(mesh.mb_mesh_data)

	for face in sel_faces:
		face.uv_scale = Vector2(_spin_tiling_u.value, _spin_tiling_v.value)
		face.uv_offset = Vector2(_spin_offset_u.value, _spin_offset_v.value)
		face.uv_rotation = _spin_angle.value
		face.uv_flip_u = _chk_flip_u.button_pressed
		face.uv_flip_v = _chk_flip_v.button_pressed

	MBUv.refresh_mesh_uvs(mesh.mb_mesh_data)
	var after := MBCommand.copy_mesh_data(mesh.mb_mesh_data)
	_commit_mesh_action(mesh, "Change Face UVs", before, after)

func _on_tint_changed(color: Color) -> void:
	if _syncing:
		return
	var mesh: MBMesh = editor.active_mesh if editor != null else null
	if mesh == null or mesh.mb_mesh_data == null:
		return
	var sel_faces := _get_target_faces(mesh)
	if sel_faces.is_empty():
		return

	var before := MBCommand.copy_mesh_data(mesh.mb_mesh_data)

	var data := mesh.mb_mesh_data
	var vc := data.positions.size()
	if data.colors.size() != vc:
		data.colors.resize(vc)
		data.colors.fill(Color.WHITE)

	for face in sel_faces:
		for idx in face.get_distinct_indexes():
			if idx >= 0 and idx < vc:
				data.colors[idx] = color

	var after := MBCommand.copy_mesh_data(mesh.mb_mesh_data)
	_commit_mesh_action(mesh, "Change Face Tint", before, after)
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

func _make_spinbox(min_val: float, max_val: float, step_val: float, default_val: float, suffix_str: String = "") -> Range:
	if Engine.is_editor_hint() and ClassDB.can_instantiate("EditorSpinSlider"):
		var s := EditorSpinSlider.new()
		s.min_value = min_val
		s.max_value = max_val
		s.step = step_val
		s.value = default_val
		if not suffix_str.is_empty():
			s.suffix = suffix_str
		s.flat = false
		s.hide_slider = true
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		return s
	else:
		var sb := SpinBox.new()
		sb.min_value = min_val
		sb.max_value = max_val
		sb.step = step_val
		sb.value = default_val
		if not suffix_str.is_empty():
			sb.suffix = suffix_str
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		return sb

func _set_slider_enabled(slider: Range, enabled: bool) -> void:
	if slider == null:
		return
	if slider is SpinBox:
		(slider as SpinBox).editable = enabled
	elif slider is EditorSpinSlider:
		(slider as EditorSpinSlider).read_only = not enabled

class MBSpriteDropBox extends PanelContainer:
	var dock: MBMaterialDock = null

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		if typeof(data) == TYPE_DICTIONARY:
			var dict: Dictionary = data
			if dict.get("type", "") == "files":
				var files: Array = dict.get("files", [])
				for f in files:
					var ext := str(f).get_extension().to_lower()
					if ext in ["png", "jpg", "jpeg", "webp", "tres", "material"]:
						return true
		return false

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		if typeof(data) == TYPE_DICTIONARY and dock != null:
			var dict: Dictionary = data
			if dict.get("type", "") == "files":
				var files: Array = dict.get("files", [])
				for f in files:
					var path_str := str(f)
					var ext := path_str.get_extension().to_lower()
					if ext in ["png", "jpg", "jpeg", "webp"]:
						if ResourceLoader.exists(path_str):
							var tex = ResourceLoader.load(path_str)
							if tex is Texture2D:
								dock.set_active_sprite_texture(tex)
								return
					elif ext in ["tres", "material"]:
						if ResourceLoader.exists(path_str):
							var mat = ResourceLoader.load(path_str)
							if mat is Material:
								dock._select_sprite_material(mat)
								return
