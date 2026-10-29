# MeshBuilder

In-editor 3D modeling for Godot: shape primitives, vertex/edge/face editing, mesh operations,
UV editor, CSG booleans. Fork of [PoiBuilder](https://github.com/Francesco149/poibuilder) (MIT),
trimmed down to prop modeling.

Full manual: [English](docs/README.en.md) · [по-русски](docs/README.ru.md).
Русское краткое описание — ниже, раздел «По-русски».

## English

**What it is.** A Godot editor plugin that turns the 3D viewport into a modeling tool. Draw a
primitive, drag its vertices, extrude a face, unwrap it, assign a material — without leaving the
editor and without round-tripping through Blender. It is a fork of PoiBuilder stripped of everything
unrelated to prop modeling: texture splatting and face painting, PBM export and the retro/PSP
pipeline, particle emitters, animated UV scrolling and the bundled offline documentation are gone.

### Features

**Shape creation.** 13 primitives — cube, stairs, curved stairs, prism, cylinder, plane, door, pipe,
cone, arch, sphere, torus, n-gon. Drag the base on any surface or on the grid, move the mouse
to set the height, click to confirm. Shape parameters stay re-editable until you start editing the
geometry by hand.

**Mesh editing.** Object / Vertex / Edge / Face modes with marquee selection and selection conversion
between modes. Operations: extrude, inset, multi-segment bevel, loop cut, knife, subdivide, merge,
weld, bridge, connect, tunnel, fill hole, detach, delete. Everything with live previews and full
undo.

**Materials and UV.** Per-mesh material palette (each mesh keeps its own list) with per-face assignment and a default material for
new shapes. A dedicated 2D UV editor with UV1 and UV2 channels, box unwrap, LightmapGI unwrap,
island selection and snapping — plus a per-face row (tiling, offset, rotation, flips, vertex-colour
tint).

**Extras.** CSG booleans (union / subtract / intersect), `MeshBuilderize` to turn a `MeshInstance3D`
or a CSG node into an editable mesh, a snapping grid.

### Requirements

Godot 4.7 or newer. Pure GDScript — no GDExtension, no C#/.NET build, no native binaries.

### Install

Copy the `addons/meshbuilder` folder into your project and enable **MeshBuilder** in
`Project → Project Settings → Plugins`.

The UI lives in the editor's **bottom panel** as three tabs — *MeshBuilder* (toolbar),
*Materials* (material palette of the selected mesh) and *UV Editor* (2D unwrapping and per-face UV/tint) — so the
plugin takes neither rows from the 3D viewport nor the right-hand dock column.

### No file export

The modern GLB exporter shared its dialog and its module with the PBM format and the retro pipeline,
so the whole export channel was dropped instead of carving two formats out of three. Meshes live in
the scene as `MBMesh` nodes (a `MeshInstance3D` whose geometry is built in `_ready`, collision
included). Need a file? The generated `ArrayMesh` can be saved from the inspector as a `.tres`.

### License

MIT — see `LICENSE`. The original PoiBuilder copyright is kept next to the fork's. Internal names are
renamed for MeshBuilder (`mb_*` files, `MB*` classes); when porting a fix from upstream remember the
same code is called `pb_*` / `PB*` there.

## По-русски

Полное руководство: [docs/README.ru.md](docs/README.ru.md) (English: [docs/README.en.md](docs/README.en.md)).

Редактор геометрии внутри редактора Godot: примитивы drag-to-create, правка вершин/рёбер/граней,
операции меша, UV-редактор, булевы через CSG.

Форк PoiBuilder (MIT, © 2026 headpats), урезанный под моделинг пропов: убраны сплаты и роспись по
граням, экспорт PBM и ретро-пайплайн, партиклы, анимированный UV-скролл и офлайн-документация.

### Что умеет

**Создание геометрии.** 13 примитивов (куб, лестница, винтовая лестница, призма, цилиндр, плоскость,
дверь, труба, конус, арка, сфера, тор, n-угольник) с рисованием по любой поверхности или по
сетке: тянем основание, двигаем мышь для высоты, клик — готово. Параметры шейпа остаются
редактируемыми, пока геометрию не начали править руками.

**Правка меша.** Режимы Object / Vertex / Edge / Face, выделение рамкой, с конвертацией между
режимами. Операции: extrude, inset, bevel (мультисегментный), loop cut, нож, subdivide, merge, weld,
bridge, connect, tunnel, fill hole, detach, delete. Всё с превью и полноценным undo.

**Материалы и UV.** Палитра материалов меша (у каждого свой список) с назначением на грани и материалом по умолчанию для
новых фигур. Отдельный 2D UV-редактор: каналы UV1 и UV2, box-unwrap, развёртка для LightmapGI,
острова, снап — плюс строка «Face:» для граней (тайлинг, офсет, угол, флипы, тинт вершинным цветом).

**Прочее.** CSG-булевы (union / subtract / intersect), `MeshBuilderize` — превратить `MeshInstance3D`
или CSG в редактируемый меш, сетка с привязками.

### Требования

Godot 4.7 или новее. Чистый GDScript, без GDExtension, C# и нативных бинарников.

### Установка

Плагин вендорится в проект игры: репозиторий плагина — источник правды, в `addons/` игры лежит снимок.

Правки делаются здесь, потом снимок обновляется в проекте:

```
rsync -a --delete \
  --exclude '.git*' --exclude '.editorconfig' --exclude 'README.md' \
  ~/Projects/meshbuilder/ ~/Projects/<проект>/addons/meshbuilder/
```

`--delete` обязателен: без него удалённые в плагине файлы останутся в игре.

Включить в `Проект → Настройки проекта → Плагины → MeshBuilder`.

Всё живёт в **нижней панели** отдельными вкладками — «MeshBuilder» (тулбар), «Material & UV»
(палитра материалов выделенного меша) и «UV Editor» (2D-развёртка и построчная правка UV/тинта): так плагин не отъедает ни строки у
3D-вьюпорта, ни правую колонку доков.

### Экспорта в файл нет

Современный GLB жил в том же диалоге и том же модуле, что PBM и ретро-пайплайн, поэтому канал
выгрузки убран целиком. Меши живут в сцене нодами `MBMesh` (`MeshInstance3D`, геометрия собирается в
`_ready`, коллизия генерируется там же). Нужен файл — собранный `ArrayMesh` сохраняется из инспектора
(`Save as .tres`).

### Лицензия

MIT — см. `LICENSE`: оригинальный копирайт PoiBuilder сохранён, добавлен копирайт форка. Внутренние
имена переименованы под MeshBuilder (`mb_*` файлы, `MB*` классы) — при переносе фиксов из апстрима
учитывать, что там те же места называются `pb_*` / `PB*`.
