# Prop Curve Finder

A Garry's Mod tool for measuring a surface, as a console command or a weapon. Click a screen, a wall or a prop, and it tells you:
- what you hit;
- where it is, in the world and in the prop's own coordinates;
- what shape it is (flat, curved or domed): its radius, axis, centre, arc and which way it curves;
- how big it is;
- how to lay flat `cam.Start3D2D` panels along it.

It can also put a test Star Trek Modules LCARS interface on it, to check the curve.

Look at a surface and run `propcurvefinder` in the console (bind it to a key: `bind f6 propcurvefinder`), or use the **Prop Curve Finder** weapon (spawn menu, Weapons, Prop Curve Finder). It doesn't depend on any gamemode, and it works in singleplayer and on servers.

## Installing

Put the repository in `garrysmod/addons/` so the path is `garrysmod/addons/propcurvefinder/lua/...`. Then change map or restart.
- **Lowercase folder name:** on a Linux server, GMod requires addon folder names to be all lowercase, so name it `propcurvefinder`, not `PropCurveFinder`. Clone it with `git clone https://github.com/Fluffer-oss/PropCurveFinder propcurvefinder`.
- **Downloaded as a zip:** make sure you don't end up with a folder inside a folder (`addons/PropCurveFinder-main/PropCurveFinder-main/lua`).
- **Check it's loaded:** the console prints `[PropCurveFinder] loaded (server)` and `[PropCurveFinder] loaded (client)`.
- **Client-only use:** the console command needs only the client part, so it also works when you're just a player on a server that has the addon. The test interface needs the server part.

## Using it

| Console | Weapon | |
|---|---|---|
| `propcurvefinder` | Primary fire | Probe the surface you're looking at. |
| `propcurvefinder_clear` | Secondary fire | Clear the probe, and your test interface. |
| `propcurvefinder_show` | Reload | Show the last result again. |
| `propcurvefinder_materials` | | List the materials of the prop you're looking at. |
| `propcurvefinder_staticprop` | | Print (and copy) the static prop you're looking at: model, index, skin, position, angles and bounding box. |
| `propcurvefinder_material <path>` | | Measure that material on props, e.g. `propcurvefinder_material models/kingpommes/startrek/intrepid/lcars/lcars_bridge_mission_middle`. Empty (`propcurvefinder_material ""`) measures the material you're looking at. |

### Props: measured from the model itself

A trace against a prop hits its collision model, a simplified shape that can sit in front of what you see. A console's collision model is often a sheet in front of its screens. So on props and static props, the tool reads the model's own files instead:
- `.mdl`: its materials and meshes;
- `.vvd`: its vertices and normals;
- `.dx90.vtx`: its triangles.

Then it measures with the real triangles:
1. Your aim is cast against the triangles, to find exactly which surface and material you're looking at, even behind glass.
2. It takes that material (or the one named in `propcurvefinder_material`), only the piece connected to where you aimed.
3. The curve is fitted to every corner of that piece with its own normals, so the radius, arc, width, height and edges are the material's exactly.

