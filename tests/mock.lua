-- Minimal Garry's Mod environment for running the addon in plain Lua 5.1, with
-- Source's angle conventions and a scene of exact surfaces to trace against.

local M = {}
local ADDON_LUA = HARNESS_DIR .. "../lua/"

function math.Clamp(v, lo, hi) return math.min(math.max(v, lo), hi) end

---------------------------------------------------------------- Vector
local VEC = {}
VEC.__index = VEC
local function Vector(x, y, z)
    if type(x) == "table" then return setmetatable({ x = x.x, y = x.y, z = x.z }, VEC) end
    return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VEC)
end
VEC.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
VEC.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
VEC.__unm = function(a) return Vector(-a.x, -a.y, -a.z) end
VEC.__mul = function(a, b) if type(a) == "number" then a, b = b, a end return Vector(a.x * b, a.y * b, a.z * b) end
function VEC:Dot(o) return self.x * o.x + self.y * o.y + self.z * o.z end
function VEC:Cross(o) return Vector(self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x) end
function VEC:Length() return math.sqrt(self:Dot(self)) end
function VEC:DistToSqr(o) local d = self - o return d:Dot(d) end
function VEC:Distance(o) return (self - o):Length() end
function VEC:GetNormalized() local l = self:Length() if l == 0 then return Vector(0, 0, 0) end return self * (1 / l) end

---------------------------------------------------------------- Angle (Source conventions)
local ANG = {}
ANG.__index = ANG
local function Angle(p, y, r) return setmetatable({ p = p or 0, y = y or 0, r = r or 0 }, ANG) end
local function Basis(a)
    local rad = math.pi / 180
    local sp, cp = math.sin(a.p * rad), math.cos(a.p * rad)
    local sy, cy = math.sin(a.y * rad), math.cos(a.y * rad)
    local sr, cr = math.sin(a.r * rad), math.cos(a.r * rad)
    local forward = Vector(cp * cy, cp * sy, -sp)
    local right = Vector(-sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp)
    local up = Vector(cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp)
    return forward, right, up
end
function ANG:Forward() return (Basis(self)) end
function ANG:Right() local _, r = Basis(self) return r end
function ANG:Up() local _, _, u = Basis(self) return u end

-- The angle whose forward is this vector and whose up is `up`.
function VEC:AngleEx(up)
    local f = self:GetNormalized()
    local pitch = math.deg(math.atan2(-f.z, math.sqrt(f.x * f.x + f.y * f.y)))
    local yaw = math.deg(math.atan2(f.y, f.x))
    local _, right0, up0 = Basis(Angle(pitch, yaw, 0))
    local roll = math.deg(math.atan2(up:Dot(right0), up:Dot(up0)))
    return Angle(pitch, yaw, roll)
end

-- Source local space: x forward, y left, z up.
local function ToLocalVec(d, ang)
    local f, r, u = Basis(ang)
    return Vector(d:Dot(f), -d:Dot(r), d:Dot(u))
end
local function ToWorldVec(l, ang)
    local f, r, u = Basis(ang)
    return f * l.x - r * l.y + u * l.z
end
local function WorldToLocal(pos, ang, origin, angles)
    local lp = ToLocalVec(pos - origin, angles)
    local f, _, u = Basis(ang)
    return lp, ToLocalVec(f, angles):AngleEx(ToLocalVec(u, angles))
end
local function LocalToWorld(lpos, lang, origin, angles)
    local wp = origin + ToWorldVec(lpos, angles)
    local f, _, u = Basis(lang)
    return wp, ToWorldVec(f, angles):AngleEx(ToWorldVec(u, angles))
end
M.Vector, M.Angle, M.WorldToLocal, M.LocalToWorld = Vector, Angle, WorldToLocal, LocalToWorld

---------------------------------------------------------------- Scene
-- M.scene = list of surfaces: { Intersect = function(start, dir, maxT) -> t, normal }, plus
-- entity = Entity or nil, texture = "..." ("**studio**" for static props).
M.scene = {}
M.traces = 0

