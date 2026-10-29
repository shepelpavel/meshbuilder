# MeshBuilder — prop modeling inside Godot

MeshBuilder turns the editor's 3D viewport into a modeling tool: drag-to-create primitives,
vertex/edge/face editing, mesh operations, a UV editor and a project material palette. No Blender,
no export/import round-trip, no leaving the editor.

The plugin is a fork of **PoiBuilder** (MIT) stripped down to prop modeling: texture splatting and face
painting, PBM export and the retro pipeline, particle emitters, animated UV scrolling, billboard
sprites, time-of-day presets and the bundled offline documentation are gone.

- **Godot:** 4.7 or newer
- **Language:** pure GDScript — no GDExtension, no C#/.NET, no native binaries
- **License:** MIT (see `LICENSE`)

---

## Install

1. Copy the `addons/meshbuilder` folder into your project.
2. `Project → Project Settings → Plugins` → enable **MeshBuilder**.
3. Three tabs appear in the editor's bottom panel: **MeshBuilder** (toolbar), **Materials** (palette)
   and **UV Editor**.

Shortcuts are registered under `Editor Settings → Shortcuts → meshbuilder/…` and rebind like any other.
Defaults that clash with Godot's own keys are unbound by the plugin on first run (reported in Output).

## Interface

The toolbar is three rows of icon groups (groups are separated by vertical lines):

| Row | Contents |
|---|---|
| 1 | modes (Object / Vertex / Edge / Face / Texture), Move / Rotate / Scale, gizmo Space, selection operations, Auto Smooth |
| 2 | V-Snap, Soft (proportional editing) and its radius, grid + snapping, Lit / Shadow / X-Ray, mesh operations (Extrude, Inset, Bevel, Subdiv, Merge, Del, Knife, Loop Cut, Connect, Bridge, Collapse, Fill Hole, Weld, Detach) |
| 3 | New Shape, N-Gon, Edit Params, object operations (Merge Objects, Mirror, Center Pivot, Freeze Xform, MeshBuilderize), Merge by Dist, CSG (Union / Subtract / Intersect), Trim Walls, panel buttons |

Panels are separate bottom tabs: the toolbar opens on start, `Materials` and `UV Editor` are opened from
the third row.

## Creating geometry

**13 primitives:** cube, stair, curved stair, prism, cylinder, plane, door, pipe, cone, arch, sphere,
torus, n-gon — plus **Trim Walls** for skirting and mouldings along walls.

- **New Shape** → pick a shape → drag the base on any surface → move the mouse to set the height →
  click to confirm. `Ctrl` locks the direction, `Esc` cancels.
- Size-only shapes (cube, prism, plane) commit on release; the rest open a parameter modal.
  **Edit Params** reopens it later — until the geometry is edited by hand.
- N-Gon is drawn point by point.
- Surface-aligned sheets (plane) are lifted off the surface by the normal offset.

## Modes and selection

`1` / `2` / `3` switch vertex / edge / face mode (`6` — texture); `H` / `J` / `K` are the same modes
without leaving the left hand on the number row. Switching modes converts the selection.

- click selects one element, rubber band selects a group, `Shift` adds, `Ctrl` removes;
- **edges:** `Alt+click` or double-click selects the edge loop, `Shift+Alt+click` the edge ring;
- `Ctrl+I` inverts, `Alt+G` / `Alt+Shift+G` grow/shrink, `Alt+C` selects coplanar faces, the **Similar**
  and **Boundary** buttons cover coplanar look-alikes and open borders;
- **V-Snap** snaps to the nearest vertex, **Soft** enables proportional editing with a radius;
- **X-Ray** (`Alt+Z`) makes the mesh translucent so back faces are visible and pickable. With X-Ray
  **off**, hidden elements are not pickable: clicks and marquee take only what you can see.

## Mesh operations

