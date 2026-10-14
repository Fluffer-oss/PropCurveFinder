PropCurveFinder = PropCurveFinder or {}
local PCF = PropCurveFinder

-- Showing a probe: drawn in the world (samples, edges, fitted curve, segments),
-- and written out as a Lua table in a window you can copy from.

local function N(x) return string.format("%.3f", x) end
local function Vec(v) return "Vector(" .. N(v.x) .. ", " .. N(v.y) .. ", " .. N(v.z) .. ")" end
local function Ang(a) return "Angle(" .. N(a.p) .. ", " .. N(a.y) .. ", " .. N(a.r) .. ")" end
PCF.FormatVector, PCF.FormatAngle = Vec, Ang

-- The result as a Lua table: world coordinates, and the target's own
-- coordinates ("Local") when it's a prop or entity. A material in several
-- separate pieces gets a Pieces list, left to right, each with everything
-- needed to build an interface on it.
function PCF.FormatResult(result)
    local t = result.target
    local out = {}
    local function line(depth, text) table.insert(out, string.rep("    ", depth) .. text) end

    -- One surface's measurements, at `depth`.
    local function Body(r, depth)
        local L = r.ToLocal
        local function pair(d, key, world, localValue)
            if localValue then
                line(d, key .. " = { World = " .. world .. ", Local = " .. localValue .. " },")
            else
                line(d, key .. " = " .. world .. ",")
            end
        end
        if r.aimed ~= false then
            line(depth, "Hit = {")
            pair(depth + 1, "Pos", Vec(r.hit.pos), L and Vec(L(r.hit.pos)))
            pair(depth + 1, "Normal", Vec(r.hit.normal), L and Vec(r.ToLocalDir(r.hit.normal)))
            line(depth, "},")
        end
        line(depth, "Shape = \"" .. r.shape .. "\", -- fit error " .. N(r.residual or 0) .. " units (rms)")
        if r.radius then line(depth, "Radius = " .. N(r.radius) .. ",") end
        if r.concave ~= nil then line(depth, "Concave = " .. tostring(r.concave) .. ", -- curves towards you") end
        if r.center then pair(depth, "Center", Vec(r.center), L and Vec(L(r.center))) end
        if r.axis then pair(depth, "Axis", Vec(r.axis), L and Vec(r.ToLocalDir(r.axis))) end
        if r.arcDegrees then line(depth, "ArcDegrees = " .. N(r.arcDegrees) .. ",") end
        line(depth, "Width = " .. N(r.width) .. ", -- along the surface")
        line(depth, "Height = " .. N(r.height) .. ",")

        local frame = r.frame
        line(depth, "Screen = { -- the middle of the surface, facing out")
        pair(depth + 1, "Pos", Vec(frame.pos), L and Vec(L(frame.pos)))
        pair(depth + 1, "Ang", Ang(frame.ang), L and Ang(r.ToLocalAng({ right = frame.up:Cross(frame.normal):GetNormalized(), normal = frame.normal })))
        line(depth, "},")

        -- The exact surface (see sh_curve.lua): u runs left to right, v top to bottom.
        local c = r.curve
        if c then
            line(depth, "Curve = {")
            if c.flat then
                line(depth + 1, "Flat = true, Width = " .. N(c.width) .. ", Height = " .. N(c.height) .. ",")
                pair(depth + 1, "Center", Vec(c.center), L and Vec(L(c.center)))
                for _, key in ipairs({ "normal", "right", "up" }) do
                    pair(depth + 1, key:sub(1, 1):upper() .. key:sub(2), Vec(c[key]), L and Vec(r.ToLocalDir(c[key])))
                end
            else
                line(depth + 1, "Radius = " .. N(c.radius) .. ", Concave = " .. tostring(c.concave) .. ",")
                line(depth + 1, "TMin = " .. N(c.tMin) .. ", TMax = " .. N(c.tMax) .. ", -- radians round the axis, from E1 towards E2")
                line(depth + 1, "HMin = " .. N(c.hMin) .. ", HMax = " .. N(c.hMax) .. ", -- along the axis, from Center")
                pair(depth + 1, "Center", Vec(c.center), L and Vec(L(c.center)))
                for _, key in ipairs({ "axis", "e1", "e2" }) do
                    pair(depth + 1, key:sub(1, 1):upper() .. key:sub(2), Vec(c[key]), L and Vec(r.ToLocalDir(c[key])))
                end
            end
            line(depth, "},")
        end

        line(depth, "Edges = { -- why each direction stopped")
        for _, side in ipairs({ "left", "right", "up", "down" }) do
            line(depth + 1, side:sub(1, 1):upper() .. side:sub(2) .. " = \"" .. r.edges[side] .. "\",")
        end
        line(depth, "},")

        line(depth, "-- Flat pieces following the surface, for cam.Start3D2D(TopLeft, Ang, scale)")
        line(depth, "-- (Pos is each piece's middle).")
        line(depth, "Segments = {")
        for _, seg in ipairs(r.segments) do
            line(depth + 1, "{")
            pair(depth + 2, "Pos", Vec(seg.pos), L and Vec(L(seg.pos)))
            pair(depth + 2, "TopLeft", Vec(seg.topLeft), L and Vec(L(seg.topLeft)))
            pair(depth + 2, "Ang", Ang(seg.ang), L and Ang(r.ToLocalAng(seg)))
            line(depth + 2, "Width = " .. N(seg.width) .. ", Height = " .. N(seg.height) .. ",")
            line(depth + 1, "},")
        end
        line(depth, "},")
    end

    line(0, "-- PropCurveFinder")
    line(0, "{")
    line(1, "Target = {")
    line(2, "Type = \"" .. t.type .. "\",")
    if t.class then line(2, "Class = \"" .. t.class .. "\",") end
    if t.model then line(2, "Model = \"" .. t.model .. "\",") end
    if t.index then line(2, "StaticPropIndex = " .. t.index .. ",") end
    if t.texture then line(2, "Texture = \"" .. t.texture .. "\",") end
    if t.pos then line(2, "Pos = " .. Vec(t.pos) .. ",") end
    if t.ang then line(2, "Ang = " .. Ang(t.ang) .. ",") end
    line(1, "},")

    if result.source == "model" then
        line(1, "Material = \"" .. result.material .. "\", -- measured from the model's own triangles")
    elseif result.meshNote then
        line(1, "-- Measured with traces (" .. result.meshNote .. ").")
    end

    local pieces = result.pieces
    if pieces and #pieces > 1 then
        line(1, "-- " .. #pieces .. " separate pieces of the material, left to right as you looked at them.")
        line(1, "Aimed = " .. result.index .. ", -- the one you aimed at (or nearest)")
        line(1, "Pieces = {")
        for i, piece in ipairs(pieces) do
            line(2, "{ -- piece " .. i)
            Body(piece, 3)
            line(2, "},")
        end
        line(1, "},")
    else
        Body(result, 1)
    end
    line(0, "}")
    return table.concat(out, "\n")
end

--------------------------------------------------------------------------------
-- In the world
--------------------------------------------------------------------------------

local function Corners(seg)
    local r, u = seg.right * (seg.width / 2), seg.up * (seg.height / 2)
    return { seg.pos - r + u, seg.pos + r + u, seg.pos + r - u, seg.pos - r - u }
end
PCF.SegmentCorners = Corners

local function DrawResult(result)
    for i, tri in ipairs(result.triangles or {}) do
        if i > 4000 then break end
        for k = 1, 3 do render.DrawLine(tri[k], tri[k % 3 + 1], Color(0, 200, 255), false) end
    end
    for _, p in ipairs(result.points) do
        render.DrawLine(p, p + result.hit.normal * 1, Color(255, 255, 0), false)
    end
    for _, path in pairs(result.paths) do
        local last = path[#path]
        if last then render.DrawWireframeSphere(last.pos, 1, 6, 6, Color(255, 80, 80), false) end
    end
    render.DrawLine(result.hit.pos, result.hit.pos + result.hit.normal * 12, Color(80, 160, 255), false)
    if result.axis and result.center then
        render.DrawLine(result.center - result.axis * result.height, result.center + result.axis * result.height, Color(255, 0, 255), false)
    end
    for _, seg in ipairs(result.segments) do
        local c = Corners(seg)
        for i = 1, 4 do render.DrawLine(c[i], c[i % 4 + 1], Color(80, 255, 120), false) end
    end
end

hook.Add("PostDrawTranslucentRenderables", "PropCurveFinder.Overlay", function(depth, skybox)
    local result = PCF.Last
    if depth or skybox or not result then return end
    render.SetColorMaterial()
    for _, piece in ipairs(result.pieces or { result }) do DrawResult(piece) end
end)

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local frame
function PCF.ShowResult(result)
    if IsValid(frame) then frame:Remove() end
    local text = PCF.FormatResult(result)

    frame = vgui.Create("DFrame")
    local count = result.pieces and #result.pieces or 1
    frame:SetTitle("PropCurveFinder: " .. (count > 1 and (count .. " pieces, ") or "") .. result.shape .. (result.radius and string.format(", radius %.1f", result.radius) or ""))
    frame:SetSize(math.min(ScrW() - 40, 760), math.min(ScrH() - 40, 640))
    frame:Center()
    frame:MakePopup()

    local buttons = vgui.Create("DPanel", frame)
    buttons:Dock(BOTTOM)
    buttons:SetTall(30)
    buttons:SetPaintBackground(false)

    local entry = vgui.Create("DTextEntry", frame)
    entry:Dock(FILL)
    entry:SetMultiline(true)
    entry:SetFont("DebugFixed")
    entry:SetText(text)

    local copy = vgui.Create("DButton", buttons)
    copy:Dock(LEFT)
    copy:SetWide(140)
    copy:SetText("Copy to clipboard")
    copy.DoClick = function()
        SetClipboardText(text)
        copy:SetText("Copied")
    end

    local interface = vgui.Create("DButton", buttons)
    interface:Dock(LEFT)
    interface:DockMargin(6, 0, 0, 0)
    interface:SetWide(200)
    interface:SetText(count > 1 and ("Make " .. count .. " STM test interfaces") or "Make STM test interface")
    interface:SetEnabled(Star_Trek ~= nil and Star_Trek.LCARS ~= nil)
    interface.DoClick = function()
        PCF.RequestTestInterface(result)
        frame:Close()
    end
end

--------------------------------------------------------------------------------
-- Network
--------------------------------------------------------------------------------

-- Asks the server for STM test interfaces: one covering each piece.
function PCF.RequestTestInterface(result)
    local pieces = result.pieces or { result }
    local lift = PCF.Setting("lift", 0.25)
    net.Start("PropCurveFinder.TestInterface")
    net.WriteEntity(result.target.type == "entity" and result.target.ent or NULL)
    net.WriteUInt(math.min(#pieces, 15), 4)
    for i = 1, math.min(#pieces, 15) do
        local curve = pieces[i].curve
        -- A little in front of the surface, so it doesn't flicker into it.
        local lifted = {}
        for k, v in pairs(curve) do lifted[k] = v end
        if curve.flat then
            lifted.center = curve.center + curve.normal * lift
        else
            lifted.radius = curve.radius + (curve.concave and -lift or lift)
        end
        PCF.Curve.Write(lifted)
    end
    net.SendToServer()
end

-- Probes whatever you're looking at.
function PCF.ProbeLook()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local tr = ply:GetEyeTrace()
    if not tr.Hit or tr.HitSky then
        notification.AddLegacy("PropCurveFinder: nothing there", NOTIFY_ERROR, 3)
        return
    end
    local result = PCF.Probe(tr, ply:EyeAngles():Forward())
    PCF.Last = result
    print(PCF.FormatResult(result))
    PCF.ShowResult(result)
    return result
end

-- Clears the drawing, the window, and (on the server) your test interface.
function PCF.Clear(fromServer)
    PCF.Last = nil
    if IsValid(frame) then frame:Remove() end
    if not fromServer then
        net.Start("PropCurveFinder.ClearRequest")
        net.SendToServer()
    end
end

function PCF.Reopen()
    if PCF.Last then PCF.ShowResult(PCF.Last) end
end

-- Console commands, bindable: bind f6 propcurvefinder
concommand.Add("propcurvefinder", function() PCF.ProbeLook() end, nil, "Probe the surface you're looking at")
concommand.Add("propcurvefinder_clear", function() PCF.Clear() end, nil, "Clear the probe and your test interface")
concommand.Add("propcurvefinder_show", function() PCF.Reopen() end, nil, "Show the last result again")
-- The static prop under the crosshair: where it is, printed and copied.
function PCF.StaticPropInfo()
    local tr = LocalPlayer():GetEyeTrace()
    local prop = tr.Hit and PCF.FindStaticProp(tr.HitPos)
    if not prop then
        print("[PropCurveFinder] No static prop under the crosshair" .. (tr.HitTexture == "**studio**" and " found in the map's list." or "."))
        return nil
    end
    local bounds = PCF.ModelBounds(prop.model)
    local text = string.format('{ Model = "%s", Index = %d, Skin = %d, Pos = %s, Ang = %s%s }',
        prop.model, prop.index, prop.skin or 0, Vec(prop.pos), Ang(prop.ang),
        bounds and (", Mins = " .. Vec(bounds.mins) .. ", Maxs = " .. Vec(bounds.maxs)) or "")
    print("[PropCurveFinder] " .. text)
    SetClipboardText(text)
    return prop, text
end

concommand.Add("propcurvefinder_staticprop", function() PCF.StaticPropInfo() end, nil,
    "Print (and copy) the position and angles of the static prop you're looking at")

concommand.Add("propcurvefinder_materials", function()
    local ply = LocalPlayer()
    local target = PCF.IdentifyTarget(ply:GetEyeTrace())
    local mesh = target.model and PCF.ModelMesh(target.model, target.skin)
    if not mesh then
        print("[PropCurveFinder] Look at a prop (its model files must be readable).")
        return
    end
    print("[PropCurveFinder] " .. target.model .. " uses:")
    for _, name in ipairs(PCF.ModelMaterials(mesh)) do print("    " .. name) end
    print("Pick one with: propcurvefinder_material <name>   (or propcurvefinder_material \"\" for the one you look at)")
end, nil, "List the materials of the prop you're looking at")

-- From the weapon (in singleplayer, weapons only run on the server).
net.Receive("PropCurveFinder.Probe", function() PCF.ProbeLook() end)
net.Receive("PropCurveFinder.Clear", function() PCF.Clear(true) end)
net.Receive("PropCurveFinder.Reopen", function() PCF.Reopen() end)