local function Trace(data)
    M.traces = M.traces + 1
    local start, stop = data.start, data.endpos
    local delta = stop - start
    local length = delta:Length()
    local dir = delta * (1 / length)
    local best, bestT, bestN
    for _, surface in ipairs(M.scene) do
        local t, n = surface.Intersect(start, dir, length)
        if t and t >= 0 and t <= length and (not bestT or t < bestT) then best, bestT, bestN = surface, t, n end
    end
    if not best then
        return { Hit = false, HitPos = stop, HitNormal = Vector(0, 0, 0), Fraction = 1, HitWorld = false, StartSolid = false }
    end
    if bestN:Dot(dir) > 0 then bestN = -bestN end -- facing the ray, as Source reports it
    return {
        Hit = true, HitPos = start + dir * bestT, HitNormal = bestN, Fraction = bestT / length,
        Entity = best.entity or M.world, HitWorld = best.entity == nil, HitTexture = best.texture or "maps/wall",
        StartSolid = false, HitSky = false
    }
end
M.Trace = Trace

-- A curved strip of a cylinder (axis through `center` along `axis`): angles
-- [a1, a2] (degrees, measured from `zero` towards axis x zero), heights [h1, h2].
function M.CylinderStrip(center, axis, zero, radius, a1, a2, h1, h2)
    local e1 = zero:GetNormalized()
    local e2 = axis:Cross(e1)
    return { Intersect = function(start, dir, maxT)
        local s = start - center
        local sx, sy, sh = s:Dot(e1), s:Dot(e2), s:Dot(axis)
        local dx, dy, dh = dir:Dot(e1), dir:Dot(e2), dir:Dot(axis)
        local a = dx * dx + dy * dy
        if a < 1e-12 then return nil end
        local b = 2 * (sx * dx + sy * dy)
        local c = sx * sx + sy * sy - radius * radius
        local disc = b * b - 4 * a * c
        if disc < 0 then return nil end
        local roots = { (-b - math.sqrt(disc)) / (2 * a), (-b + math.sqrt(disc)) / (2 * a) }
        for _, t in ipairs(roots) do
            if t >= 0 and t <= maxT then
                local x, y, h = sx + dx * t, sy + dy * t, sh + dh * t
                local ang = math.deg(math.atan2(y, x))
                if ang >= a1 and ang <= a2 and h >= h1 and h <= h2 then
                    return t, (e1 * x + e2 * y):GetNormalized()
                end
            end
        end
    end }
end

-- A flat rectangle: center, normal, right and up half-extents.
function M.Rect(center, normal, right, up, halfW, halfH)
    return { Intersect = function(start, dir, maxT)
        local denom = dir:Dot(normal)
        if math.abs(denom) < 1e-12 then return nil end
        local t = (center - start):Dot(normal) / denom
        if t < 0 or t > maxT then return nil end
        local d = start + dir * t - center
        if math.abs(d:Dot(right)) <= halfW and math.abs(d:Dot(up)) <= halfH then return t, normal end
    end }
end

-- A spherical cap: within `maxAngle` degrees of direction `pole` from `center`.
function M.SphereCap(center, radius, pole, maxAngle)
    return { Intersect = function(start, dir, maxT)
        local s = start - center
        local b = 2 * s:Dot(dir)
        local c = s:Dot(s) - radius * radius
        local disc = b * b - 4 * c
        if disc < 0 then return nil end
        for _, t in ipairs({ (-b - math.sqrt(disc)) / 2, (-b + math.sqrt(disc)) / 2 }) do
            if t >= 0 and t <= maxT then
                local p = s + dir * t
                if math.deg(math.acos(math.Clamp(p:GetNormalized():Dot(pole), -1, 1))) <= maxAngle then
                    return t, p:GetNormalized()
                end
            end
        end
    end }
end

---------------------------------------------------------------- Realms
M.files = {}
M.convars = {}
M.time = 100

