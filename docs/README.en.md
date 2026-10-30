# MeshBuilder — prop modeling inside Godot

MeshBuilder turns the editor's 3D viewport into a modeling tool: drag-to-create primitives,
vertex/edge/face editing, mesh operations, a UV editor and a per-mesh material palette. No Blender,
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
| 2 | V-Snap, Soft (proportional editing) and its radius, Lit / Shadow / X-Ray, mesh operations (Extrude, Inset, Bevel, Subdiv, Merge, Del, Knife, Loop Cut, Connect, Bridge, Tunnel, Fill Hole, Weld, Detach) |
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

`1` / `2` / `3` switch vertex / edge / face mode (`4` — object, `6` — texture); `H` / `J` are the same modes
without leaving the left hand on the number row (`K` is the knife). Switching modes converts the selection.
While the camera is flying (RMB or the wheel held) the plugin's shortcuts stay out of the way and the
keys go to the editor.

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
| Subdivide | `D` | face mode — cut a quad into 4; edge mode — split the selected edges at their midpoints (the faces around them become n-gons) |
| Loop Cut | `Ctrl+R` | inserts an edge loop through a quad ring |
| Knife | `K` | cuts a face along clicked points; it arms from object mode too (the first click picks the face, pressing `K` again cancels), `Enter` completes the cut; a closed loop inside a face cuts a hole. The magnet scales with the face (14 % for corners, 20 % for edges) so it grips the same on a 0.2 m prop and a 20 m wall; holding **Alt** turns it off so the point sits exactly under the cursor. An open cut extends itself to the face border — click two points inside the face and the cut still runs edge to edge. A stroke that runs across several visible faces cuts **all** of them in one go, so a wall built from separate quads is cut by a single line (it does not cut through the solid — the back wall stays, and a seam keeps a single vertex) |
| Merge Faces | button | merges selected faces into one |
| Merge (Weld) | `M` | merges selected vertices into their centroid |
| **Merge by Dist** | button | merges every vertex closer than 1 mm across the whole mesh (Blender's Merge by Distance) |
| Bridge / Connect | `Shift+B` / button | bridge two edges, add a connecting edge |
| **Tunnel** | button | a tunnel between two selected faces (see below) |
| Fill Hole | button | in vertex mode — a face from the selected vertices (3+); otherwise closes the mesh's open borders |
| Detach | button | moves selected faces into a new object |
| Delete | `X` | mode-aware delete: faces, edges (merging the neighbours) or vertices |

**Tunnel:** select two faces in face mode (two opposite sides of a box, say) and hit **Tunnel** — both faces
are removed and their loops are bridged with walls, so the hole runs straight through the solid. The
openings keep the faces' shapes (both need the same corner count: 4 and 4, 3 and 3) and the walls face
into the bore. Neighbouring faces (sharing an edge) are refused — a tunnel goes between different sides
of the solid.

**Bevel:** Distance is in metres, clamped to 49 % of the shortest incident edge; Segments 1–8 round the
fillet. A vertex bevel has no segments — it is a single flat cut, so its slider is hidden. A face with a
cut-out (after a closed knife cut) is split into triangles before beveling, otherwise its edges cannot be
beveled at all.

## Object operations and CSG

- **Mirror Model** — a live mirror (Blender's Mirror modifier): model one half and the render builds the
  reflection across the object's origin; the stored geometry never changes, the reflected half is display
  only. Click toggles it, **Shift+click** switches the axis X / Y / Z. One undo step.
- **Apply Mirror** — bakes the reflection into real geometry: the half stays editable and the copy becomes
  ordinary faces (the modifier switches off). Every press re-bakes — the previous reflection is deleted
  and rebuilt from the current half, so copies never stack.
- **Merge Objects** welds selected `MBMesh` nodes, **Mirror** bakes a mirrored copy of the geometry across X, **Center Pivot** moves the
  pivot to the centre, **Freeze Transform** bakes the transform into the geometry.
- **MeshBuilderize** converts a `MeshInstance3D` or a `CSG` node into an editable `MBMesh`.
- **CSG Union / Subtract / Intersect** run Godot's CSG kernel on the selection: select two `MBMesh`
  nodes (first — target, second — cutter) **in object mode** (`4`) and hit the button. The result stays on
  the target, the cutter leaves the scene, all one undo step. Meshes must be closed (an open border is
  refused as non-manifold), 256 materials per operand max. In vertex/edge/face mode the selection is
  deliberately narrowed to one mesh, so multi-select is unavailable there.
- **Lit / Shadow** toggle shading and shadow casting on the selected objects.

## Materials

The **Materials** tab is the palette of the **selected mesh**. Its cards are that mesh's own materials
(its `materials` slots): every mesh keeps its own set, the project is not scanned and nothing is pulled
in automatically.

- `+ Add` — add a material to the current mesh: `.tres` / `.material` is taken as is, a texture
  (`.png` / `.jpg` / `.webp`) is wrapped into a `StandardMaterial3D` with transparency read from the
  image. Adding is a single undo step; the same file is never added twice (the status line says so);
- click a card — apply the material to the selected faces (in Object mode — to every face of the mesh);
- right click — **Apply to Selection**, **Remove from Mesh** (drops the material's slot from the mesh;
  faces on it fall back to the first slot, all in one undo step), **Copy Path**;
- `↺` — re-read the material list from the mesh (the palette also switches on its own when another mesh
  is selected);
- dragging a card onto an object in the viewport assigns it as well.

New shapes start with the default material (`materials/mb_default_material.tres`) as their first slot;
after that each mesh carries its own set.

## UV editor

The `UV Editor` tab has **UV1** (texture) and **UV2** (lightmap) channels, Auto/Manual modes,
Move/Rotate/Scale tools (`W` / `E` / `R`; `F` frames the selection) and snapping to the Godot grid.

- Projections: **Planar**, **Box**, **Fit** into [0,1], **Unwrap** into a clean non-overlapping layout,
  **Lightmap** — a UV2 atlas unwrap for `LightmapGI`.
- Editing: **Flip U/V**, ±90° rotations, **Sew** / **Split** / **Collapse** / **Stitch**.
- **Texel density:** `Get` samples the density of the selected face, `Set` applies a target (px/m).
- **Export PNG** saves the UV template; **↗ Window** pops the editor out into its own window.
- The **Face:** row edits per-face values without touching the unwrap: `×2`, `÷2`, `Reset (1m)`, `45°`,
  Tiling U/V, Offset U/V, Angle, Flip U/V and **Tint** (vertex colour of the selected faces, `White`
  clears it). Values follow the first selected face and every change is a single undo step.

## Grid and snapping

Snapping follows the **Godot grid**: the step comes from the editor's Snap Settings dialog (1 m cell when
that is unavailable). The plugin no longer draws a grid of its own — you see the editor's grid. `Y` or the toolbar **Snap** button toggles it.
applies to new shapes and to dragging elements alike.

## Keyboard reference

| Key | Action |
|---|---|
| `1` `2` `3` `6` | vertex / edge / face / texture mode |
| `4` | object mode (multi-select; CSG and Merge Objects work from here) |
| `H` `J` | the same modes (alternative) |
| `K` | knife tool (press again to cancel) |
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
