PropCurveFinder = PropCurveFinder or {}
local PCF = PropCurveFinder
local Curve = PCF.Curve

-- STM draws each window flat, from a render target. For the test interface,
-- that render target is drawn wrapped round the measured surface instead, in
-- thin strips, and your aim is mapped onto the curve, so hovering and
-- pressing land exactly where things are drawn. STM's own drawing and button
-- handling are switched off for these interfaces through its hooks.

-- anchor entity index -> curve, in the anchor's coordinates.
PCF.Curved = PCF.Curved or {}
local STRIPS = 48
local REACH = 80 -- how close you have to be to press, like STM

net.Receive("PropCurveFinder.Curved", function()
    local anchor = net.ReadEntity()
    local curve = Curve.Read()
    if IsValid(anchor) then PCF.Curved[anchor:EntIndex()] = curve end
end)

hook.Add("InitPostEntity", "PropCurveFinder.CurvedSync", function()
    net.Start("PropCurveFinder.CurvedSync")
    net.SendToServer()
end)

-- The curve of an STM interface, in the world now (the anchor may move).
local function WorldCurve(interface)
    local ent = interface and interface.Ent
    if not IsValid(ent) then return nil end
    local curve = PCF.Curved[ent:EntIndex()]
    return curve and Curve.ToWorld(curve, ent:GetPos(), ent:GetAngles())
end
PCF.WorldCurve = WorldCurve

local function AimRay()
    local lcars = Star_Trek and Star_Trek.LCARS
    local origin = lcars and lcars.EyePos or LocalPlayer():EyePos()
    return origin, gui.ScreenToVector(input.GetCursorPos())
end

-- A window's pixel under your aim, or nil.
function PCF.CurvedPixel(window, curve, origin, dir)
    local u, v, distance = Curve.Hit(curve, origin, dir)
    if not u then return nil end
    return Vector(u * window.WWidth, v * window.WHeight, 0), distance
end

-- STM asks where the mouse is on a window: on ours, where your aim meets the curve.
hook.Add("Star_Trek.LCARS.Get3D2DMousePos", "PropCurveFinder.Curved", function(window)
    local curve = WorldCurve(window.Interface)
    if not curve then return end
    local origin, dir = AimRay()
    return (PCF.CurvedPixel(window, curve, origin, dir)) or Vector(-1, -1, 0)
end)

-- STM draws nothing for ours (it still updates them: that call passes true).
hook.Add("Star_Trek.LCARS.PreventRender", "PropCurveFinder.Curved", function(interface, updating)
    if not updating and WorldCurve(interface) then return true end
end)

-- STM's button handling skips ours; ours is below.
hook.Add("Star_Trek.LCARS.PreventButton", "PropCurveFinder.Curved", function(interface)
    if WorldCurve(interface) then return true end
end)

-- Presses on our interfaces: where your aim meets the curve.
function PCF.CurvedButtonDown(ply, button)
    local lcars = Star_Trek and Star_Trek.LCARS
    if not (lcars and lcars.ActiveInterfaces) then return end
    if not ((button == KEY_E and not ply.DisableEButton) or button == MOUSE_LEFT or button == MOUSE_RIGHT) then return end
    if not ply:Alive() then return end

    local origin, dir = AimRay()
    for id, interface in pairs(lcars.ActiveInterfaces) do
        local curve = WorldCurve(interface)
        local window = interface.Windows and interface.Windows[1]
        if curve and window and interface.IVis and not (interface.Closing and interface.AnimPos ~= 1) then
            local pixel, distance = PCF.CurvedPixel(window, curve, origin, dir)
            if pixel and distance <= REACH then
                local buttonId = window:OnPress(pixel, interface.AnimPos)
                if buttonId then
                    net.Start("Star_Trek.LCARS.Pressed")
                    net.WriteInt(id, 32)
                    net.WriteInt(1, 32)
                    net.WriteInt(buttonId, 32)
                    net.SendToServer()
                end
            end
        end
    end
end

-- STM calls Star_Trek.LCARS:PlayerButtonDown from both its hook and (in
-- singleplayer) a net message, so ours runs right after it either way.
local function Wrap()
    local lcars = Star_Trek and Star_Trek.LCARS
    if not lcars or not lcars.PlayerButtonDown or lcars.PropCurveFinderWrapped then return end
    lcars.PropCurveFinderWrapped = true
    local original = lcars.PlayerButtonDown
    function lcars:PlayerButtonDown(ply, button)
        original(self, ply, button)
        PCF.CurvedButtonDown(ply, button)
    end
end
hook.Add("InitPostEntity", "PropCurveFinder.WrapLCARS", Wrap)
hook.Add("Think", "PropCurveFinder.WrapLCARS", function()
    Wrap()
    if Star_Trek and Star_Trek.LCARS and Star_Trek.LCARS.PropCurveFinderWrapped then
        hook.Remove("Think", "PropCurveFinder.WrapLCARS")
    end
end)

-- The window's render target as a material that can be drawn on any mesh,
-- from both sides, blended like STM blends it.
local materials = {}
local function WindowMaterial(window, additive)
    local key = window.RT:GetName() .. (additive and "+" or "")
    if not materials[key] then
        materials[key] = CreateMaterial("propcurvefinder_" .. key, "UnlitGeneric", {
            ["$basetexture"] = window.RT:GetName(),
            ["$nocull"] = 1,
            ["$vertexalpha"] = 1,
            ["$vertexcolor"] = 1,
            ["$translucent"] = additive and 0 or 1,
            ["$additive"] = additive and 1 or 0
        })
    end
    return materials[key]
end

-- The surface as quads (corners and texture coordinates), left to right.
function PCF.CurvedQuads(curve)
    local quads = {}
    local count = curve.flat and 1 or STRIPS
    for i = 1, count do
        local u0, u1 = (i - 1) / count, i / count
        quads[i] = {
            { pos = (Curve.Point(curve, u0, 0)), u = u0, v = 0 },
            { pos = (Curve.Point(curve, u1, 0)), u = u1, v = 0 },
            { pos = (Curve.Point(curve, u1, 1)), u = u1, v = 1 },
            { pos = (Curve.Point(curve, u0, 1)), u = u0, v = 1 }
        }
    end
    return quads
end

hook.Add("PostDrawTranslucentRenderables", "PropCurveFinder.Curved", function(depth, skybox)
    if depth or skybox then return end
    local lcars = Star_Trek and Star_Trek.LCARS
    if not (lcars and lcars.ActiveInterfaces and lcars.RTDrawWindow) then return end

    for _, interface in pairs(lcars.ActiveInterfaces) do
        local curve = WorldCurve(interface)
        local window = interface.Windows and interface.Windows[1]
        if curve and window and window.RT and interface.IVis then
            -- STM draws the window's contents into its render target...
            lcars:RTDrawWindow(window, interface.AnimPos)
            -- ...and that's drawn round the curve.
            local additive = not interface.Solid and not window.Solid
            render.SetMaterial(WindowMaterial(window, additive))
            local alpha = math.floor(255 * math.Clamp(interface.AnimPos or 1, 0, 1))
            local quads = PCF.CurvedQuads(curve)
            mesh.Begin(MATERIAL_QUADS, #quads)
            for _, quad in ipairs(quads) do
                for _, corner in ipairs(quad) do
                    mesh.Position(corner.pos)
                    mesh.TexCoord(0, corner.u, corner.v)
                    mesh.Color(255, 255, 255, alpha)
                    mesh.AdvanceVertex()
                end
            end
            mesh.End()
        end
    end
end)
