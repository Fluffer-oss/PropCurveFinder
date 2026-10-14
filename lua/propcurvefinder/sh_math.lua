PropCurveFinder = PropCurveFinder or {}
local PCF = PropCurveFinder
local Mth = {}
PCF.Math = Mth

-- Small linear algebra on GMod Vectors, for fitting surfaces to sampled points.

-- Eigen decomposition of a symmetric 3x3 matrix m[i][j] (Jacobi rotations).
-- Returns the eigenvalues in ascending order and their unit eigenvectors.
function Mth.Eigen(m)
    local a = { { m[1][1], m[1][2], m[1][3] }, { m[2][1], m[2][2], m[2][3] }, { m[3][1], m[3][2], m[3][3] } }
    local v = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
    for _ = 1, 64 do
        local p, q, largest = 1, 2, 0
        for i = 1, 2 do
            for j = i + 1, 3 do
                if math.abs(a[i][j]) > largest then p, q, largest = i, j, math.abs(a[i][j]) end
            end
        end
        if largest < 1e-14 then break end

        local theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
        local t = (theta >= 0 and 1 or -1) / (math.abs(theta) + math.sqrt(theta * theta + 1))
        local c = 1 / math.sqrt(t * t + 1)
        local s = t * c
        for k = 1, 3 do
            local akp, akq = a[k][p], a[k][q]
            a[k][p], a[k][q] = c * akp - s * akq, s * akp + c * akq
        end
        for k = 1, 3 do
            local apk, aqk = a[p][k], a[q][k]
            a[p][k], a[q][k] = c * apk - s * aqk, s * apk + c * aqk
        end
        for k = 1, 3 do
            local vkp, vkq = v[k][p], v[k][q]
            v[k][p], v[k][q] = c * vkp - s * vkq, s * vkp + c * vkq
        end
    end

    local pairsList = {}
    for i = 1, 3 do
        pairsList[i] = { value = a[i][i], vector = Vector(v[1][i], v[2][i], v[3][i]):GetNormalized() }
    end
    table.sort(pairsList, function(x, y) return x.value < y.value end)
    return { pairsList[1].value, pairsList[2].value, pairsList[3].value },
        { pairsList[1].vector, pairsList[2].vector, pairsList[3].vector }
end

-- Sum of outer products v vT over a list of vectors, divided by the count.
local function MeanOuter(list, center)
    local m = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
    for _, item in ipairs(list) do
        local d = center and (item - center) or item
        local c = { d.x, d.y, d.z }
        for i = 1, 3 do
            for j = 1, 3 do m[i][j] = m[i][j] + c[i] * c[j] end
        end
    end
    for i = 1, 3 do
        for j = 1, 3 do m[i][j] = m[i][j] / #list end
    end
    return m
end
Mth.MeanOuter = MeanOuter

