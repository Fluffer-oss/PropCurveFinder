PropCurveFinder = PropCurveFinder or {}
local PCF = PropCurveFinder
local Curve = {}
PCF.Curve = Curve

-- A measured surface as a screen: u runs 0..1 left to right, v 0..1 top to
-- bottom. Either a strip of a cylinder (center, axis, e1, e2: angles measured
-- from e1 towards e2; radius; concave; angles tMin..tMax; heights hMin..hMax
-- along the axis) or a flat rectangle (flat = true: center, normal, right, up,
-- width, height).

-- Width (along the surface) and height.
function Curve.Size(c)
    if c.flat then return c.width, c.height end
    return c.radius * (c.tMax - c.tMin), c.hMax - c.hMin
end

-- The point at (u, v), the surface's normal there (facing the viewer) and its
-- right and up directions.
function Curve.Point(c, u, v)
    if c.flat then
        local pos = c.center + c.right * ((u - 0.5) * c.width) + c.up * ((0.5 - v) * c.height)
        return pos, c.normal, c.right, c.up
    end
    local t = c.tMin + (c.tMax - c.tMin) * u
    local h = c.hMax - (c.hMax - c.hMin) * v
    local radial = c.e1 * math.cos(t) + c.e2 * math.sin(t)
    local normal = c.concave and -radial or radial
    return c.center + radial * c.radius + c.axis * h, normal, c.axis:Cross(normal):GetNormalized(), c.axis
end

local EDGE = 1e-9 -- rounding at the very edges still counts as on the surface

-- Where a ray from `origin` along unit `dir` meets the surface: u, v and the
-- distance, or nil if it misses.
function Curve.Hit(c, origin, dir)
    if c.flat then
        local denom = dir:Dot(c.normal)
        if math.abs(denom) < 1e-9 then return nil end
        local t = (c.center - origin):Dot(c.normal) / denom
        if t <= 0 then return nil end
        local d = origin + dir * t - c.center
        local u, v = d:Dot(c.right) / c.width + 0.5, 0.5 - d:Dot(c.up) / c.height
        if u < -EDGE or u > 1 + EDGE or v < -EDGE or v > 1 + EDGE then return nil end
        return math.Clamp(u, 0, 1), math.Clamp(v, 0, 1), t
    end

    local s = origin - c.center
    local sx, sy, sh = s:Dot(c.e1), s:Dot(c.e2), s:Dot(c.axis)
    local dx, dy, dh = dir:Dot(c.e1), dir:Dot(c.e2), dir:Dot(c.axis)
    local a = dx * dx + dy * dy
    if a < 1e-12 then return nil end
    local b = 2 * (sx * dx + sy * dy)
    local k = sx * sx + sy * sy - c.radius * c.radius
    local disc = b * b - 4 * a * k
    if disc < 0 then return nil end
    for _, t in ipairs({ (-b - math.sqrt(disc)) / (2 * a), (-b + math.sqrt(disc)) / (2 * a) }) do
        if t > 0 then
            local angle = math.atan2(sy + dy * t, sx + dx * t)
            local h = sh + dh * t
            local u, v = (angle - c.tMin) / (c.tMax - c.tMin), (c.hMax - h) / (c.hMax - c.hMin)
            if u >= -EDGE and u <= 1 + EDGE and v >= -EDGE and v <= 1 + EDGE then
                return math.Clamp(u, 0, 1), math.Clamp(v, 0, 1), t
            end
        end
    end
    return nil
end

-- The curve moved into or out of a frame (pos, ang): positions are moved,
-- directions only turned.
local function Transform(c, point, direction)
    local out = {}
    for k, value in pairs(c) do out[k] = value end
    out.center = point(c.center)
    for _, key in ipairs({ "axis", "e1", "e2", "normal", "right", "up" }) do
        if c[key] then out[key] = direction(c[key]) end
    end
    return out
end

function Curve.ToLocal(c, pos, ang)
    local zero = Angle(0, 0, 0)
    return Transform(c,
        function(p) return (WorldToLocal(p, zero, pos, ang)) end,
        function(d) return (WorldToLocal(d, zero, Vector(0, 0, 0), ang)) end)
end

function Curve.ToWorld(c, pos, ang)
    local zero = Angle(0, 0, 0)
    return Transform(c,
        function(p) return (LocalToWorld(p, zero, pos, ang)) end,
        function(d) return (LocalToWorld(d, zero, Vector(0, 0, 0), ang)) end)
end

-- Network a curve.
function Curve.Write(c)
    net.WriteBool(c.flat == true)
    net.WriteVector(c.center)
    if c.flat then
        net.WriteVector(c.normal)
        net.WriteVector(c.right)
        net.WriteVector(c.up)
        net.WriteFloat(c.width)
        net.WriteFloat(c.height)
    else
        net.WriteVector(c.axis)
        net.WriteVector(c.e1)
        net.WriteVector(c.e2)
        net.WriteFloat(c.radius)
        net.WriteBool(c.concave == true)
        net.WriteFloat(c.tMin)
        net.WriteFloat(c.tMax)
        net.WriteFloat(c.hMin)
        net.WriteFloat(c.hMax)
    end
end

function Curve.Read()
    local c = { flat = net.ReadBool(), center = net.ReadVector() }
    if c.flat then
        c.normal, c.right, c.up = net.ReadVector(), net.ReadVector(), net.ReadVector()
        c.width, c.height = net.ReadFloat(), net.ReadFloat()
    else
        c.axis, c.e1, c.e2 = net.ReadVector(), net.ReadVector(), net.ReadVector()
        c.radius, c.concave = net.ReadFloat(), net.ReadBool()
        c.tMin, c.tMax, c.hMin, c.hMax = net.ReadFloat(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
    end
    return c
end

-- Whether a curve is sane enough to build on (sizes, numbers).
function Curve.Valid(c)
    local function finite(x) return type(x) == "number" and x == x and x > -1e7 and x < 1e7 end
    local w, h = Curve.Size(c)
    if not (finite(w) and finite(h) and w > 0.5 and w < 4096 and h > 0.5 and h < 4096) then return false end
    if not c.flat and not (finite(c.radius) and c.radius > 0.5 and c.tMax > c.tMin and c.tMax - c.tMin <= 2 * math.pi) then return false end
    return true
end