function M.MakeEntity(class, pos, ang, extra)
    local e = { __valid = true, class = class, pos = pos, ang = ang or Angle(0, 0, 0), sounds = {} }
    function e:GetClass() return self.class end
    function e:GetModel() return self.model end
    function e:GetPos() return self.pos end
    function e:GetAngles() return self.ang end
    function e:IsWorld() return self.class == "worldspawn" end
    function e:IsPlayer() return self.class == "player" end
    function e:SetPos(p) self.pos = p end
    function e:SetAngles(a) self.ang = a end
    function e:SetParent(p) self.parent = p end
    function e:Spawn() self.spawned = true end
    function e:Remove() self.__valid = false end
    function e:EmitSound(s) table.insert(self.sounds, s) end
    function e:IsAdmin() return self.admin == true end
    function e:ChatPrint(m) self.chat = self.chat or {} table.insert(self.chat, m) end
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end
M.world = M.MakeEntity("worldspawn", Vector(0, 0, 0))

local NetQueue = {}
M.netQueue = NetQueue

function M.NewRealm(isServer, localPlayer)
    local env = setmetatable({}, { __index = _G })
    env._G = env
    env.SERVER, env.CLIENT = isServer, not isServer
    env.Vector, env.Angle, env.WorldToLocal, env.LocalToWorld = Vector, Angle, WorldToLocal, LocalToWorld
    env.IsValid = function(v) return type(v) == "table" and rawget(v, "__valid") == true end
    env.NULL = { __valid = false }
    env.CurTime = function() return M.time end
    env.Color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end
    env.include = function(path)
        local chunk = assert(loadfile(ADDON_LUA .. path))
        setfenv(chunk, env)
        return chunk()
    end
    env.AddCSLuaFile = function() end
    env.util = {
        TraceLine = function(data)
            assert(data.filter == localPlayer, "traces should ignore the player")
            return Trace(data)
        end,
        AddNetworkString = function(name) env.netStrings = env.netStrings or {} env.netStrings[name] = true end
    }
    env.game = { GetMap = function() return "rp_test" end }
    env.file = { Open = function(path, mode, where)
        assert(mode == "rb" and where == "GAME")
        local data = M.files[path]
        if not data then return nil end
        local pos = 0
        return {
            Read = function(_, n) local chunk = data:sub(pos + 1, pos + n) pos = pos + #chunk return chunk end,
            Seek = function(_, p) pos = p end,
            Close = function() end
        }
    end }
    env.GetConVar = function(name)
        if M.convars[name] == nil then return nil end
        return { GetFloat = function() return M.convars[name] end, GetBool = function() return M.convars[name] ~= 0 end }
    end
    env.CreateConVar = function(name, default)
        M.convars[name] = M.convars[name] or tonumber(default)
        return env.GetConVar(name)
    end
    env.LocalPlayer = function() return localPlayer end
    env.MsgN = function(...) env.printed = table.concat({ ... }) end
    env.print = function(...) env.lastPrint = table.concat({ ... }, " ") end
    env.commands = {}
    env.concommand = { Add = function(name, fn) env.commands[name] = fn end }
    env.CreateClientConVar = function(name, default)
        assert(not isServer, "client convars are created on the client")
        if M.convars[name] == nil then M.convars[name] = tonumber(default) end
        env.clientConVars = env.clientConVars or {}
        env.clientConVars[name] = default
        return env.GetConVar(name)
    end
    env.notification = { AddLegacy = function(text) env.notified = text end }
    env.ScrW, env.ScrH = function() return 1920 end, function() return 1080 end
    env.SetClipboardText = function(text) env.clipboard = text end
    -- Windows: every method is accepted and does nothing; created panels are recorded.
    env.panels = {}
    env.vgui = { Create = function(class)
        local panel = { class = class, __valid = true }
        setmetatable(panel, { __index = function(_, key)
            if key == "Remove" then return function(self) self.__valid = false end end
            if key == "Close" then return function(self) self.__valid = false end end
            return function() end
        end })
        table.insert(env.panels, panel)
        return panel
    end }

    local hooks = {}
    env.hook = {
        Add = function(e, n, f) hooks[e] = hooks[e] or {} hooks[e][n] = f end,
        Run = function(e, ...) for _, f in pairs(hooks[e] or {}) do f(...) end end
    }

    -- net: messages are lists of typed fields.
    local out, inc
    local receivers = {}
    env.net = { Receive = function(n, f) receivers[n] = f end, Start = function(n) out = { name = n, fields = {} } end }
    for _, kind in ipairs({ "Entity", "UInt", "Vector", "Angle", "Float" }) do
        env.net["Write" .. kind] = function(v) table.insert(out.fields, { kind, v }) end
        env.net["Read" .. kind] = function()
            local f = table.remove(inc.fields, 1)
            assert(f and f[1] == kind, "net read " .. kind .. " but got " .. tostring(f and f[1]))
            return f[2]
        end
    end
    env.net.SendToServer = function() table.insert(NetQueue, { msg = out, sender = localPlayer, toServer = true }) end
    env.net.Send = function(ply) table.insert(NetQueue, { msg = out, target = ply }) end
    env.receivers = receivers
    env.__deliver = function(msg, sender)
        inc = { name = msg.name, fields = { unpack(msg.fields) } }
        assert(receivers[msg.name], "no receiver for " .. msg.name)(0, sender)
    end
    return env
