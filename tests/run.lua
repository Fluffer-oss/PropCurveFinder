HARNESS_DIR = arg[0]:match("^(.*/)") or "./"
package.path = HARNESS_DIR .. "?.lua;" .. package.path
local M = require("mock")
local V, A = M.Vector, M.Angle

local passed, failed = 0, 0
local function check(cond, label)
    if cond then passed = passed + 1 else failed = failed + 1 print("FAIL: " .. label) end
end
local function step(label, fn)
    local ok, err = pcall(fn)
    if not ok then failed = failed + 1 print("ERROR in '" .. label .. "': " .. tostring(err)) end
end
local function near(a, b, tol) return a ~= nil and b ~= nil and math.abs(a - b) <= (tol or 1e-3) end
local function vnear(v, w, tol) return v and w and (v - w):Length() <= (tol or 1e-3) end

M.convars = {
    propcurvefinder_step = 2, propcurvefinder_maxdistance = 512, propcurvefinder_maxbend = 30,
    propcurvefinder_segments = 8, propcurvefinder_texturestop = 1, propcurvefinder_lift = 0.25
}

local admin = M.MakeEntity("player", V(0, 0, 0), nil, { admin = true })
-- Where the player is looking, for the console command and the weapon.
admin.eye, admin.look = V(0, 0, 0), V(1, 0, 0)
function admin:EyeAngles() return self.look:AngleEx(V(0, 0, 1)) end
function admin:GetEyeTrace() return M.Trace({ start = self.eye, endpos = self.eye + self.look * 4096, filter = self }) end
local client = M.NewRealm(false, admin)
client.include("autorun/propcurvefinder.lua")
local PCF = client.PropCurveFinder

-- Probes from `eye` looking at `target`.
local function ProbeAt(eye, target)
    local dir = (target - eye):GetNormalized()
    local tr = M.Trace({ start = eye, endpos = eye + dir * 4096, filter = admin })
    assert(tr.Hit, "the probe's first trace missed")
    return PCF.Probe(tr, dir), tr
end

-- cam.Start3D2D draws x along the angle's Forward, y along its Right, facing its Up.
local function Check3D2D(seg, label)
    local ang = seg.ang
    check(vnear(ang:Forward(), seg.right, 1e-6) and vnear(ang:Up(), seg.normal, 1e-6), label .. ": angle's Forward is the piece's right, Up its normal")
    check(vnear(ang:Right(), -seg.up, 1e-6), label .. ": angle's Right points down the piece (3D2D y goes down)")
end

step("eigen decomposition", function()
    local values, vectors = PCF.Math.Eigen({ { 2, 1, 0 }, { 1, 2, 0 }, { 0, 0, 5 } })
    check(near(values[1], 1, 1e-9) and near(values[2], 3, 1e-9) and near(values[3], 5, 1e-9), "eigenvalues 1, 3, 5")
    check(near(math.abs(vectors[1]:Dot(V(1, -1, 0):GetNormalized())), 1, 1e-9), "eigenvector for 1")
    check(near(math.abs(vectors[3].z), 1, 1e-9), "eigenvector for 5")
end)