function Mth.Centroid(points)
    local sum = Vector(0, 0, 0)
    for _, p in ipairs(points) do sum = sum + p end
    return sum * (1 / #points)
end

-- Solves the 3x3 system a x = b (Cramer). nil if it's (nearly) singular.
local function Solve3(a, b)
    local function det(m)
        return m[1][1] * (m[2][2] * m[3][3] - m[2][3] * m[3][2])
            - m[1][2] * (m[2][1] * m[3][3] - m[2][3] * m[3][1])
            + m[1][3] * (m[2][1] * m[3][2] - m[2][2] * m[3][1])
    end
    local d = det(a)
    local scale = math.abs(a[1][1]) + math.abs(a[2][2]) + math.abs(a[3][3])
    if math.abs(d) < 1e-9 * scale * scale * scale or d == 0 then return nil end
    local result = {}
    for col = 1, 3 do
        local m = { { a[1][1], a[1][2], a[1][3] }, { a[2][1], a[2][2], a[2][3] }, { a[3][1], a[3][2], a[3][3] } }
        for row = 1, 3 do m[row][col] = b[row] end
        result[col] = det(m) / d
    end
    return result
end
Mth.Solve3 = Solve3

-- The point nearest (in least squares) to all the lines p_i + t n_i: where a
-- surface's normals meet. Restricted to the plane through `origin` that's
-- perpendicular to `axis` when an axis is given (a cylinder's normals all meet
-- its axis, so only their crossing in that plane is defined).
function Mth.NormalsMeet(points, normals, axis, origin)
    local a = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
    local b = { 0, 0, 0 }
    for i, p in ipairs(points) do
        local n = normals[i]
        if axis then
            n = (n - axis * n:Dot(axis)):GetNormalized()
            p = p - axis * (p - origin):Dot(axis)
        end
        local nc = { n.x, n.y, n.z }
        local pc = { p.x, p.y, p.z }
        for r = 1, 3 do
            for c = 1, 3 do
                local projector = (r == c and 1 or 0) - nc[r] * nc[c]
                a[r][c] = a[r][c] + projector
                b[r] = b[r] + projector * pc[c]
            end
        end
    end
    if axis then
        -- Pin the free direction along the axis to `origin`.
        local ac = { axis.x, axis.y, axis.z }
        local along = origin:Dot(axis)
        for r = 1, 3 do
            for c = 1, 3 do a[r][c] = a[r][c] + ac[r] * ac[c] end
            b[r] = b[r] + ac[r] * along
        end
    end
    local x = Solve3(a, b)
    return x and Vector(x[1], x[2], x[3]) or nil
end

-- Thresholds (mean squared sine of the spread of the normals).
Mth.FLAT = 2e-4   -- under about 0.8 degrees of spread: flat
Mth.AXIS = 0.15   -- a cylinder when the least spread is under this fraction of the middle one

-- Fits a plane, cylinder or sphere to points with their surface normals.
-- `facing` is the normal at the probed point (towards the viewer).
function Mth.FitSurface(points, normals, facing)
    local fit = { centroid = Mth.Centroid(points), count = #points }
    local values, vectors = Mth.Eigen(MeanOuter(normals))
    fit.spread = { values[1], values[2], values[3] }

    local function Residual(distanceTo)
        local sum = 0
        for _, p in ipairs(points) do sum = sum + distanceTo(p) ^ 2 end
        return math.sqrt(sum / #points)
    end

    if values[1] + values[2] < Mth.FLAT then
        fit.shape = "flat"
        local normal = vectors[3]
        if normal:Dot(facing) < 0 then normal = -normal end
        fit.normal = normal
        fit.residual = Residual(function(p) return math.abs((p - fit.centroid):Dot(normal)) end)
        return fit
    end

    if values[1] < Mth.AXIS * values[2] then
        fit.shape = "cylinder"
        -- The normals of a cylinder are all perpendicular to its axis.
        local axis = vectors[1]
        if axis.z < -1e-6 or (math.abs(axis.z) <= 1e-6 and axis:Dot(facing:Cross(Vector(0, 0, 1))) < 0) then axis = -axis end
        fit.axis = axis
        local center = Mth.NormalsMeet(points, normals, axis, fit.centroid)
        if not center then
            fit.shape = "unknown"
            return fit
        end
        fit.center = center
        local function Radial(p)
            local d = p - center
            return (d - axis * d:Dot(axis)):Length()
        end
        local sum = 0
        for _, p in ipairs(points) do sum = sum + Radial(p) end
        fit.radius = sum / #points
        fit.residual = Residual(function(p) return Radial(p) - fit.radius end)
    else
        fit.shape = "sphere"
        local center = Mth.NormalsMeet(points, normals)
        if not center then
            fit.shape = "unknown"
            return fit
        end
        fit.center = center
        local sum = 0
        for _, p in ipairs(points) do sum = sum + (p - center):Length() end
        fit.radius = sum / #points
        fit.residual = Residual(function(p) return (p - center):Length() - fit.radius end)
    end

    -- Concave (curving round towards the viewer, like a wraparound screen) when
    -- the normals point towards the center.
    fit.concave = facing:Dot(fit.center - fit.centroid) > 0
    return fit
end