end

-- Delivers queued net messages: to the server, or to the client realm.
function M.Pump(server, client)
    while #NetQueue > 0 do
        local item = table.remove(NetQueue, 1)
        if item.toServer then server.__deliver(item.msg, item.sender) else client.__deliver(item.msg) end
    end
end

---------------------------------------------------------------- binary files
local function I32(v)
    if v < 0 then v = v + 4294967296 end
    local b = {}
    for i = 1, 4 do b[i] = string.char(v % 256) v = math.floor(v / 256) end
    return table.concat(b)
end
local function U16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function F32(x)
    if x == 0 then return "\0\0\0\0" end
    local sign = x < 0 and 1 or 0
    local m, e = math.frexp(math.abs(x))
    local bits = sign * 2147483648 + (e - 1 + 127) * 8388608 + math.floor((m * 2 - 1) * 8388608 + 0.5)
    return I32(bits >= 2147483648 and bits - 4294967296 or bits)
end
local function Pad(s, n) return s .. string.rep("\0", n - #s) end

-- A map with only static props: { model, pos = Vector, ang = Angle }.
function M.MapWithStaticProps(props)
    local models, index = {}, {}
    for _, p in ipairs(props) do
        if not index[p.model] then table.insert(models, p.model) index[p.model] = #models - 1 end
    end
    local sprp = { I32(#models) }
    for _, m in ipairs(models) do table.insert(sprp, Pad(m, 128)) end
    table.insert(sprp, I32(0))
    table.insert(sprp, I32(#props))
    for _, p in ipairs(props) do
        table.insert(sprp, Pad(F32(p.pos.x) .. F32(p.pos.y) .. F32(p.pos.z) .. F32(p.ang.p) .. F32(p.ang.y) .. F32(p.ang.r) .. U16(index[p.model]), 76))
    end
    local sprpBytes = table.concat(sprp)
    local headerSize = 8 + 64 * 16
    local gameLump = I32(1) .. I32(0x73707270) .. U16(0) .. U16(10) .. I32(headerSize + 4 + 16) .. I32(#sprpBytes)
    local dir = {}
    for i = 0, 63 do
        dir[#dir + 1] = i == 35 and (I32(headerSize) .. I32(#gameLump) .. I32(0) .. "\0\0\0\0") or string.rep("\0", 16)
    end
    return "VBSP" .. I32(20) .. table.concat(dir) .. gameLump .. sprpBytes
end

-- A model header with view box mins/maxs.
function M.Model(mins, maxs)
    local function V3(v) return F32(v.x) .. F32(v.y) .. F32(v.z) end
    return "IDST" .. I32(48) .. string.rep("\0", 120) .. V3(mins) .. V3(maxs) .. V3(mins) .. V3(maxs) .. string.rep("\0", 100)
end

return M
