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

A probe:
1. **Finds what you hit.**
   - An entity or prop: its class, model, position and angles.
   - A static prop: static props aren't entities, so a trace only says it hit the world. The tool reads the map's static prop list (model, position, angles) and each model's box to find which one. It reads the files only.
   - A world brush: its texture.
2. **Walks along the surface** from where you clicked, to the right, left, up and down, until it reaches an edge. An edge is any of:
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

## STM test interface

**Make STM test interface** in the result window puts a Star Trek Modules LCARS interface on the surface:
- one window on each piece, each full of numbered test buttons (`S3 B2` is piece 3, button 2);
- pressing one beeps and tells you in chat which piece and button you pressed.

If the windows sit flush on the screen and every press registers on the button you aimed at, the curve is right.

How it works:
- STM interfaces belong to an entity, so it's held by an invisible anchor entity. If you probed a prop or entity, the anchor is parented to it, so it moves with it.
- It's a normal STM interface class (`propcurvefinder_test`, built on STM's `base`).
- Its windows are STM `button_list` windows. Their scale is raised if needed so a small screen still fits STM's frame.
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
- the STM interface: windows on their pieces at the right size, button presses, admin-only, replacing and clearing;
- the console commands and the weapon.

```
lua5.1 tests/run.lua
```

It can't prove the real engine behaves exactly like the mock, so check it in-game too.
