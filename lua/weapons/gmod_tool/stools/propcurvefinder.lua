TOOL.Category = "Construction"
TOOL.Name = "#tool.propcurvefinder.name"

TOOL.ClientConVar = {
    step = "2",          -- distance between samples when walking along the surface
    maxdistance = "512", -- how far to walk in each direction
    maxbend = "30",      -- a sharper bend than this (degrees) is an edge
    segments = "8",      -- flat pieces to split a curved surface into
    texturestop = "1",   -- on world brushes, a different texture is an edge
    lift = "0.25"        -- how far in front of the surface the pieces sit
}

if CLIENT then
    language.Add("tool.propcurvefinder.name", "Prop Curve Finder")
    language.Add("tool.propcurvefinder.desc", "Measure a surface: its shape, curve, size and coordinates")
    language.Add("tool.propcurvefinder.left", "Probe the surface")
    language.Add("tool.propcurvefinder.right", "Clear the probe and test interface")
    language.Add("tool.propcurvefinder.reload", "Show the last result again")
    TOOL.Information = { { name = "left" }, { name = "right" }, { name = "reload" } }
end

-- The work happens on the client (it reads the map's static props and shows
-- the result there); the server just tells it when, which also works in
-- singleplayer where tools only run on the server.
local function Send(tool, message)
    if CLIENT then return true end
    local ply = tool:GetOwner()
    if IsValid(ply) then
        net.Start(message)
        net.Send(ply)
    end
    return true
end

function TOOL:LeftClick(trace)
    if not trace.Hit then return false end
    return Send(self, "PropCurveFinder.Probe")
end

function TOOL:RightClick()
    if SERVER and PropCurveFinder.ClearTestInterface then PropCurveFinder.ClearTestInterface(self:GetOwner()) end
    return Send(self, "PropCurveFinder.Clear")
end

function TOOL:Reload()
    return Send(self, "PropCurveFinder.Reopen")
end

function TOOL.BuildCPanel(panel)
    panel:Help("Click a surface. The tool walks along it to its edges, works out whether it's flat or curved (and its radius, axis and arc), and splits it into flat pieces you can draw on with cam.Start3D2D. Coordinates are given in the world and, for props and entities, in the prop's own space.")
    panel:NumSlider("Sample spacing", "propcurvefinder_step", 0.5, 16, 1)
    panel:NumSlider("Max distance", "propcurvefinder_maxdistance", 16, 2048, 0)
    panel:NumSlider("Edge bend (degrees)", "propcurvefinder_maxbend", 5, 89, 0)
    panel:NumSlider("Pieces", "propcurvefinder_segments", 1, 64, 0)
    panel:NumSlider("Lift off the surface", "propcurvefinder_lift", 0, 4, 2)
    panel:CheckBox("Stop at texture changes (world brushes)", "propcurvefinder_texturestop")
end
