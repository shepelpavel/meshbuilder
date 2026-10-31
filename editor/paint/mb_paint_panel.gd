## MBPaintPanel — vertex-colour painting tools for MeshBuilder.
##
## A brush that paints the corner colours of the active MBMesh in the 3D
## viewport, plus the operations that do not need aiming: fill the selected
## faces, fill the whole mesh, reset to white, and an eyedropper. The colours
## live in MBMeshData.colors and are uploaded as ARRAY_COLOR, so they show up
## wherever the material uses vertex colour as albedo.
@tool
class_name MBPaintPanel
extends VBoxContainer

signal brush_toggled(active: bool)
signal request_fill_selected(color: Color)
signal request_fill_all(color: Color)
signal request_reset(color: Color)
signal eyedropper_toggled(active: bool)
signal request_mode(mode: int)

## Saved palette lives in EditorSettings, so custom colours survive restarts and
## are shared across projects opened by this editor.
const PALETTE_SETTING := "meshbuilder/paint/palette"

const DEFAULT_PALETTE: Array[Color] = [
	Color(1.0, 1.0, 1.0), Color(0.86, 0.86, 0.88), Color(0.45, 0.47, 0.5), Color(0.08, 0.08, 0.09),
	Color(0.78, 0.22, 0.18), Color(0.95, 0.55, 0.15), Color(0.96, 0.86, 0.3), Color(0.35, 0.65, 0.28),
	Color(0.2, 0.55, 0.75), Color(0.3, 0.35, 0.7), Color(0.6, 0.35, 0.65), Color(0.55, 0.4, 0.28),
]

## Element mode shortcuts shown as icons: value is MBEditor.SelectMode.
const MODES: Array = [["Object", 0, "icon_object.svg"], ["Vertex", 1, "icon_vertex.svg"],
	["Edge", 2, "icon_edge.svg"], ["Face", 3, "icon_face.svg"]]

var brush_active: bool = false
## Eyedropper is a MODE: arm it, click a vertex in the viewport, the colour is
## picked and the mode drops back to the brush.
var eyedropper_active: bool = false
var brush_color: Color = Color(0.78, 0.22, 0.18)
var brush_radius: float = 0.6
var brush_strength: float = 1.0
## How far the paint bleeds past the element you clicked (0 = not at all, the
## face/edge/vertex under the cursor is the only thing that changes).
var brush_spread: float = 0.0

var _brush_button: Button
var _color_button: ColorPickerButton
var _radius_box: SpinBox
var _strength_box: SpinBox
var _spread_box: SpinBox
var palette_colors: Array[Color] = []
var _palette_bar: HBoxContainer
var _palette_buttons: Array[Button] = []
var _mode_buttons: Array[Button] = []
var _eyedropper_button: Button

func _ready() -> void:
	add_theme_constant_override("separation", 6)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 6)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	column.add_child(top)

	# Element modes as icons, exactly like the modelling tab: no label, the
	# highlight tells you which one is armed.
	_mode_buttons = []
	for entry in MODES:
		var mode_btn := Button.new()
		mode_btn.name = "PaintMode%s" % String(entry[0])
		mode_btn.toggle_mode = true
		mode_btn.flat = true
		mode_btn.custom_minimum_size = Vector2(26, 24)
		mode_btn.icon = _load_icon(String(entry[2]))
		mode_btn.tooltip_text = String(entry[0])
		var mode_value: int = int(entry[1])
		mode_btn.pressed.connect(func() -> void: request_mode.emit(mode_value))
		top.add_child(mode_btn)
		_mode_buttons.append(mode_btn)
	# Divider between "which element" and "the brush itself".
	var mode_sep := VSeparator.new()
	mode_sep.name = "PaintModeSeparator"
	top.add_child(mode_sep)

	# Icon toggle: the pressed state is the only cue that the brush owns the
	# mouse in the viewport, so it is a normal toggle button with an icon and a
	# tint that lights up while it is on.
	_brush_button = Button.new()
	_brush_button.name = "PaintBrushToggle"
	_brush_button.toggle_mode = true
	_brush_button.flat = true
	_brush_button.custom_minimum_size = Vector2(28, 26)
	_brush_button.icon = _load_icon("icon_brush.svg")
	_brush_button.tooltip_text = "Brush: paint vertex colours in the 3D viewport (left drag, Alt = erase)"
	_brush_button.toggled.connect(_on_brush_toggled)
	top.add_child(_brush_button)
	_update_brush_look()

	_color_button = ColorPickerButton.new()
	_color_button.name = "PaintColor"
	_color_button.custom_minimum_size = Vector2(64, 26)
	_color_button.color = brush_color
	_color_button.tooltip_text = "Brush colour"
	_color_button.color_changed.connect(_on_color_changed)
	top.add_child(_color_button)

	_radius_box = _make_spin("PaintRadius", "Radius (m)", 0.02, 5.0, 0.01, brush_radius, top)
	_strength_box = _make_spin("PaintStrength", "Strength", 0.05, 1.0, 0.05, brush_strength, top)
	_spread_box = _make_spin("PaintSpread", "Spread", 0.0, 1.0, 0.05, brush_spread, top)

	var actions := top
	_add_action(actions, "PaintFillSelected", "icon_fill_selected.svg",
		"Fill the selected faces with the current colour", func() -> void: request_fill_selected.emit(brush_color))
	_add_action(actions, "PaintFillAll", "icon_fill_all.svg",
		"Fill the whole mesh with the current colour", func() -> void: request_fill_all.emit(brush_color))
	_add_action(actions, "PaintReset", "icon_paint_reset.svg",
		"Reset every vertex colour to white", func() -> void: request_reset.emit(Color.WHITE))
	_eyedropper_button = _add_action(actions, "PaintEyedropper", "icon_eyedropper.svg",
		"Eyedropper: arm it, then click a vertex in the viewport to take its colour",
		func() -> void: _on_eyedropper_pressed())
	_eyedropper_button.toggle_mode = true

	_palette_bar = HBoxContainer.new()
	_palette_bar.add_theme_constant_override("separation", 4)
	column.add_child(_palette_bar)
	_load_palette()
	_rebuild_palette()

