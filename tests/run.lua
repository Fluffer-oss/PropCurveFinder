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
    propcurvefinder_material = "",
    propcurvefinder_step = 2, propcurvefinder_maxdistance = 512, propcurvefinder_maxbend = 30,
    propcurvefinder_segments = 8, propcurvefinder_texturestop = 1, propcurvefinder_lift = 0.25
}

local admin = M.MakeEntity("player", V(0, 0, 0), nil, { admin = true })
-- Where the player is looking, for the console command and the weapon.
admin.eye, admin.look = V(0, 0, 0), V(1, 0, 0)
function admin:EyeAngles() return self.look:AngleEx(V(0, 0, 1)) end
function admin:EyePos() return self.eye end
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

-- A fake STM: windows are recorded; button_matrix windows take rows of buttons.
local function FakeSTM(windows)
    return { LCARS = {
        Interfaces = { base = { Close = function() end } },
        CreateWindow = function(self, kind, pos, ang, scale, width, height, callback, title)
            local w = { kind = kind, pos = pos, ang = ang, scale = scale, width = width, height = height, title = title, rows = {} }
            function w:CreateMainButtonRow(rowHeight) local row = { height = rowHeight, buttons = {} } table.insert(self.rows, row) return row end
            function w:AddButtonToRow(row, name, number, color, active, disabled, toggle, cb)
                local button = { name = name, callback = cb }
                table.insert(row.buttons, button)
                return button
            end
            table.insert(windows, w)
            return true, w
        end,
        OpenInterface = function(self, ply, ent, name, ...)
            return setmetatable({}, { __index = self.Interfaces[name] }):Open(ent, ...)
        end
    } }
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