| Operation | Key | What it does |
|---|---|---|
| Extrude | `E` | extrudes selected faces/edges |
| Inset | `I` | insets a face inside the selected one |
| Bevel | `B` | chamfers edges, faces or vertices (Distance + Segments modal) |
| Subdivide | `D` | splits faces |
| Loop Cut | `Ctrl+R` | inserts an edge loop through a quad ring |
| Knife | button | cuts a face along clicked points; a closed loop inside a face cuts a hole |
| Merge Faces | button | merges selected faces into one |
| Merge (Weld) | `M` | merges selected vertices into their centroid |
| **Merge by Dist** | button | merges every vertex closer than 1 mm across the whole mesh (Blender's Merge by Distance) |
| Bridge / Connect / Collapse | `Shift+B` / button / button | bridge edges, add a connecting edge, collapse the selection |
| Fill Hole | button | closes a hole along its border |
| Detach | button | moves selected faces into a new object |
| Delete | `X` | mode-aware delete: faces, edges (merging the neighbours) or vertices |

**Bevel:** Distance is in metres, clamped to 49 % of the shortest incident edge; Segments 1–8 round the
fillet. A vertex bevel has no segments — it is a single flat cut, so its slider is hidden. A face with a
cut-out (after a closed knife cut) is split into triangles before beveling, otherwise its edges cannot be
beveled at all.

## Object operations and CSG

- **Merge Objects** welds selected `MBMesh` nodes, **Mirror** mirrors across X, **Center Pivot** moves the
  pivot to the centre, **Freeze Transform** bakes the transform into the geometry.
- **MeshBuilderize** converts a `MeshInstance3D` or a `CSG` node into an editable `MBMesh`.
- **CSG Union / Subtract / Intersect** run Godot's CSG kernel on the selection.
- **Lit / Shadow** toggle shading and shadow casting on the selected objects.

## Materials

The **Materials** tab is the project palette: cards for materials and textures scanned from `res://`,
`+ Add` for a file from disk, `↺` to rescan.

- click a card — apply the material to the selected faces (in Object mode — to the whole model);
- right click — **Set as Default** (material for new shapes, marked ★), **Apply to Selection**,
  **Copy Path**;
- dragging a card onto an object in the viewport assigns it as well.

## UV editor

The `UV Editor` tab has **UV1** (texture) and **UV2** (lightmap) channels, Auto/Manual modes,
Move/Rotate/Scale tools (`W` / `E` / `R`; `F` frames the selection) and grid snapping with a selectable step.

- Projections: **Planar**, **Box**, **Fit** into [0,1], **Unwrap** into a clean non-overlapping layout,
  **Lightmap** — a UV2 atlas unwrap for `LightmapGI`.
- Editing: **Flip U/V**, ±90° rotations, **Sew** / **Split** / **Collapse** / **Stitch**.
- **Texel density:** `Get` samples the density of the selected face, `Set` applies a target (px/m).
- **Export PNG** saves the UV template; **↗ Window** pops the editor out into its own window.
- The **Face:** row edits per-face values without touching the unwrap: `×2`, `÷2`, `Reset (1m)`, `45°`,
  Tiling U/V, Offset U/V, Angle, Flip U/V and **Tint** (vertex colour of the selected faces, `White`
  clears it). Values follow the first selected face and every change is a single undo step.

## Grid and snapping

The plugin draws its own grid over the scene: `Y` toggles snapping, `=` / `-` make the division finer or
coarser, `Ctrl+=` / `Ctrl+-` scale the cell, `[` / `]` raise or lower the grid plane, `\` resets its
height. Snapping applies to new shapes and to dragging elements alike.

## Keyboard reference

| Key | Action |
|---|---|
| `1` `2` `3` `6` | vertex / edge / face / texture mode |
| `H` `J` `K` | the same modes (alternative) |
| `G` `R` `S` | Move / Rotate / Scale |
| `Shift+X` | cycle gizmo space |
| `E` `I` `B` `D` | Extrude / Inset / Bevel / Subdivide |
| `Ctrl+R` | Loop Cut |
| `Shift+B` | Bridge Edges |
| `M` | Merge (weld selected vertices) |
| `X` | delete by mode |
| `Ctrl+I` | invert selection |
| `Alt+G` / `Alt+Shift+G` | grow / shrink selection |
| `Alt+C` | select coplanar |
| `Alt+L` / `Alt+R` | face loop / face ring |
| `Alt+Z` | X-Ray |
| `Y` | toggle snapping |
| `=` / `-`, `Ctrl+=` / `Ctrl+-` | grid division, cell size |
| `[` `]` `\` | grid elevation, reset |

Every binding is rebindable in the editor settings; clashes with Godot's own keys are cleared on first
run.

## Undo and saving

Every operation is one `UndoRedo` action (`Ctrl+Z` / `Ctrl+Shift+Z`). Geometry lives in the scene as an
`MBMesh` node (a `MeshInstance3D` built from mesh data), so saving the scene saves the model.

**There is no file export:** the GLB exporter shared its dialog and module with the PBM format and the
retro pipeline, so the channel was dropped instead of carving two formats out of three. Need a file? The
generated `ArrayMesh` can be saved from the node inspector.

## Limitations and notes

- Only `MBMesh` nodes are editable; a plain `MeshInstance3D`/`CSG` has to go through **MeshBuilderize**.
- **Merge by Dist** welds vertices closer than 1 mm and drops faces that collapse to a line.
- **Beveling the rim of a hole** is refused while the hole has no walls (the edge borders a single face) —
  cut it through the solid or extrude it inward first.
- A vertex bevel is a flat cut (no segments); vertices on an open border are skipped with a message in
  the viewport's top banner.
- An operation with nothing to do (empty selection, Object mode, zero distance) reports the reason in the
  viewport's top banner for a few seconds.
- The vertex-colour **Tint** shows only in materials that use vertex colour as albedo.

## Checking changes

The plugin is verified with headless editor runs and `--check-only` over the scripts; visual acceptance is
a normal Godot run with the scene open.
