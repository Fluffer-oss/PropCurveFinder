PropCurveFinder = PropCurveFinder or {}
local PCF = PropCurveFinder

-- Showing a probe: drawn in the world (samples, edges, fitted curve, segments),
-- and written out as a Lua table in a window you can copy from.

local function N(x) return string.format("%.3f", x) end
local function Vec(v) return "Vector(" .. N(v.x) .. ", " .. N(v.y) .. ", " .. N(v.z) .. ")" end
local function Ang(a) return "Angle(" .. N(a.p) .. ", " .. N(a.y) .. ", " .. N(a.r) .. ")" end
PCF.FormatVector, PCF.FormatAngle = Vec, Ang

-- The result as a Lua table: world coordinates, and the target's own
-- coordinates ("Local") when it's a prop or entity.
function PCF.FormatResult(result)
    local t = result.target
    local L = result.ToLocal
    local out = {}
    local function line(depth, text) table.insert(out, string.rep("    ", depth) .. text) end
    local function pair(depth, key, world, localValue)
        if localValue then
            line(depth, key .. " = { World = " .. world .. ", Local = " .. localValue .. " },")
        else
            line(depth, key .. " = " .. world .. ",")
        end
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

    line(1, "Hit = {")
    pair(2, "Pos", Vec(result.hit.pos), L and Vec(L(result.hit.pos)))
    pair(2, "Normal", Vec(result.hit.normal), L and Vec(result.ToLocalDir(result.hit.normal)))
    line(1, "},")

    if result.source == "model" then
        line(1, "Material = \"" .. result.material .. "\", -- measured from the model's own triangles")
    elseif result.meshNote then
        line(1, "-- Measured with traces (" .. result.meshNote .. ").")
    end
    line(1, "Shape = \"" .. result.shape .. "\", -- fit error " .. N(result.residual or 0) .. " units (rms)")
    if result.radius then line(1, "Radius = " .. N(result.radius) .. ",") end
    if result.concave ~= nil then line(1, "Concave = " .. tostring(result.concave) .. ", -- curves towards you") end
    if result.center then pair(1, "Center", Vec(result.center), L and Vec(L(result.center))) end
    if result.axis then pair(1, "Axis", Vec(result.axis), L and Vec(result.ToLocalDir(result.axis))) end
    if result.arcDegrees then line(1, "ArcDegrees = " .. N(result.arcDegrees) .. ",") end
    line(1, "Width = " .. N(result.width) .. ", -- along the surface")
    line(1, "Height = " .. N(result.height) .. ",")

    local frame = result.frame
    line(1, "Screen = { -- the middle of the surface, facing out")
    pair(2, "Pos", Vec(frame.pos), L and Vec(L(frame.pos)))
    pair(2, "Ang", Ang(frame.ang), L and Ang(result.ToLocalAng({ right = frame.up:Cross(frame.normal):GetNormalized(), normal = frame.normal })))
    line(1, "},")

    line(1, "Edges = { -- why each direction stopped")
    for _, side in ipairs({ "left", "right", "up", "down" }) do
        line(2, side:sub(1, 1):upper() .. side:sub(2) .. " = \"" .. result.edges[side] .. "\",")
    end
    line(1, "},")

    line(1, "-- Flat pieces following the surface, for cam.Start3D2D(TopLeft, Ang, scale)")
    line(1, "-- (Pos is each piece's middle).")
    line(1, "Segments = {")
    for _, seg in ipairs(result.segments) do
        line(2, "{")
        pair(3, "Pos", Vec(seg.pos), L and Vec(L(seg.pos)))
        pair(3, "TopLeft", Vec(seg.topLeft), L and Vec(L(seg.topLeft)))
        pair(3, "Ang", Ang(seg.ang), L and Ang(result.ToLocalAng(seg)))
        line(3, "Width = " .. N(seg.width) .. ", Height = " .. N(seg.height) .. ",")
        line(2, "},")
    end
    line(1, "},")
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

hook.Add("PostDrawTranslucentRenderables", "PropCurveFinder.Overlay", function(depth, skybox)
    local result = PCF.Last
    if depth or skybox or not result then return end

    render.SetColorMaterial()
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
end)

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local frame
function PCF.ShowResult(result)
    if IsValid(frame) then frame:Remove() end
    local text = PCF.FormatResult(result)

    frame = vgui.Create("DFrame")
    frame:SetTitle("PropCurveFinder: " .. result.shape .. (result.radius and string.format(", radius %.1f", result.radius) or ""))
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
    interface:SetText("Make STM test interface")
    interface:SetEnabled(Star_Trek ~= nil and Star_Trek.LCARS ~= nil)
    interface.DoClick = function()
        PCF.RequestTestInterface(result)
        frame:Close()
    end
end

--------------------------------------------------------------------------------
-- Network
--------------------------------------------------------------------------------

-- Asks the server for an STM interface with one window on each segment.
function PCF.RequestTestInterface(result)
    net.Start("PropCurveFinder.TestInterface")
    net.WriteEntity(result.target.type == "entity" and result.target.ent or NULL)
    net.WriteUInt(#result.segments, 7)
    for _, seg in ipairs(result.segments) do
        net.WriteVector(seg.pos)
        net.WriteAngle(seg.ang)
        net.WriteFloat(seg.width)
        net.WriteFloat(seg.height)
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