step("a curved wraparound screen (concave), seen from inside", function()
    -- Radius 100 around the z axis, from -40 to +40 degrees around +x, z -20..20.
    M.scene = { M.CylinderStrip(V(0, 0, 0), V(0, 0, 1), V(1, 0, 0), 100, -40, 40, -20, 20) }
    local r = ProbeAt(V(0, 0, 0), V(100, 10, 3))
    check(r.target.type == "world", "on the world")
    check(r.shape == "cylinder", "cylinder: " .. tostring(r.shape))
    check(near(r.radius, 100, 0.05), "radius 100: " .. tostring(r.radius))
    check(r.concave == true, "concave (curving round towards you)")
    check(vnear(r.axis, V(0, 0, 1), 1e-3), "axis straight up")
    check(near(r.center.x, 0, 0.1) and near(r.center.y, 0, 0.1), "axis through the middle of the curve")
    check(near(r.arcDegrees, 80, 2.5), "80 degree arc: " .. tostring(r.arcDegrees))
    check(near(r.width, 100 * math.rad(80), 4.5), "width along the curve: " .. tostring(r.width))
    check(near(r.height, 40, 2.1), "40 tall: " .. tostring(r.height))
    check(r.residual < 0.01, "fits well: " .. tostring(r.residual))
    check(r.edges.left == "ran off the surface" and r.edges.right == "ran off the surface", "stopped at the side edges")

    check(#r.segments == 8, "8 pieces")
    local totalWidth = 0
    for i, seg in ipairs(r.segments) do
        totalWidth = totalWidth + seg.width
        Check3D2D(seg, "piece " .. i)
        -- Every corner of every piece lies on or just in front of the curve.
        for _, c in ipairs(PCF.SegmentCorners(seg)) do
            local d = math.sqrt(c.x ^ 2 + c.y ^ 2)
            if not (d <= 100 + 1e-6 and d >= 100 - 3) then check(false, "piece " .. i .. " corner off the curve: " .. d) end
        end
    end
    check(near(totalWidth, 2 * r.radius * math.sin(math.rad(r.arcDegrees) / 16) * 8, 1e-6), "pieces are the chords of the arc")
    -- Left to right as you look at it (looking down +x, your right is A(0, 0, 0):Right() = -y).
    check((r.segments[8].pos - r.segments[1].pos):Dot(A(0, 0, 0):Right()) > 0, "pieces go left to right")
    check(r.segments[1].normal:Dot(V(0, 0, 0) - r.segments[1].pos) > 0, "pieces face the viewer")
end)

step("a pillar (convex), seen from outside", function()
    M.scene = { M.CylinderStrip(V(500, 0, 0), V(0, 0, 1), V(-1, 0, 0), 50, -180, 180, -64, 64) }
    M.convars.propcurvefinder_maxdistance = 60
    local r = ProbeAt(V(300, 0, 10), V(450, 0, 10))
    M.convars.propcurvefinder_maxdistance = 512
    check(r.shape == "cylinder" and near(r.radius, 50, 0.05), "cylinder, radius 50: " .. tostring(r.radius))
    check(r.concave == false, "convex (bulging out)")
    for i, seg in ipairs(r.segments) do
        Check3D2D(seg, "piece " .. i)
        for _, c in ipairs(PCF.SegmentCorners(seg)) do
            local d = math.sqrt((c.x - 500) ^ 2 + c.y ^ 2)
            if d < 50 - 1e-6 then check(false, "piece " .. i .. " sinks into the pillar") end
        end
    end
    check(r.edges.left == "reached the maximum distance", "stopped at the maximum distance")

    -- With no lift, neighbouring pieces meet edge to edge (tangent pieces, wider than chords).
    M.convars.propcurvefinder_lift, M.convars.propcurvefinder_maxdistance = 0, 60
    r = ProbeAt(V(300, 0, 10), V(450, 0, 10))
    M.convars.propcurvefinder_lift, M.convars.propcurvefinder_maxdistance = 0.25, 512
    for i = 1, #r.segments - 1 do
        local a, b = PCF.SegmentCorners(r.segments[i]), PCF.SegmentCorners(r.segments[i + 1])
        check(vnear(a[2], b[1], 1e-6), "pieces " .. i .. " and " .. (i + 1) .. " meet")
    end
end)

step("a dome (sphere)", function()
    M.scene = { M.SphereCap(V(0, 0, 0), 200, V(1, 0, 0), 30) }
    local r = ProbeAt(V(0, 0, 0), V(200, 0, 0))
    check(r.shape == "sphere" and near(r.radius, 200, 0.2), "sphere, radius 200: " .. tostring(r.radius))
    check(r.concave == true, "concave (seen from inside)")
end)

step("a flat static prop panel: local coordinates", function()
    -- A panel prop at (1000, 200, 50), turned 30 degrees, its face 2 units in front of its origin.
    local propPos, propAng = V(1000, 200, 50), A(0, 30, 0)
    M.files["maps/rp_test.bsp"] = M.MapWithStaticProps({
        { model = "models/props/far.mdl", pos = V(-5000, 0, 0), ang = A(0, 0, 0) },
        { model = "models/props/panel.mdl", pos = propPos, ang = propAng },
        { model = "models/props/room.mdl", pos = propPos, ang = A(0, 0, 0) } -- a big prop around it
    })
    M.files["models/props/room.mdl"] = M.Model(V(-500, -500, -500), V(500, 500, 500))
    M.files["models/props/panel.mdl"] = M.Model(V(-1, -24, -16), V(2, 24, 16))
    M.files["models/props/far.mdl"] = M.Model(V(-8, -8, -8), V(8, 8, 8))
    local forward, left, up = propAng:Forward(), -propAng:Right(), propAng:Up()
    local face = M.Rect(propPos + forward * 2, forward, left, up, 24, 16)
    face.texture = "**studio**"
    M.scene = { face }

    local eye = propPos + forward * 60 + left * 5
    local r = ProbeAt(eye, propPos + forward * 2 + left * 5 + up * 4)
    check(r.target.type == "static_prop", "found the static prop: " .. r.target.type)
    check(r.target.model == "models/props/panel.mdl" and r.target.index == 1, "which one")
    check(r.shape == "flat", "flat")
    check(near(r.width, 48, 2.1) and near(r.height, 32, 2.1), "48 x 32: " .. r.width .. " x " .. r.height)
    local localHit = r.ToLocal(r.hit.pos)
    check(vnear(localHit, V(2, 5, 4), 1e-3), "hit in the prop's own coordinates: (2, 5, 4)")
    check(vnear(r.ToLocalDir(r.hit.normal), V(1, 0, 0), 1e-6), "normal in the prop's coordinates: its forward")
    check(vnear(r.ToLocal(r.frame.pos), V(2.25 - 0.25, 0, 0), 0.6), "the middle of the panel")
    Check3D2D(r.segments[1], "the panel")
    local text = PCF.FormatResult(r)
    check(text:find("Type = \"static_prop\"", 1, true) and text:find("Local = Vector(2.000, 5.000, 4.000)", 1, true), "written out with local coordinates")
    check(loadstring("return " .. text:gsub("^%-%-[^\n]*\n", "")) ~= nil, "the output is valid Lua")
end)

step("an entity: local coordinates follow its angles", function()
    local ent = M.MakeEntity("prop_physics", V(0, 0, 0), A(0, 90, 0), { model = "models/props/screen.mdl" })
    local face = M.Rect(V(0, 10, 0), V(0, 1, 0), V(1, 0, 0), V(0, 0, 1), 20, 10)
    face.entity = ent
    M.scene = { face }
    local r = ProbeAt(V(3, 100, 2), V(3, 10, 2))
    check(r.target.type == "entity" and r.target.ent == ent, "the entity")
    check(vnear(r.ToLocal(r.hit.pos), V(10, -3, 2), 1e-3), "hit in its coordinates (its forward is world +y)")
    check(r.edges.up == "ran off the surface", "stopped at its edge")
end)

step("a texture change on a world brush is an edge", function()
    local a = M.Rect(V(0, 0, 0), V(-1, 0, 0), V(0, 1, 0), V(0, 0, 1), 20, 20)
    local b = M.Rect(V(0, 40, 0), V(-1, 0, 0), V(0, 1, 0), V(0, 0, 1), 20, 20)
    a.texture, b.texture = "screen/lcars", "walls/metal"
    M.scene = { a, b }
    local r = ProbeAt(V(-50, 0, 0), V(0, 0, 0))
    check(near(r.width, 40, 2.1), "stopped where the texture changes: " .. r.width)
    check(r.edges.right == "reached a different surface" or r.edges.left == "reached a different surface", "and says so")
    M.convars.propcurvefinder_texturestop = 0
    r = ProbeAt(V(-50, 0, 0), V(0, 0, 0))
    check(near(r.width, 80, 2.1), "or carries on when told to: " .. r.width)
    M.convars.propcurvefinder_texturestop = 1
end)

step("a bend sharper than the limit is an edge", function()
    -- Flat, then bending away by 45 degrees along a shared edge at y = 20.
    local a = M.Rect(V(0, 0, 0), V(-1, 0, 0), V(0, 1, 0), V(0, 0, 1), 20, 20)
    local d = V(1, 1, 0):GetNormalized()
    local b = M.Rect(V(0, 20, 0) + d * 20, V(1, -1, 0):GetNormalized(), d, V(0, 0, 1), 20, 20)
    M.scene = { a, b }
    local r = ProbeAt(V(-50, 0, 0), V(0, 0, 0))
    check(near(r.width, 40, 2.1), "stops at the 45 degree bend: " .. r.width)
    check((r.edges.left .. r.edges.right):find("bent 45 degrees", 1, true) ~= nil, "and says so")
    M.convars.propcurvefinder_maxbend = 60
    r = ProbeAt(V(-50, 0, 0), V(0, 0, 0))
    M.convars.propcurvefinder_maxbend = 30
    check(r.width > 50, "carries on round it with a higher limit: " .. r.width)
end)

step("a right angle the walk can't follow is an edge too", function()
    -- A screen in an L: two flat faces meeting at 90 degrees.
    local a = M.Rect(V(0, 0, 0), V(-1, 0, 0), V(0, 1, 0), V(0, 0, 1), 20, 20)
    local b = M.Rect(V(20, 20, 0), V(0, -1, 0), V(1, 0, 0), V(0, 0, 1), 20, 20)
    M.scene = { a, b }
    local r = ProbeAt(V(-50, -5, 0), V(0, -5, 0))
    check(r.shape == "flat" and near(r.width, 40, 2.1), "flat, and the bent part left out: " .. r.width)
end)

--------------------------------------------------------------------------------
-- STM test interface (server)
--------------------------------------------------------------------------------

step("STM test interface: one window on each piece", function()
    M.scene = { M.CylinderStrip(V(0, 0, 0), V(0, 0, 1), V(1, 0, 0), 100, -40, 40, -20, 20) }
    local result = ProbeAt(V(0, 0, 0), V(100, 10, 3))

    local server = M.NewRealm(true)
    local created = {}
    local windows = {}
    server.ents = { Create = function(class)
        local e = M.MakeEntity(class, V(0, 0, 0))
        table.insert(created, e)
        return e
    end }
    server.Star_Trek = { LCARS = {
        Interfaces = { base = { Close = function() end } },
        CreateWindow = function(self, kind, pos, ang, scale, width, height, callback, buttons, title)
            local w = { kind = kind, pos = pos, ang = ang, scale = scale, width = width, height = height, callback = callback, buttons = buttons, title = title }
            table.insert(windows, w)
            return true, w
        end,
        OpenInterface = function(self, ply, ent, name, ...)
            local interface = setmetatable({}, { __index = self.Interfaces[name] })
            local ok, list = interface:Open(ent, ...)
            self.opened = { ok = ok, windows = list, ent = ent }
            return ok, list
        end
    } }
    server.include("autorun/propcurvefinder.lua")
    client.Star_Trek = { LCARS = {} }

    local crew = M.MakeEntity("player", V(0, 0, 0), nil, { admin = false })
    M.netQueue[#M.netQueue + 1] = nil
    -- A non-admin is refused.
    local crewClient = M.NewRealm(false, crew)
    crewClient.include("autorun/propcurvefinder.lua")
    crewClient.PropCurveFinder.RequestTestInterface(result)
    M.Pump(server, crewClient)
    check(#windows == 0 and crew.chat and crew.chat[1]:find("Only admins"), "non-admins are refused")

    PCF.RequestTestInterface(result)
    M.Pump(server, client)
    check(#windows == 8, "8 windows: " .. #windows)
    local anchor = created[1]
    check(anchor and anchor.class == "propcurvefinder_anchor" and anchor.spawned, "an anchor entity holds it")
    check(anchor.LCARSKeyData and anchor.LCARSKeyData.lcars_never_close, "and keeps it open")
    for i, w in ipairs(windows) do
        local seg = result.segments[i]
        local pos, ang = M.LocalToWorld(w.pos, w.ang, anchor.pos, anchor.ang)
        check(vnear(pos, seg.pos, 1e-3) and vnear(ang:Up(), seg.normal, 1e-6) and vnear(ang:Forward(), seg.right, 1e-6), "window " .. i .. " on its piece")
        check(near(w.width / w.scale, seg.width, 1e-6) and near(w.height / w.scale, seg.height, 1e-6), "window " .. i .. " the piece's size")
        check(w.width >= 180 - 1e-6 and w.height >= 160 - 1e-6, "window " .. i .. " big enough for STM's frame")
        check(w.kind == "button_list" and #w.buttons >= 1, "window " .. i .. " has test buttons")
    end
    windows[3].callback(nil, nil, admin, 2)
    check(admin.chat[#admin.chat]:find("segment 3 of 8, button 2", 1, true), "pressing a button says which: " .. tostring(admin.chat[#admin.chat]))
    check(anchor.sounds[1] == "star_trek.lcars_beep", "and beeps")

    -- Placing another replaces the first; the tool's clear removes it.
    PCF.RequestTestInterface(result)
    M.time = M.time + 2
    PCF.RequestTestInterface(result)
    M.Pump(server, client)
    check(not anchor.__valid and created[2] and created[2].__valid, "a new one replaces the old")
    server.PropCurveFinder.ClearTestInterface(admin)
    check(not created[2].__valid, "cleared")

    -- A small screen still gets windows big enough for STM's frame.
    M.scene = { M.Rect(V(0, 0, 0), V(-1, 0, 0), V(0, 1, 0), V(0, 0, 1), 3, 2) }
    local small = ProbeAt(V(-20, 0, 0), V(0, 0, 0))
    windows = {}
    M.time = M.time + 2
    PCF.RequestTestInterface(small)
    M.Pump(server, client)
    check(#windows == 1 and windows[1].width >= 180 - 1e-6 and windows[1].height >= 160 - 1e-6,
        "6 x 4 screen: window " .. tostring(windows[1] and windows[1].width) .. " x " .. tostring(windows[1] and windows[1].height) .. " pixels")
    check(near(windows[1].width / windows[1].scale, small.segments[1].width, 1e-6), "still exactly the screen's size")
end)

step("console commands: probe, show, clear", function()
    check(client.clientConVars.propcurvefinder_step == "2" and client.clientConVars.propcurvefinder_segments == "8", "settings are console variables")
    check(client.printed:find("propcurvefinder", 1, true) ~= nil, "says it's loaded: " .. tostring(client.printed))

    M.scene = { M.CylinderStrip(V(0, 0, 0), V(0, 0, 1), V(1, 0, 0), 100, -40, 40, -20, 20) }
    admin.eye, admin.look = V(0, 0, 0), V(1, 0.1, 0.03):GetNormalized()
    PCF.Last = nil
    client.panels = {}
    client.commands.propcurvefinder()
    check(PCF.Last and PCF.Last.shape == "cylinder" and near(PCF.Last.radius, 100, 0.05), "'propcurvefinder' probes what you're looking at")
    check(client.panels[1] and client.panels[1].class == "DFrame", "and shows the result window")
    check(client.lastPrint:find("Shape = \"cylinder\"", 1, true) ~= nil, "and prints it to the console")

    client.panels = {}
    client.commands.propcurvefinder_show()
    check(client.panels[1] and client.panels[1].class == "DFrame", "'propcurvefinder_show' shows it again")

    admin.look = V(0, 0, -1) -- at nothing
    client.commands.propcurvefinder()
    check(client.notified and client.notified:find("nothing there", 1, true), "looking at nothing says so")
end)

step("the weapon: primary probes, secondary clears", function()
    local server = M.NewRealm(true)
    local created = {}
    server.ents = { Create = function(class) local e = M.MakeEntity(class, V(0, 0, 0)) table.insert(created, e) return e end }
    server.Star_Trek = { LCARS = {
        Interfaces = { base = {} },
        CreateWindow = function(_, ...) return true, {} end,
        OpenInterface = function(self, ply, ent, name, ...)
            return setmetatable({}, { __index = self.Interfaces[name] }):Open(ent, ...)
        end
    } }
    server.include("autorun/propcurvefinder.lua")
    server.SWEP = {}
    server.include("weapons/weapon_propcurvefinder.lua")
    local SWEP = server.SWEP
    check(SWEP.Spawnable and SWEP.PrintName == "Prop Curve Finder", "spawnable weapon")
    local weapon = setmetatable({ GetOwner = function() return admin end, SetNextPrimaryFire = function() end,
        SetNextSecondaryFire = function() end, EmitSound = function() end }, { __index = SWEP })

    M.scene = { M.Rect(V(50, 0, 0), V(-1, 0, 0), V(0, 1, 0), V(0, 0, 1), 10, 5) }
    admin.eye, admin.look = V(0, 0, 0), V(1, 0, 0)
    PCF.Last = nil
    weapon:PrimaryAttack()
    M.Pump(server, client)
    check(PCF.Last and PCF.Last.shape == "flat" and near(PCF.Last.width, 20, 2.1), "primary probes on the owner's game")

    PCF.RequestTestInterface(PCF.Last)
    M.Pump(server, client)
    check(created[1] and created[1].__valid, "a test interface placed")
    weapon:SecondaryAttack()
    M.Pump(server, client)
    check(PCF.Last == nil and not created[1].__valid, "secondary clears the probe and the interface")

    -- The console clear does the same through the server.
    M.time = M.time + 2
    PCF.Last = PCF.Probe(admin:GetEyeTrace(), admin.look)
    PCF.RequestTestInterface(PCF.Last)
    M.Pump(server, client)
    client.commands.propcurvefinder_clear()
    M.Pump(server, client)
    check(PCF.Last == nil and created[2] and not created[2].__valid, "'propcurvefinder_clear' clears both")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
