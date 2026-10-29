## MBApplyPrep — Prepares a material the moment it is APPLIED to faces.
##
## One property travels with the FACE, not the palette card, and an ordinary
## "apply material" used to destroy it:
##
## Texture transparency: MBAlphaDetect gives the incoming material the same
## alpha handling its pixels need before it lands (see that class).
##
## Pure statics: the plugin's apply path and the tests share one definition.
@tool
class_name MBApplyPrep
extends RefCounted

## Returns the material to actually assign to the faces: `incoming` prepared
## with detected transparency. Returns `incoming` itself when nothing needs
## changing; any mutated variant is a detached duplicate, so shared resources
## (saved .tres, palette wrappers) are never rewritten.
static func prepare(incoming: Material, previous: Material) -> Material:
	if incoming == null:
		return null
	return MBAlphaDetect.ensure_transparency(incoming)