step("a console's screen material: measured from the model's own triangles", function()
    -- A static prop console turned 30 degrees. Its screen material is a concave
    -- strip, radius 80 around the prop's z axis, -30..30 degrees around its +x,
    -- z -20..25. A frame material carries on from 30 to 45 degrees, and a
    -- separate piece of the screen material sits at -60..-45. The collision
    -- model is a flat sheet of glass 10 units in front: that's all traces hit.
    local propPos, propAng = V(2000, 500, 100), A(0, 30, 0)
    local function Strip(texture, a1, a2)
        local verts, tris = {}, {}
        local columns = math.floor((a2 - a1) / 5 + 0.5)
        for c = 0, columns do
            local t = math.rad(a1 + (a2 - a1) * c / columns)
            for _, z in ipairs({ -20, 25 }) do
                local radial = V(math.cos(t), math.sin(t), 0)
                table.insert(verts, { pos = radial * 80 + V(0, 0, z), normal = -radial })
            end
        end
        for c = 0, columns - 1 do
            local i = c * 2 + 1
            table.insert(tris, { i, i + 2, i + 1 })
            table.insert(tris, { i + 1, i + 2, i + 3 })
        end
        return { texture = texture, verts = verts, tris = tris }
    end
    local meshes = { Strip("screen_middle", -30, 30), Strip("frame", 30, 45), Strip("screen_middle", -60, -45) }
    local mdl, vvd, vtx = M.ModelFiles(meshes, "models\\kingpommes\\test\\", V(-10, -100, -30), V(100, 100, 30), true)
    M.files["models/test/console.mdl"], M.files["models/test/console.vvd"], M.files["models/test/console.dx90.vtx"] = mdl, vvd, vtx
    M.existingMaterials["models/kingpommes/test/screen_middle"] = true
    M.existingMaterials["models/kingpommes/test/frame"] = true
    M.files["maps/rp_test.bsp"] = M.MapWithStaticProps({ { model = "models/test/console.mdl", pos = propPos, ang = propAng } })
    PCF.ReloadStaticProps()

    local forward, left = propAng:Forward(), -propAng:Right()
    local glass = M.Rect(propPos + forward * 70, forward, left, V(0, 0, 1), 60, 30)
    glass.texture = "**studio**"
    M.scene = { glass }

    local mesh = PCF.ModelMesh("models/test/console.mdl", 0)
    check(mesh and #mesh.triangles == (12 + 3 + 3) * 2, "the model's triangles read: " .. tostring(mesh and #mesh.triangles))
    check(mesh and mesh.triangles[1].material == "models/kingpommes/test/screen_middle", "with their materials")
    -- The right corners: the screen's triangles add up to its 12 flat strips of 45 x chord.
    local area = 0
    for _, tri in ipairs(mesh and mesh.triangles or {}) do
        if tri.material == "models/kingpommes/test/screen_middle" then area = area + (tri.b - tri.a):Cross(tri.c - tri.a):Length() / 2 end
    end
    local strip = 45 * 2 * 80 * math.sin(math.rad(5) / 2)
    check(near(area, strip * (12 + 3), 0.01), "triangles join the right corners: area " .. area .. ", want " .. strip * 15)

    -- Aim at the screen through the glass, a little off center.
    local eye = propPos + V(0, 0, 5)
    local aim = propPos + (forward * math.cos(math.rad(10)) + left * math.sin(math.rad(10))) * 80 + V(0, 0, 5)
    local r = ProbeAt(eye, aim)
    check(r.source == "model", "measured from the model, not traces: " .. tostring(r.source) .. " " .. tostring(r.meshNote))
    check(r.material == "models/kingpommes/test/screen_middle", "the material under the crosshair")
    check(near(math.sqrt((r.hit.pos.x - propPos.x) ^ 2 + (r.hit.pos.y - propPos.y) ^ 2), 80, 0.3),
        "hit on the screen itself, not the glass in front of it")
    check(r.shape == "cylinder" and near(r.radius, 80, 0.01), "radius exactly 80: " .. tostring(r.radius))
    check(r.concave == true, "concave")
    check(near(r.arcDegrees, 60, 0.01), "exactly the screen material's 60 degrees (not the frame, not the other piece): " .. tostring(r.arcDegrees))
    check(near(r.height, 45, 1e-3), "exactly its 45 height: " .. tostring(r.height))
    check(vnear(r.ToLocal(r.center), V(0, 0, r.ToLocal(r.center).z), 1e-3), "its axis through the prop's origin")
    check(vnear(r.ToLocal(r.frame.pos), V(80, 0, 2.5), 1e-3), "the screen's middle in the prop's coordinates")
    check(#r.segments == 8 and near(r.segments[1].width, 2 * 80 * math.sin(math.rad(60) / 16), 1e-6), "8 chord pieces across it")
    for i, seg in ipairs(r.segments) do Check3D2D(seg, "piece " .. i) end
    check(PCF.FormatResult(r):find("Material = \"models/kingpommes/test/screen_middle\"", 1, true) ~= nil, "material in the output")

    -- Pick a material by name: the frame.
    M.convars.propcurvefinder_material = "models/kingpommes/test/frame"
    r = ProbeAt(eye, aim)
    M.convars.propcurvefinder_material = ""
    check(r.material == "models/kingpommes/test/frame" and near(r.arcDegrees, 15, 0.01), "the frame by name: 15 degrees")

    -- A material the model doesn't have: back to traces, and says why.
    M.convars.propcurvefinder_material = "models/kingpommes/test/nope"
    r = ProbeAt(eye, aim)
    M.convars.propcurvefinder_material = ""
    check(r.source == "traces" and r.meshNote:find("doesn't use", 1, true), "unknown material: traces, with the reason")
end)

step("a material in separate pieces: each measured, exported and given its own interface", function()
    -- A lower console panel: one material in three curved pieces with gaps
    -- between (-50..-20, -15..15, 20..50 degrees), radius 80, z -30..-10, plus a
    -- sliver too small to count.
    local propPos, propAng = V(-3000, 0, 0), A(0, 0, 0)
    local function Strip(texture, a1, a2, z1, z2)
        local verts, tris = {}, {}
        local columns = math.max(1, math.floor((a2 - a1) / 5 + 0.5))
        for c = 0, columns do
            local t = math.rad(a1 + (a2 - a1) * c / columns)
            for _, z in ipairs({ z1, z2 }) do
                local radial = V(math.cos(t), math.sin(t), 0)
                table.insert(verts, { pos = radial * 80 + V(0, 0, z), normal = -radial })
            end
        end
        for c = 0, columns - 1 do
            local i = c * 2 + 1
            table.insert(tris, { i, i + 2, i + 1 })
            table.insert(tris, { i + 1, i + 2, i + 3 })
        end
        return { texture = texture, verts = verts, tris = tris }
    end
    local meshes = {
        Strip("lower", -15, 15, -30, -10), Strip("lower", 20, 50, -30, -10), Strip("lower", -50, -20, -30, -10),
        Strip("lower", 60, 60.2, -30, -29.9) -- a sliver
    }
    local mdl, vvd, vtx = M.ModelFiles(meshes, "models/kingpommes/test/", V(-10, -100, -40), V(100, 100, 10), false)
    M.files["models/test/lower.mdl"], M.files["models/test/lower.vvd"], M.files["models/test/lower.dx90.vtx"] = mdl, vvd, vtx
    M.existingMaterials["models/kingpommes/test/lower"] = true
    M.files["maps/rp_test.bsp"] = M.MapWithStaticProps({ { model = "models/test/lower.mdl", pos = propPos, ang = propAng } })
    M.files["models/test/lower.mdl"] = mdl
    PCF.ReloadStaticProps()
    local glass = M.Rect(propPos + V(70, 0, -20), V(1, 0, 0), V(0, 1, 0), V(0, 0, 1), 60, 20)
    glass.texture = "**studio**"
    M.scene = { glass }

    M.convars.propcurvefinder_material = "models/kingpommes/test/lower"
    local eye = propPos + V(0, 0, -20)
    local r = ProbeAt(eye, propPos + V(80, 5, -20)) -- aiming at the middle piece
    M.convars.propcurvefinder_material = ""

    check(r.pieces and #r.pieces == 3, "three pieces (the sliver dropped): " .. tostring(r.pieces and #r.pieces))
    -- Looking down +x, left is +y: left to right is the 20..50 piece, then the middle, then -50..-20.
    local expected = { { 20, 50 }, { -15, 15 }, { -50, -20 } }
    for i, piece in ipairs(r.pieces or {}) do
        local mid = piece.ToLocal(piece.frame.pos)
        local angle = math.deg(math.atan2(mid.y, mid.x))
        check(near(angle, (expected[i][1] + expected[i][2]) / 2, 0.01), "piece " .. i .. " in order, left to right: middle at " .. angle)
        check(piece.shape == "cylinder" and near(piece.radius, 80, 0.01) and near(piece.arcDegrees, 30, 0.01) and near(piece.height, 20, 1e-3),
            "piece " .. i .. " measured on its own: radius " .. tostring(piece.radius) .. ", " .. tostring(piece.arcDegrees) .. " degrees")
        check(piece.index == i, "piece " .. i .. " numbered")
    end
    check(r.index == 2 and r.aimed, "the result is the one aimed at")

    local text = PCF.FormatResult(r)
    local _, count = text:gsub("{ %-%- piece %d", "")
    check(count == 3 and text:find("Aimed = 2", 1, true) and text:find("Pieces = {", 1, true), "exported as three pieces")
    check(text:find("TMin = ", 1, true) and text:find("E1 = { World", 1, true), "each with its exact curve")
    local chunk = loadstring("return " .. text:gsub("^%-%-[^\n]*\n", ""))
    check(chunk ~= nil, "the export is valid Lua")
    if chunk then
        local data = setfenv(chunk, { Vector = V, Angle = A })()
        check(#data.Pieces == 3 and near(data.Pieces[1].Radius, 80, 0.01) and data.Pieces[3].Curve.Concave == true, "and reads back")
    end

    -- Three separate STM test interfaces.
    local server = M.NewRealm(true)
    local created, windows = {}, {}
    server.ents = { Create = function(class) local e = M.MakeEntity(class, V(0, 0, 0)) table.insert(created, e) return e end }
    server.Star_Trek = FakeSTM(windows)
    server.include("autorun/propcurvefinder.lua")
    client.Star_Trek = { LCARS = {} }
    admin.pos = eye
    M.time = M.time + 5
    PCF.RequestTestInterface(r)
    M.Pump(server, client)
    check(#created == 3 and #windows == 3, "three interfaces, each on its own anchor: " .. #created .. ", " .. #windows)
    for i, w in ipairs(windows) do
        local piece = r.pieces[i]
        check(near(w.width / w.scale, (80 - 0.25) * math.rad(30), 0.1), "interface " .. i .. " as wide as its piece")
        local pos = M.LocalToWorld(w.pos, w.ang, created[i].pos, created[i].ang)
        local u, v = PCF.Curve.Hit(piece.curve, eye, (pos - eye):GetNormalized())
        check(u and near(u, 0.5, 1e-3) and near(v, 0.5, 1e-3), "interface " .. i .. " on its own piece")
        check(w.title:find(i .. "/3", 1, true), "titled " .. i .. "/3: " .. w.title)
    end
    windows[2].rows[1].buttons[2].callback(admin)
    check(admin.chat[#admin.chat]:find("interface 2 of 3: row 1, column 2", 1, true), "presses say which interface: " .. admin.chat[#admin.chat])
    server.PropCurveFinder.ClearTestInterface(admin)
    check(not created[1].__valid and not created[2].__valid and not created[3].__valid, "clearing removes all three")

    -- Where's that static prop?
    admin.eye, admin.look = eye, V(1, 0.05, 0):GetNormalized()
    local prop, info = PCF.StaticPropInfo()
    check(prop and prop.model == "models/test/lower.mdl" and info:find("Pos = Vector(-3000.000, 0.000, 0.000)", 1, true), "propcurvefinder_staticprop: " .. tostring(info))
    check(client.clipboard == info, "and copies it")
end)

step("panels touching only at a corner are separate pieces", function()
    local mesh = { triangles = {
        { a = V(0, 0, 0), b = V(10, 0, 0), c = V(10, 10, 0), material = "m" },
        { a = V(0, 0, 0), b = V(10, 10, 0), c = V(0, 10, 0), material = "m" },
        { a = V(10, 10, 0), b = V(20, 10, 0), c = V(20, 20, 0), material = "m" }, -- touches the first square at one corner
        { a = V(10, 10, 0), b = V(20, 20, 0), c = V(10, 20, 0), material = "m" },
        { a = V(50, 0, 0), b = V(60, 0, 0), c = V(60, 10, 0), material = "other" }
    } }
    local pieces = PCF.MaterialPieces(mesh, "m")
    check(#pieces == 2 and #pieces[1] == 2 and #pieces[2] == 2, "two squares, two pieces")
end)

step("an entity: local coordinates follow its angles", function()
    local ent = M.MakeEntity("prop_physics", V(0, 0, 0), A(0, 90, 0), { model = "models/props/screen.mdl", GetSkin = function() return 0 end })
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

step("STM test interface: one window over the whole surface", function()
    M.scene = { M.CylinderStrip(V(0, 0, 0), V(0, 0, 1), V(1, 0, 0), 100, -40, 40, -20, 20) }
    local result = ProbeAt(V(0, 0, 0), V(100, 10, 3))
    check(result.curve and not result.curve.flat and near(result.curve.radius, 100, 0.05), "the probe keeps the exact curve")

    local server = M.NewRealm(true)
    local created, windows = {}, {}
    server.ents = { Create = function(class) local e = M.MakeEntity(class, V(0, 0, 0)) table.insert(created, e) return e end }
    server.Star_Trek = FakeSTM(windows)
    server.include("autorun/propcurvefinder.lua")
    client.Star_Trek = { LCARS = {} }

    -- A non-admin is refused.
    local crew = M.MakeEntity("player", V(0, 0, 0), nil, { admin = false })
    local crewClient = M.NewRealm(false, crew)
    crewClient.include("autorun/propcurvefinder.lua")
    crewClient.PropCurveFinder.RequestTestInterface(result)
    M.Pump(server, crewClient)
    check(#windows == 0 and crew.chat and crew.chat[1]:find("Only admins"), "non-admins are refused")

    PCF.RequestTestInterface(result)
    M.Pump(server, client)
    check(#windows == 1, "one window: " .. #windows)
    local w = windows[1]
    local anchor = created[1]
    check(anchor and anchor.class == "propcurvefinder_anchor" and anchor.spawned, "an anchor entity holds it")
    check(anchor.LCARSKeyData and anchor.LCARSKeyData.lcars_never_close, "and keeps it open")

    -- The window, lifted 0.25 in front of the curve, covers all of it.
    local lifted = 100 - 0.25
    local width, height = lifted * (result.curve.tMax - result.curve.tMin), result.curve.hMax - result.curve.hMin
    check(w.kind == "button_matrix", "an STM button matrix")
    check(near(w.width / w.scale, width, 0.1) and near(w.height / w.scale, height, 0.1), "as wide as the curve (" .. w.width / w.scale .. " of " .. width .. ") and as tall")
    check(w.width == math.floor(w.width) and w.height >= 300, "whole pixels, enough for STM's frame")
    local pos, ang = M.LocalToWorld(w.pos, w.ang, anchor.pos, anchor.ang)
    local mu, mv = PCF.Curve.Hit(result.curve, V(0, 0, 0), pos:GetNormalized())
    check(near(math.sqrt(pos.x ^ 2 + pos.y ^ 2), lifted, 1e-3) and near(mu, 0.5, 1e-6) and near(mv, 0.5, 1e-6),
        "STM's own placement: the middle of the curve (" .. tostring(mu) .. ", " .. tostring(mv) .. ")")
    check(ang:Up():Dot(V(0, 0, 0) - pos) > 0 and near(ang:Up().z, 0, 1e-6), "facing the viewer")

    local rows, cols = #w.rows, #w.rows[1].buttons
    check(rows >= 2 and cols >= 3, "a grid of test buttons: " .. rows .. " x " .. cols)
    w.rows[2].buttons[3].callback(admin)
    check(admin.chat[#admin.chat]:find("row 2, column 3", 1, true), "pressing one says which: " .. tostring(admin.chat[#admin.chat]))

    -- Every client gets the curve, in the anchor's coordinates.
    local curve = PCF.Curved[anchor:EntIndex()]
    check(curve and near(curve.radius, lifted, 1e-3), "the client has the curve")
    local world = PCF.Curve.ToWorld(curve, anchor.pos, anchor.ang)
    check(vnear(world.center, result.curve.center, 1e-3), "back in the world, the same curve")

    -- A late joiner asks for it.
    local late = M.MakeEntity("player", V(0, 0, 0), nil, { admin = false })
    local lateClient = M.NewRealm(false, late)
    lateClient.include("autorun/propcurvefinder.lua")
    lateClient.hook.Run("InitPostEntity")
    M.Pump(server, lateClient)
    check(lateClient.PropCurveFinder.Curved[anchor:EntIndex()] ~= nil, "late joiners get it")

    -- Placing another replaces the first; clearing removes it.
    M.time = M.time + 2
    PCF.RequestTestInterface(result)
    M.Pump(server, client)
    check(not anchor.__valid and created[2] and created[2].__valid, "a new one replaces the old")
    server.PropCurveFinder.ClearTestInterface(admin)
    check(not created[2].__valid and next(server.PropCurveFinder.CurvedAnchors) == nil, "cleared")

    PCF.TestServer, PCF.TestWindow, PCF.TestResult = server, w, result
end)

step("the window drawn round the curve, and your aim mapped onto it", function()
    local Curve = PCF.Curve
    M.scene = { M.CylinderStrip(V(0, 0, 0), V(0, 0, 1), V(1, 0, 0), 100, -40, 40, -20, 20) }
    local result = ProbeAt(V(0, 0, 0), V(100, 10, 3))
    local curve = result.curve

    -- Points and hits agree everywhere.
    local worst = 0
    for _, uv in ipairs({ { 0, 0 }, { 1, 1 }, { 0.25, 0.75 }, { 0.5, 0.5 }, { 0.9, 0.1 } }) do
        local p = Curve.Point(curve, uv[1], uv[2])
        local u, v = Curve.Hit(curve, V(0, 0, 0), p:GetNormalized())
        worst = math.max(worst, math.abs(u - uv[1]), math.abs(v - uv[2]))
    end
    check(worst < 1e-6, "aiming at a point of the curve gives back its place: " .. worst)
    check(Curve.Hit(curve, V(0, 0, 0), V(0, 1, 0)) == nil, "aiming off the curve: nothing")
    local left, right = Curve.Point(curve, 0, 0.5), Curve.Point(curve, 1, 0.5)
    check((right - left):Dot(A(0, 0, 0):Right()) > 0, "u runs left to right as you look at it")
    check(Curve.Point(curve, 0.5, 0).z > Curve.Point(curve, 0.5, 1).z, "v runs top to bottom")

    -- An STM interface on an anchor, with one window.
    local anchor = M.MakeEntity("propcurvefinder_anchor", V(50, 0, 0))
    PCF.Curved[anchor:EntIndex()] = Curve.ToLocal(curve, anchor.pos, anchor.ang)
    local pressed = {}
    local window = { WWidth = 1400, WHeight = 400, RT = { GetName = function() return "LCARS_W_1" end } }
    function window:OnPress(pixel, animPos) table.insert(pressed, pixel) return 7 end
    local interface = { Ent = anchor, IVis = true, AnimPos = 1, Windows = { window } }
    window.Interface = interface
    local stmPresses, rtDraws = 0, 0
    client.Star_Trek = { LCARS = {
        ActiveInterfaces = { [anchor:EntIndex()] = interface },
        PlayerButtonDown = function() stmPresses = stmPresses + 1 end,
        RTDrawWindow = function(_, w) if w == window then rtDraws = rtDraws + 1 end end
    } }

    -- STM's hooks: its drawing and its button handling skip ours; its updates don't.
    check(client.hook.Run("Star_Trek.LCARS.PreventRender", interface) == true, "STM doesn't draw it flat")
    check(client.hook.Run("Star_Trek.LCARS.PreventRender", interface, true) == nil, "but still updates it")
    check(client.hook.Run("Star_Trek.LCARS.PreventButton", interface) == true, "and leaves its buttons to us")
    check(client.hook.Run("Star_Trek.LCARS.PreventRender", { Ent = M.MakeEntity("prop", V(0, 0, 0)) }) == nil, "other interfaces untouched")

    -- Hover: the pixel under your aim.
    M.aim = Curve.Point(curve, 0.25, 0.75):GetNormalized()
    admin.eye = V(0, 0, 0)
    local pixel = client.hook.Run("Star_Trek.LCARS.Get3D2DMousePos", window, V(0, 0, 0))
    check(pixel and near(pixel.x, 350, 1e-3) and near(pixel.y, 300, 1e-3), "hovering: pixel " .. tostring(pixel and pixel.x) .. ", " .. tostring(pixel and pixel.y))
    M.aim = V(0, 1, 0)
    pixel = client.hook.Run("Star_Trek.LCARS.Get3D2DMousePos", window, V(0, 0, 0))
    check(pixel and pixel.x < 0, "aiming away: off the window")

    -- Pressing: through STM's own entry point, which ours wraps.
    client.hook.Run("Think")
    admin.eye = V(40, 0, 0) -- within STM's reach of 80
    M.aim = (Curve.Point(curve, 0.6, 0.2) - admin.eye):GetNormalized()
    client.sent = {}
    client.Star_Trek.LCARS:PlayerButtonDown(admin, client.MOUSE_LEFT)
    check(stmPresses == 1, "STM's own handling still runs (for its other interfaces)")
    check(#pressed == 1 and near(pressed[1].x, 0.6 * 1400, 1e-3) and near(pressed[1].y, 0.2 * 400, 1e-3), "the press lands on the pixel you aimed at")
    local msg = client.sent[#client.sent]
    check(msg and msg.name == "Star_Trek.LCARS.Pressed" and msg.fields[1][2] == anchor:EntIndex() and msg.fields[2][2] == 1 and msg.fields[3][2] == 7,
        "and is sent to STM's server like any press")

    M.aim = (Curve.Point(curve, 0.6, 0.2) - admin.eye):GetNormalized()
    client.Star_Trek.LCARS:PlayerButtonDown(admin, 42) -- some other key
    check(#pressed == 1, "only E and mouse buttons press")
    admin.eye = V(-200, 0, 0) -- too far
    M.aim = (Curve.Point(curve, 0.5, 0.5) - V(-200, 0, 0)):GetNormalized()
    client.Star_Trek.LCARS:PlayerButtonDown(admin, client.MOUSE_LEFT)
    check(#pressed == 1, "too far away: no press")
    admin.eye = V(0, 0, 0)

    -- Drawing: STM fills the render target, then it's wrapped round the curve.
    client.drawn = {}
    client.hook.Run("PostDrawTranslucentRenderables", false, false)
    check(rtDraws == 1, "STM draws the window's contents")
    local drawn = client.drawn[1]
    check(drawn and drawn.count == 48 and #drawn.verts == 48 * 4, "in 48 strips")
    local onCurve, mapped = true, true
    for _, vert in ipairs(drawn and drawn.verts or {}) do
        local localPos = vert.pos - V(0, 0, 0)
        if not near(math.sqrt(localPos.x ^ 2 + localPos.y ^ 2), 100, 0.1) then onCurve = false end
        local u, v = Curve.Hit(curve, V(0, 0, 0), vert.pos:GetNormalized())
        if not (u and near(u, vert.u, 1e-6) and near(v, vert.v, 1e-6)) then mapped = false end
    end
    check(onCurve, "every corner on the curve")
    check(mapped, "every corner shows the part of the window your aim maps there")

    PCF.Curved[anchor:EntIndex()] = nil
    client.Star_Trek = nil
    for i = #M.netQueue, 1, -1 do M.netQueue[i] = nil end -- the press went to STM, not here
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
    server.Star_Trek = FakeSTM({})
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