**Materials in separate pieces.** A material can come in several separate pieces, like a lower console panel split into three screens. Triangles are in the same piece only when they share an edge, so pieces with a gap between them, or touching at just a corner, are separate. Slivers under 1% of the biggest piece are ignored. Then:
- each piece is measured on its own;
- the export has a `Pieces = { ... }` list, left to right as you looked at them, with `Aimed` saying which one you aimed at;
- each piece has its shape, size, `Screen` position and angles, `Curve` (the exact surface: radius, angle and height ranges, center and axes, in the world and the prop's own coordinates) and segments;
- **Make STM test interfaces** places one separate interface on each piece. Presses say which interface, row and column.

The result says `Material = "..."` when it was measured this way, and the piece's triangles are drawn in light blue. If the model's files can't be read, or it doesn't use the material you named, it falls back to walking the surface with traces and says why.

A probe:
1. **Finds what you hit.**
   - An entity or prop: its class, model, position and angles.
   - A static prop: static props aren't entities, so a trace only says it hit the world. The tool reads the map's static prop list (model, position, angles) and each model's box to find which one. It reads the files only.
   - A world brush: its texture.
2. **Walks along the surface** (world brushes; props are measured from the model, see below) from where you clicked, to the right, left, up and down, until it reaches an edge. An edge is any of:
   - the surface ends;
   - a different object;
   - a bend sharper than the limit (30° by default);
   - on world brushes, a different texture, so a screen texture stops at its frame.

   The walk follows curves, re-tracing onto the surface at each step.
3. **Fits the shape** from every point and surface normal it found:
   - **flat**;
   - **cylinder:** a curved screen or a pillar. The axis is the direction all the normals are perpendicular to, and the centre is where they meet;
   - **sphere:** a dome.

   It also says whether the surface is **concave** (curving round towards you, like a wraparound screen) or convex, and how well the shape fits (rms error).
4. **Lays out flat pieces** along it (8 by default), each sized and angled for `cam.Start3D2D`:
   - on a concave surface, the pieces are the chords of the curve, so they sit just in front of it everywhere;
   - on a convex one, they're tangent to it, so they never sink in;
   - with no lift, neighbouring pieces meet edge to edge.

The result is drawn in the world:
- yellow: the sampled points;
- red: where each direction stopped;
- magenta: the axis;
- green: the pieces.

It's also shown in a window as a Lua table you can copy, and printed to the console:

```lua
-- PropCurveFinder
{
    Target = { Type = "static_prop", Model = "models/.../console.mdl", StaticPropIndex = 412, Pos = Vector(...), Ang = Angle(...) },
    Hit = { Pos = { World = Vector(...), Local = Vector(...) }, Normal = { World = ..., Local = ... } },
    Shape = "cylinder", -- fit error 0.004 units (rms)
    Radius = 100.000,
    Concave = true, -- curves towards you
    Center = { World = ..., Local = ... },
    Axis = { World = ..., Local = ... },
    ArcDegrees = 80.000,
    Width = 139.626, -- along the surface
    Height = 40.000,
    Screen = { Pos = ..., Ang = ... }, -- the middle of the surface, facing out
    Edges = { Left = "ran off the surface", Right = ..., Up = ..., Down = ... },
    Segments = { { Pos = ..., TopLeft = ..., Ang = ..., Width = 17.4, Height = 40 }, ... },
}
```

`Local` values are in the prop's own space (for props, static props and entities), so they stay right if the prop moves. Draw a piece with `cam.Start3D2D(TopLeft, Ang, 1 / pixelsPerUnit)`: x runs across the piece and y down it.

### Settings (console variables, saved)

- `propcurvefinder_step 2`: distance between samples on the walk. Smaller is more precise on tight curves.
- `propcurvefinder_maxdistance 512`: how far to walk in each direction.
- `propcurvefinder_maxbend 30`: a sharper bend than this (degrees) is an edge.
- `propcurvefinder_segments 8`: how many flat pieces a curved surface is split into.
- `propcurvefinder_lift 0.25`: how far in front of the surface the pieces sit, so they don't flicker into it.
- `propcurvefinder_texturestop 1`: on world brushes, stop at a texture change.
- `propcurvefinder_material ""`: on props, the material to measure (empty: the one you're looking at).

## STM test interface

**Make STM test interface** in the result window puts one Star Trek Modules LCARS interface over the whole surface, wrapped round the curve:
- it's a single STM `button_matrix` window, as wide as the surface (along the curve) and as tall, full of test buttons (`R2 C3` is row 2, column 3);
- pressing one beeps and tells you in chat which row and column you pressed.

If the window sits flush on the screen from edge to edge, and every press registers on the button you aimed at (including at the far left and right of a curve), the curve is right.

How it's drawn on a curve, without changing STM:
- STM windows are flat. Each one draws its picture into a render target, then puts that on a flat panel.
- For this interface, that render target is drawn round the measured curve instead, in 48 thin strips, so each part of the window sits on the surface.
- Where your aim meets the curve (exactly, not via a flat approximation) becomes the window's mouse position. Hover and presses land where things are drawn, through STM's own `Get3D2DMousePos`, `PreventRender` and `PreventButton` hooks.
- Presses are sent to STM's server like any other LCARS press, within STM's usual reach of 80 units.

Where it lives:
- STM interfaces belong to an entity, so it's held by an invisible anchor entity. If you probed a prop or entity, the anchor is parented to it, so it moves with it.
- It sits `propcurvefinder_lift` (0.25 units) in front of the surface.
- Every client gets the curve, late joiners included.
- It stays open until you clear it (`propcurvefinder_clear` or the weapon's secondary fire), place another, or leave.

Only admins can place one, unless the server sets `propcurvefinder_interface_adminonly 0`.

## Tests

`tests/` runs the real addon files in a mock Garry's Mod:
- **Angles:** Source's angle conventions, including `AngleEx`, `WorldToLocal` and `LocalToWorld`.
- **Surfaces:** a scene of exact surfaces to trace against: a wraparound screen, a pillar, a dome, a turned static prop panel, an entity, texture and bend edges.
- **Files:** real binary map and model files.

They check, against the true geometry:
- the shape, radius, axis, arc, width and height;
- that every piece sits on or in front of the surface and faces you, in order left to right;
- the 3D2D angle conventions;
- static prop and entity local coordinates;
- props measured from real binary model files (`.mdl`, `.vvd` with fixups, `.vtx`): a curved console screen behind a collision sheet of glass, measured exactly, by the material you look at or name;
- a material in three separate pieces (and a sliver): each measured, ordered left to right, exported (valid Lua that reads back) and given its own interface; panels touching only at a corner kept apart;
- the static prop command;
- the STM interface: one window over the whole curve at the right size and place, its buttons, the curve sent to every client (late joiners too), admin-only, replacing and clearing;
- drawing it round the curve (every corner on the curve showing the right part of the window) and mapping your aim to the exact pixel for hover and presses, through STM's hooks;
- the console commands and the weapon.

```
lua5.1 tests/run.lua
```

It can't prove the real engine behaves exactly like the mock, so check it in-game too.
