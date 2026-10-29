## MBAssetCatalog — Classifies image assets into sprites / materials so the
## pickers don't cross-populate.
##
## Classification for an image path, in priority order:
##   1. Parent folder name:  .../sprites/  .../textures/
##   2. File-name prefix:    sprite_ billboard_ tree_ bush_ grass_   -> sprite
##   3. Shipped default names that predate prefixes (tree_oak, bush_foliage …).
##   4. Everything else -> texture (the material bucket).
##
## Users add their own assets by dropping files into a matching folder
## (res://materials/sprites/, res://materials/textures/) or by using the
## prefixes — the addon's own folder is never touched.
@tool
class_name MBAssetCatalog

const SPRITE_FOLDER_NAMES := ["sprites", "sprite"]

const SPRITE_PREFIXES := ["sprite_", "billboard_", "tree_", "bush_", "grass_"]

## Shipped textures that predate the prefix convention.
const DEFAULT_SPRITE_NAMES := ["tree_oak", "tree_pine", "bush_foliage", "grass_tuft"]

## Returns one of "sprite", "texture".
static func classify_path(path: String) -> String:
	var lower := path.to_lower()
	var parent := lower.get_base_dir().get_file()
	if parent in SPRITE_FOLDER_NAMES:
		return "sprite"
	var name := lower.get_file()
	for p in SPRITE_PREFIXES:
		if name.begins_with(p):
			return "sprite"
	for n in DEFAULT_SPRITE_NAMES:
		if name.begins_with(n):
			return "sprite"
	return "texture"

static func is_sprite(path: String) -> bool:
	return classify_path(path) == "sprite"

## Textures usable for materials: everything that is not a billboard sprite.
static func is_texture(path: String) -> bool:
	return not is_sprite(path)