## Reads the palette from EditorSettings (falling back to the default swatches).
func _load_palette() -> void:
	palette_colors = []
	var settings := EditorInterface.get_editor_settings()
	if settings != null and settings.has_setting(PALETTE_SETTING):
		var saved = settings.get_setting(PALETTE_SETTING)
		if saved is PackedColorArray:
			for c in (saved as PackedColorArray):
				palette_colors.append(c)
		elif saved is Array:
			for c in saved:
				if c is Color:
					palette_colors.append(c)
	if palette_colors.is_empty():
		for c in DEFAULT_PALETTE:
			palette_colors.append(c)

func _save_palette() -> void:
	var settings := EditorInterface.get_editor_settings()
	if settings == null:
		return
	var packed := PackedColorArray()
	for c in palette_colors:
		packed.append(c)
	settings.set_setting(PALETTE_SETTING, packed)

## Rebuilds the swatch row: one button per colour plus the "+" that stores the
## current brush colour. Right-click a swatch to edit or delete it.
func _rebuild_palette() -> void:
	if _palette_bar == null:
		return
	for child in _palette_bar.get_children():
		_palette_bar.remove_child(child)
		child.queue_free()
	_palette_buttons.clear()
	for i in palette_colors.size():
		var swatch := _make_swatch(i, palette_colors[i])
		_palette_bar.add_child(swatch)
		_palette_buttons.append(swatch)
	var add_btn := Button.new()
	add_btn.name = "PaintPaletteAdd"
	add_btn.text = "+"
	add_btn.tooltip_text = "Add the current brush colour to the palette"
	add_btn.custom_minimum_size = Vector2(24, 22)
	add_btn.pressed.connect(_on_palette_add)
	_palette_bar.add_child(add_btn)

func _make_swatch(index: int, color: Color) -> Button:
	var swatch := Button.new()
	swatch.name = "PaintSwatch%d" % index
	swatch.custom_minimum_size = Vector2(26, 22)
	swatch.tooltip_text = "Click: use this colour. Right-click: edit or delete."
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(3)
	swatch.add_theme_stylebox_override("normal", style)
	swatch.add_theme_stylebox_override("hover", style)
	swatch.add_theme_stylebox_override("pressed", style)
	swatch.pressed.connect(func() -> void: _set_color(color))
	swatch.gui_input.connect(func(event: InputEvent) -> void: _on_swatch_input(event, index))
	return swatch

func _on_swatch_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT:
		_open_swatch_menu(index, (event as InputEventMouseButton).global_position)
		get_viewport().set_input_as_handled()

## Right-click menu for a swatch: edit (colour picker) or delete.
func _open_swatch_menu(index: int, screen_pos: Vector2) -> void:
	var menu := PopupMenu.new()
	add_child(menu)
	menu.add_item("Edit colour…", 0)
	menu.add_item("Delete", 1)
	menu.id_pressed.connect(func(id: int) -> void:
		match id:
			0:
				_edit_swatch(index)
			1:
				_delete_swatch(index)
		menu.queue_free()
	)
	menu.popup(Rect2i(Vector2i(screen_pos), Vector2i.ZERO))

func _on_palette_add() -> void:
	palette_colors.append(brush_color)
	_save_palette()
	_rebuild_palette()

func _delete_swatch(index: int) -> void:
	if index < 0 or index >= palette_colors.size():
		return
	palette_colors.remove_at(index)
	_save_palette()
	_rebuild_palette()

