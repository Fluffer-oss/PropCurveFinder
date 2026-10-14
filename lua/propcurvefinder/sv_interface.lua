PropCurveFinder = PropCurveFinder or {}
local PCF = PropCurveFinder

util.AddNetworkString("PropCurveFinder.Probe")
util.AddNetworkString("PropCurveFinder.Clear")
util.AddNetworkString("PropCurveFinder.Reopen")
util.AddNetworkString("PropCurveFinder.TestInterface")
util.AddNetworkString("PropCurveFinder.ClearRequest")
util.AddNetworkString("PropCurveFinder.Curved")
util.AddNetworkString("PropCurveFinder.CurvedSync")

local adminOnly = CreateConVar("propcurvefinder_interface_adminonly", "1", FCVAR_ARCHIVE,
    "Only admins can place PropCurveFinder's STM test interfaces.")

local INTERFACE_NAME = "propcurvefinder_test"

-- STM test interface: one window covering the whole surface, full of test
-- buttons. Clients draw it wrapped round the curve and map your aim onto it
-- (cl_curved.lua). Pressing a button says which row and column you pressed,
-- so you can check it takes clicks exactly where it's drawn.
local function RegisterInterface()
    local lcars = Star_Trek and Star_Trek.LCARS
    if not (lcars and lcars.Interfaces and lcars.Interfaces.base) then return false end

    local interface = { Class = INTERFACE_NAME, IsLCARSInterface = true, BaseInterface = "base", LogType = false }
    interface.Base = lcars.Interfaces.base
    setmetatable(interface, { __index = lcars.Interfaces.base })

    -- curve: in the entity's own coordinates.
    function interface:Open(ent, curve)
        local Curve = PCF.Curve
        local width, height = Curve.Size(curve)
        -- Enough pixels for STM's frame and buttons, without a huge render target.
        local scale = math.max(20, 300 / height, 300 / width)
        scale = math.min(scale, 120, 4096 / width, 4096 / height)
        local widthPx, heightPx = math.floor(width * scale), math.floor(height * scale)

        -- STM places the window flat at the middle of the surface; it's drawn wrapped round it.
        local worldCurve = Curve.ToWorld(curve, ent:GetPos(), ent:GetAngles())
        local pos, normal, right = Curve.Point(worldCurve, 0.5, 0.5)
        local localPos, localAng = WorldToLocal(pos, right:AngleEx(normal), ent:GetPos(), ent:GetAngles())

        local ok, window = lcars:CreateWindow("button_matrix", localPos, localAng, scale, widthPx, heightPx,
            function() end, "PROPCURVEFINDER TEST", "PCF", false)
        if not ok then return false, window end

        local rows = math.Clamp(math.floor((heightPx - 120) / 40), 1, 10)
        local columns = math.Clamp(math.floor(widthPx / 150), 1, 16)
        for r = 1, rows do
            local row = window:CreateMainButtonRow(32)
            for c = 1, columns do
                window:AddButtonToRow(row, "R" .. r .. " C" .. c, nil, nil, nil, false, false, function(ply)
                    if IsValid(ply) then
                        ply:ChatPrint(string.format("[PropCurveFinder] row %d, column %d (of %d x %d)", r, c, rows, columns))
                    end
                end)
            end
        end
        return true, { window }
    end

    lcars.Interfaces[INTERFACE_NAME] = interface
    return true
end
hook.Add("Star_Trek.ModulesLoaded", "PropCurveFinder.Interface", RegisterInterface)

local lastRequest = {}

-- anchor -> its curve (in the anchor's coordinates), for every client to draw.
PCF.CurvedAnchors = PCF.CurvedAnchors or {}

local function SendCurve(anchor, curve, target)
    net.Start("PropCurveFinder.Curved")
    net.WriteEntity(anchor)
    PCF.Curve.Write(curve)
    if target then net.Send(target) else net.Broadcast() end
end

net.Receive("PropCurveFinder.TestInterface", function(_, ply)
    if not IsValid(ply) then return end
    local function Reply(text) ply:ChatPrint("[PropCurveFinder] " .. text) end

    if adminOnly:GetBool() and not ply:IsAdmin() then return Reply("Only admins can place test interfaces.") end
    if (lastRequest[ply] or 0) > CurTime() - 1 then return end
    lastRequest[ply] = CurTime()

    local target = net.ReadEntity()
    local curve = PCF.Curve.Read()
    if not PCF.Curve.Valid(curve) then return Reply("That surface is the wrong size for an interface.") end
    local middle = PCF.Curve.Point(curve, 0.5, 0.5)
    if middle:Distance(ply:GetPos()) > 4096 then return Reply("That surface is too far away.") end

    if not RegisterInterface() then return Reply("Star Trek Modules' LCARS isn't loaded.") end

    -- An invisible anchor for the interface, on the moving prop if it's one.
    PCF.ClearTestInterface(ply)
    local anchor = ents.Create("propcurvefinder_anchor")
    anchor:SetPos(middle)
    anchor:SetAngles(Angle(0, 0, 0))
    anchor:Spawn()
    if IsValid(target) then anchor:SetParent(target) end
    anchor.LCARSKeyData = { lcars_never_close = true }
    ply.PropCurveFinderAnchor = anchor

    local localCurve = PCF.Curve.ToLocal(curve, anchor:GetPos(), anchor:GetAngles())
    PCF.CurvedAnchors[anchor] = localCurve
    SendCurve(anchor, localCurve)

    local ok, err = Star_Trek.LCARS:OpenInterface(ply, anchor, INTERFACE_NAME, localCurve)
    if not ok then
        PCF.ClearTestInterface(ply)
        return Reply("Couldn't open the interface: " .. tostring(err))
    end
    Reply("Test interface placed. Clear it with propcurvefinder_clear (or the weapon's secondary fire).")
end)

-- Late joiners get the curves of the interfaces already up.
net.Receive("PropCurveFinder.CurvedSync", function(_, ply)
    for anchor, curve in pairs(PCF.CurvedAnchors) do
        if IsValid(anchor) then SendCurve(anchor, curve, ply) else PCF.CurvedAnchors[anchor] = nil end
    end
end)

function PCF.ClearTestInterface(ply)
    local anchor = ply.PropCurveFinderAnchor
    if anchor then PCF.CurvedAnchors[anchor] = nil end
    if IsValid(anchor) then anchor:Remove() end
    ply.PropCurveFinderAnchor = nil
end

hook.Add("PlayerDisconnected", "PropCurveFinder.Anchor", PCF.ClearTestInterface)

net.Receive("PropCurveFinder.ClearRequest", function(_, ply)
    if IsValid(ply) then PCF.ClearTestInterface(ply) end
end)
