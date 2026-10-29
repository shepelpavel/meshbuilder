## MBXray — полупрозрачный просмотр меша (без изменения данных).
##
## Материалы не мутируются: на время режима на ноду ставятся поверхностные
## оверрайды — копии её материалов с прозрачностью и выключенным отсечением
## задних граней. Выключение возвращает исходные оверрайды (обычно пустые),
## поэтому сейв сцены в этом режиме ничего не портит.
@tool
class_name MBXray
extends RefCounted

const ALPHA := 0.35

const META := "mb_xray_state"

static func is_active(node: GeometryInstance3D) -> bool:
	return node != null and is_instance_valid(node) and node.has_meta(META)

## Turns the node translucent. Returns true when the mode is now active.
static func enable(node: GeometryInstance3D) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if node.has_meta(META):
		return true
	var csg := node as CSGPrimitive3D
	if csg != null:
		var base: Material = csg.material
		var dup := _transparent_copy(base)
		if dup == null:
			return false
		node.set_meta(META, {"csg": base})
		csg.material = dup
		return true
	var mi := node as MeshInstance3D
	if mi == null or mi.mesh == null:
		return false
	var originals := {}
	var changed := false
	for s in range(mi.mesh.get_surface_count()):
		var cur := mi.get_surface_override_material(s)
		originals[s] = cur
		var source: Material = cur
		if source == null:
			source = mi.mesh.surface_get_material(s)
		var dup := _transparent_copy(source)
		if dup == null:
			continue
		mi.set_surface_override_material(s, dup)
		changed = true
	if not changed:
		return false
	node.set_meta(META, {"surfaces": originals})
	return true

## Restores what enable() replaced. Safe to call when the mode is off.
static func disable(node: GeometryInstance3D) -> void:
	if not is_active(node):
		return
	var state: Dictionary = node.get_meta(META)
	var csg := node as CSGPrimitive3D
	if csg != null:
		csg.material = state.get("csg")
		node.remove_meta(META)
		return
	var mi := node as MeshInstance3D
	if mi != null and state.has("surfaces"):
		var originals: Dictionary = state["surfaces"]
		for s in originals.keys():
			mi.set_surface_override_material(int(s), originals[s])
	node.remove_meta(META)

static func _transparent_copy(base: Material) -> StandardMaterial3D:
	if not (base is StandardMaterial3D):
		return null
	var dup := (base as StandardMaterial3D).duplicate() as StandardMaterial3D
	if dup == null:
		return null
	dup.resource_path = ""
	dup.resource_local_to_scene = false
	dup.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dup.albedo_color = Color(dup.albedo_color.r, dup.albedo_color.g, dup.albedo_color.b, ALPHA)
	dup.cull_mode = BaseMaterial3D.CULL_DISABLED
	dup.disable_receive_shadows = true
	return dup
