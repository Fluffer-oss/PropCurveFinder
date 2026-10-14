PropCurveFinder = PropCurveFinder or {}
local PCF = PropCurveFinder
local Mth = PCF.Math

-- Probing a surface: what was hit, how far the surface goes in each direction
-- (walking along it until it ends), what shape it is, and a layout of flat
-- segments that follow it, ready for cam.Start3D2D or STM windows.

local function Setting(name, default)
    local cvar = GetConVar("propcurvefinder_" .. name)
    return cvar and cvar:GetFloat() or default
end
PCF.Setting = Setting

local function Trace(from, to)
    return util.TraceLine({ start = from, endpos = to, filter = LocalPlayer() })
end

-- What a trace hit, and how to tell whether another trace hit the same thing.
function PCF.IdentifyTarget(tr)
    local ent = tr.Entity
    if IsValid(ent) and not ent:IsWorld() then
        return {
            type = "entity", ent = ent, class = ent:GetClass(), model = ent:GetModel(),
            pos = ent:GetPos(), ang = ent:GetAngles(),
            Same = function(other) return other.Entity == ent end
        }
    end

    if tr.HitWorld and tr.HitTexture == "**studio**" then
        local prop = PCF.FindStaticProp(tr.HitPos)
        if prop then
            return {
                type = "static_prop", index = prop.index, model = prop.model, pos = prop.pos, ang = prop.ang,
                Same = function(other)
                    return other.HitWorld and other.HitTexture == "**studio**" and PCF.InStaticProp(prop, other.HitPos, 2)
                end
            }
        end
        -- The map's static prop list couldn't be read (or this prop isn't in it).
        return {
            type = "static_prop_unknown",
            Same = function(other) return other.HitWorld and other.HitTexture == "**studio**" end
        }
    end

    local texture = tr.HitTexture
    local byTexture = Setting("texturestop", 1) ~= 0
    return {
        type = "world", texture = texture,
        Same = function(other)
            return other.HitWorld and other.HitTexture ~= "**studio**" and (not byTexture or other.HitTexture == texture)
        end
    }
end

-- Walks along the surface from `pos` in tangent direction `dir` until it ends.
-- Returns the points (with normals) and why it stopped.
function PCF.March(target, pos, normal, dir)
    local step = math.max(0.25, Setting("step", 2))
    local maxDistance = Setting("maxdistance", 512)
    local maxBend = Setting("maxbend", 30)

    local path = {}
    local p, n, d = pos, normal, dir
    for _ = 1, math.floor(maxDistance / step) do
        local guess = p + d * step
        local reach = step * 2 + 4
        local tr = Trace(guess + n * reach, guess - n * reach)
        if not tr.Hit or tr.StartSolid then return path, "ran off the surface" end
        if not target.Same(tr) then return path, "reached a different surface" end
        local bend = math.deg(math.acos(math.Clamp(tr.HitNormal:Dot(n), -1, 1)))
        if bend > maxBend then return path, string.format("bent %.0f degrees", bend) end
        local moved = tr.HitPos - p
        if moved:Length() > step * 3 then return path, "the surface jumped" end

        -- Carry on in the direction we actually moved, along the new surface.
        local nn = tr.HitNormal
        local along = moved - nn * moved:Dot(nn)
        if along:Length() < 1e-6 then return path, "stuck" end
        d = along:GetNormalized()
        p, n = tr.HitPos, nn
        table.insert(path, { pos = p, normal = n })
    end
    return path, "reached the maximum distance"
end

local function Unit(v) return v:GetNormalized() end

-- Screen-space basis at the hit: up (world up along the surface, or where
-- you're looking for floors and ceilings) and right (as you look at it).
local function HitBasis(normal, eyeForward)
    local up = Vector(0, 0, 1) - normal * normal.z
    if up:Length() < 0.1 then up = eyeForward - normal * eyeForward:Dot(normal) end
    up = Unit(up)
    return up, Unit(up:Cross(normal))
end

-- Probes the surface a trace hit. Returns a result table (see README).
function PCF.Probe(tr, eyeForward)
    local target = PCF.IdentifyTarget(tr)
    local p0, n0 = tr.HitPos, tr.HitNormal
    local up0, right0 = HitBasis(n0, eyeForward)

    local result = { target = target, hit = { pos = p0, normal = n0, texture = tr.HitTexture }, edges = {} }
    local points, normals = { p0 }, { n0 }
    local paths = {}
    for name, dir in pairs({ right = right0, left = -right0, up = up0, down = -up0 }) do
        local path, reason = PCF.March(target, p0, n0, dir)
        paths[name] = path
        result.edges[name] = reason
        for _, sample in ipairs(path) do
            table.insert(points, sample.pos)
            table.insert(normals, sample.normal)
        end
    end
    result.points = points
    result.paths = paths

    local fit = Mth.FitSurface(points, normals, n0)
    result.fit = fit
    result.shape = fit.shape
    result.residual = fit.residual

    local segmentCount = math.Clamp(math.floor(Setting("segments", 8)), 1, 64)
    local lift = Setting("lift", 0.25)
    local segments = {}

    if fit.shape == "cylinder" then
        local A, C, r = fit.axis, fit.center, fit.radius
        -- Angles around the axis, 0 at the hit, increasing to the right.
        local radial0 = p0 - C
        local e1 = Unit(radial0 - A * radial0:Dot(A))
        local e2 = Unit(A:Cross(e1))
        if e2:Dot(A:Cross(n0)) < 0 then e2 = -e2 end -- increasing to the viewer's right
        local function Theta(p)
            local d = p - C
            return math.atan2(d:Dot(e2), d:Dot(e1))
        end
        local function Radial(theta) return e1 * math.cos(theta) + e2 * math.sin(theta) end
        local function Normal(theta) return fit.concave and -Radial(theta) or Radial(theta) end

        local tMin, tMax, hMin, hMax = 0, 0, math.huge, -math.huge
        for _, p in ipairs(points) do
            local t = Theta(p)
            tMin, tMax = math.min(tMin, t), math.max(tMax, t)
            local h = (p - C):Dot(A)
            hMin, hMax = math.min(hMin, h), math.max(hMax, h)
        end
        local height = hMax - hMin
        local hMid = (hMin + hMax) / 2

        result.radius, result.concave, result.axis, result.center = r, fit.concave, A, C
        result.arcDegrees = math.deg(tMax - tMin)
        result.width = r * (tMax - tMin)
        result.height = height
        local tMid = (tMin + tMax) / 2
        result.frame = { pos = C + Radial(tMid) * r + A * hMid, normal = Normal(tMid), up = A }

        local delta = (tMax - tMin) / segmentCount
        for i = 1, segmentCount do
            local t = tMin + (i - 0.5) * delta
            local N = Normal(t)
            local pos, width
            if fit.concave then
                -- On the chord: in front of the curved surface everywhere.
                pos, width = C + Radial(t) * (r * math.cos(delta / 2)), 2 * r * math.sin(delta / 2)
            else
                -- On the tangent: in front of the bulging surface everywhere.
                pos, width = C + Radial(t) * r, 2 * r * math.tan(delta / 2)
            end
            pos = pos + A * hMid + N * lift
            table.insert(segments, { pos = pos, normal = N, right = Unit(A:Cross(N)), up = A, width = width, height = height })
        end
    else
        -- Flat (or a sphere, laid out on the plane touching it at the hit).
        local N = fit.shape == "flat" and fit.normal or n0
        local up = Unit(up0 - N * up0:Dot(N))
        local right = Unit(up:Cross(N))
        local uMin, uMax, vMin, vMax = 0, 0, 0, 0
        for _, p in ipairs(points) do
            local d = p - p0
            uMin, uMax = math.min(uMin, d:Dot(right)), math.max(uMax, d:Dot(right))
            vMin, vMax = math.min(vMin, d:Dot(up)), math.max(vMax, d:Dot(up))
        end
        local center = p0 + right * ((uMin + uMax) / 2) + up * ((vMin + vMax) / 2)
        result.width, result.height = uMax - uMin, vMax - vMin
        result.frame = { pos = center, normal = N, up = up }
        if fit.shape == "sphere" then
            result.radius, result.concave, result.center = fit.radius, fit.concave, fit.center
        end
        table.insert(segments, { pos = center + N * lift, normal = N, right = right, up = up, width = result.width, height = result.height })
    end

    for _, seg in ipairs(segments) do
        -- cam.Start3D2D: x along Forward (right), y along Right (down), facing Up.
        seg.ang = seg.right:AngleEx(seg.normal)
        seg.topLeft = seg.pos - seg.right * (seg.width / 2) + seg.up * (seg.height / 2)
    end
    result.segments = segments
    result.frame.ang = Unit(result.frame.up:Cross(result.frame.normal)):AngleEx(result.frame.normal)

    -- Everything again in the target's own coordinates (props and entities).
    if target.pos and target.ang then
        result.ToLocal = function(pos) return (WorldToLocal(pos, Angle(0, 0, 0), target.pos, target.ang)) end
        result.ToLocalDir = function(dir) return (WorldToLocal(dir, Angle(0, 0, 0), Vector(0, 0, 0), target.ang)) end
        result.ToLocalAng = function(seg)
            return result.ToLocalDir(seg.right):AngleEx(result.ToLocalDir(seg.normal))
        end
    end
    return result
end