## Colour picker dialog for an existing swatch.
func _edit_swatch(index: int) -> void:
	if index < 0 or index >= palette_colors.size():
		return
	var dialog := AcceptDialog.new()
	dialog.title = "Palette colour"
	dialog.ok_button_text = "OK"
	add_child(dialog)
	var picker := ColorPicker.new()
	picker.color = palette_colors[index]
	picker.edit_alpha = false
	picker.custom_minimum_size = Vector2(300, 260)
	dialog.add_child(picker)
	dialog.confirmed.connect(func() -> void:
		if index < palette_colors.size():
			palette_colors[index] = picker.color
			_save_palette()
			_rebuild_palette()
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	dialog.popup_centered()

## Numeric input with a small caption on the left — same shape as the radius
## field, so the row reads as data rather than as sliders you have to guess.
func _make_spin(id: String, caption: String, min_v: float, max_v: float, step_v: float,
		value: float, parent: Control) -> SpinBox:
	var label := Label.new()
	label.text = caption
	label.add_theme_font_size_override("font_size", 11)
	label.tooltip_text = caption
	parent.add_child(label)
	var box := SpinBox.new()
	box.name = id
	box.min_value = min_v
	box.max_value = max_v
	box.step = step_v
	box.value = value
	box.custom_minimum_size = Vector2(74, 0)
	parent.add_child(box)
	box.value_changed.connect(func(v: float) -> void: _on_spin_changed(id, v))
	return box

func _add_action(parent: Control, id: String, icon_name: String, tip: String, handler: Callable) -> Button:
	var btn := Button.new()
	btn.name = id
	btn.flat = true
	btn.custom_minimum_size = Vector2(28, 26)
	btn.icon = _load_icon(icon_name)
	btn.tooltip_text = tip
	btn.pressed.connect(handler)
	parent.add_child(btn)
	return btn

func _on_spin_changed(id: String, value: float) -> void:
	match id:
		"PaintRadius": brush_radius = value
		"PaintStrength": brush_strength = value
		"PaintSpread": brush_spread = value

func _set_color(color: Color) -> void:
	brush_color = color
	if _color_button != null:
		_color_button.color = color

func _on_color_changed(color: Color) -> void:
	brush_color = color

func _on_brush_toggled(active: bool) -> void:
	brush_active = active
	_update_brush_look()
	brush_toggled.emit(active)

## What the viewport brush should paint: Alt turns the stroke into an eraser.
func paint_color_for_erase(erase: bool) -> Color:
	return Color.WHITE if erase else brush_color

func sync_from_selection(editor: MBEditor) -> void:
	if editor == null:
		return
	# Fill Selected is a plain "apply to the current selection" button: it never
	# switches element modes itself and stays greyed out until faces are picked.
	var has_faces: bool = editor.selection != null and editor.selection.selected_face_count() > 0
	var fill_btn := find_child("PaintFillSelected", true, false) as Button
	if fill_btn != null:
		fill_btn.disabled = not has_faces

func _load_icon(icon_name: String) -> Texture2D:
	var path := "res://addons/meshbuilder/icons/" + icon_name
	return load(path) if ResourceLoader.exists(path) else null

## Reflects the brush state on the button: pressed + warm tint while it is on.
func _update_brush_look() -> void:
	if _brush_button == null:
		return
	_brush_button.button_pressed = brush_active
	_brush_button.self_modulate = Color(1.0, 0.74, 0.35) if brush_active else Color(1, 1, 1)

func _notification(what: int) -> void:
	# Switching to another bottom-panel tab hides the panel: the brush must let go
	# of the mouse, or the viewport keeps painting after the tool is out of sight.
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		if brush_active:
			brush_active = false
			_update_brush_look()
			brush_toggled.emit(false)
		if eyedropper_active:
			set_eyedropper(false)

func force_brush_off() -> void:
	if brush_active:
		brush_active = false
		_update_brush_look()
		brush_toggled.emit(false)

## Highlights the element mode the editor is actually in (the buttons are a
## shortcut, the truth lives in MBEditor).
func sync_mode(mode: int) -> void:
	for i in _mode_buttons.size():
		_mode_buttons[i].button_pressed = i == mode

## Eyedropper is one-click: picking a colour ends the mode (like any eyedropper
## in a paint app), so the next click paints instead of picking again.
func _on_eyedropper_pressed() -> void:
	set_eyedropper(not eyedropper_active)

func set_eyedropper(active: bool) -> void:
	eyedropper_active = active
	if active and brush_active:
		brush_active = false
		_update_brush_look()
		brush_toggled.emit(false)
	if _eyedropper_button != null:
		_eyedropper_button.button_pressed = active
		_eyedropper_button.self_modulate = Color(1.0, 0.74, 0.35) if active else Color(1, 1, 1)
	eyedropper_toggled.emit(active)

func force_eyedropper_off() -> void:
	if eyedropper_active:
		set_eyedropper(false)

## Called by the plugin after a successful pick: the colour goes into the brush
## and the mode turns itself off.
func take_picked_color(color: Color) -> void:
	_set_color(color)
	set_eyedropper(false)
