PropCurveFinder = PropCurveFinder or {}
local PCF = PropCurveFinder

util.AddNetworkString("PropCurveFinder.Probe")
util.AddNetworkString("PropCurveFinder.Clear")
util.AddNetworkString("PropCurveFinder.Reopen")
util.AddNetworkString("PropCurveFinder.TestInterface")

local adminOnly = CreateConVar("propcurvefinder_interface_adminonly", "1", FCVAR_ARCHIVE,
    "Only admins can place PropCurveFinder's STM test interfaces.")

local INTERFACE_NAME = "propcurvefinder_test"
local MAX_SEGMENTS = 64

-- STM test interface: one button list window per segment. Pressing a button
-- says which segment and button you pressed, so you can check that each window
-- sits on the surface and takes clicks where it's drawn.
local function RegisterInterface()
    local lcars = Star_Trek and Star_Trek.LCARS
    if not (lcars and lcars.Interfaces and lcars.Interfaces.base) then return false end

    local interface = { Class = INTERFACE_NAME, IsLCARSInterface = true, BaseInterface = "base", LogType = false }
    interface.Base = lcars.Interfaces.base
    setmetatable(interface, { __index = lcars.Interfaces.base })

    function interface:Open(ent, segments)
        local scale = 20
        for _, seg in ipairs(segments) do
            -- Big enough in pixels for STM's window frame and a button or two.
            scale = math.max(scale, 180 / seg.width, 160 / seg.height)
        end
        scale = math.min(scale, 120)

        local windows = {}
        for i, seg in ipairs(segments) do
            local pos, ang = WorldToLocal(seg.pos, seg.ang, ent:GetPos(), ent:GetAngles())
            local width, height = seg.width * scale, seg.height * scale
            local buttons = {}
            for b = 1, math.Clamp(math.floor((height - 80) / 35), 1, 8) do
                buttons[b] = { Name = "S" .. i .. " B" .. b }
            end
            local ok, window = lcars:CreateWindow("button_list", pos, ang, scale, width, height,
                function(_, _, ply, buttonId)
                    ent:EmitSound("star_trek.lcars_beep")
                    if IsValid(ply) then
                        ply:ChatPrint(string.format("[PropCurveFinder] segment %d of %d, button %d", i, #segments, buttonId))
                    end
                end,
                buttons, "SEGMENT " .. i, tostring(i), false)
            if not ok then return false, window end
            windows[i] = window
        end
        return true, windows
    end

    lcars.Interfaces[INTERFACE_NAME] = interface
    return true
end
hook.Add("Star_Trek.ModulesLoaded", "PropCurveFinder.Interface", RegisterInterface)

local lastRequest = {}

net.Receive("PropCurveFinder.TestInterface", function(_, ply)
    if not IsValid(ply) then return end
    local function Reply(text) ply:ChatPrint("[PropCurveFinder] " .. text) end

    if adminOnly:GetBool() and not ply:IsAdmin() then return Reply("Only admins can place test interfaces.") end
    if (lastRequest[ply] or 0) > CurTime() - 1 then return end
    lastRequest[ply] = CurTime()

    local target = net.ReadEntity()
    local count = net.ReadUInt(7)
    if count < 1 or count > MAX_SEGMENTS then return end
    local segments = {}
    for i = 1, count do
        local seg = { pos = net.ReadVector(), ang = net.ReadAngle(), width = net.ReadFloat(), height = net.ReadFloat() }
        if seg.pos:Distance(ply:GetPos()) > 4096 or not (seg.width > 0.5 and seg.width < 4096 and seg.height > 0.5 and seg.height < 4096) then
            return Reply("That surface is too far away or the wrong size.")
        end
        segments[i] = seg
    end

    if not RegisterInterface() then return Reply("Star Trek Modules' LCARS isn't loaded.") end

    -- An invisible anchor for the interface, on the moving prop if it's one.
    if IsValid(ply.PropCurveFinderAnchor) then ply.PropCurveFinderAnchor:Remove() end
    local anchor = ents.Create("propcurvefinder_anchor")
    anchor:SetPos(segments[math.ceil(count / 2)].pos)
    anchor:SetAngles(Angle(0, 0, 0))
    anchor:Spawn()
    if IsValid(target) then anchor:SetParent(target) end
    anchor.LCARSKeyData = { lcars_never_close = true }
    ply.PropCurveFinderAnchor = anchor

    local ok, err = Star_Trek.LCARS:OpenInterface(ply, anchor, INTERFACE_NAME, segments)
    if not ok then
        anchor:Remove()
        return Reply("Couldn't open the interface: " .. tostring(err))
    end
    Reply(string.format("Test interface with %d window%s. Clear it with the tool's right click.", count, count == 1 and "" or "s"))
end)

function PCF.ClearTestInterface(ply)
    if IsValid(ply.PropCurveFinderAnchor) then ply.PropCurveFinderAnchor:Remove() end
    ply.PropCurveFinderAnchor = nil
end

hook.Add("PlayerDisconnected", "PropCurveFinder.Anchor", PCF.ClearTestInterface)
