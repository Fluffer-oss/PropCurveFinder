PropCurveFinder = PropCurveFinder or {}
local PCF = PropCurveFinder

-- Static props aren't entities: a trace that hits one only says it hit the
-- world. So the map file's static prop list (model, position, angles) and each
-- model's bounding box are read here, to tell which one was hit.

local function U16(s, i) local a, b = s:byte(i, i + 1) return a + b * 256 end
local function I32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    local v = a + b * 256 + c * 65536 + d * 16777216
    return v >= 2147483648 and v - 4294967296 or v
end
local function F32(s, i)
    local b1, b2, b3, b4 = s:byte(i, i + 3)
    local sign = b4 > 127 and -1 or 1
    local exponent = (b4 % 128) * 2 + math.floor(b3 / 128)
    local mantissa = (b3 % 128) * 65536 + b2 * 256 + b1
    if exponent == 0 then return sign * math.ldexp(mantissa, -149) end
    if exponent == 255 then return 0 end
    return sign * math.ldexp(1 + mantissa / 8388608, exponent - 127)
end
local function CString(s, i)
    local stop = s:find("\0", i, true)
    return s:sub(i, (stop or #s + 1) - 1)
end
PCF.Bytes = { U16 = U16, I32 = I32, F32 = F32 }

local LUMP_GAME = 35
local SPRP = 0x73707270 -- "sprp"

-- A model's bounding box, from its .mdl header (the view box if it has one,
-- else the collision hull). nil if the model can't be read.
local boundsCache = {}
function PCF.ModelBounds(model)
    if boundsCache[model] ~= nil then return boundsCache[model] or nil end
    local result = false
    local f = file.Open(model, "rb", "GAME")
    if f then
        local h = f:Read(152) or ""
        f:Close()
        if #h == 152 and h:sub(1, 4) == "IDST" then
            local function Vec(at) return Vector(F32(h, at), F32(h, at + 4), F32(h, at + 8)) end
            local mins, maxs = Vec(129), Vec(141) -- view box
            if mins.x == 0 and mins.y == 0 and mins.z == 0 and maxs.x == 0 and maxs.y == 0 and maxs.z == 0 then
                mins, maxs = Vec(105), Vec(117) -- hull
            end
            result = { mins = mins, maxs = maxs }
        end
    end
    boundsCache[model] = result
    return result or nil
end

-- Every static prop on the map: { index, model, pos, ang }. Read once.
local staticProps
function PCF.StaticProps()
    if staticProps then return staticProps end
    staticProps = {}

    local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
    if not f then return staticProps end
    local header = f:Read(8 + 64 * 16) or ""
    if #header < 8 + 64 * 16 or header:sub(1, 4) ~= "VBSP" then f:Close() return staticProps end

    local base = 9 + LUMP_GAME * 16
    f:Seek(I32(header, base))
    local gameLump = f:Read(I32(header, base + 4)) or ""
    for g = 0, (#gameLump >= 4 and I32(gameLump, 1) or 0) - 1 do
        local at = 5 + g * 16
        if I32(gameLump, at) == SPRP and U16(gameLump, at + 4) % 2 == 0 then
            f:Seek(I32(gameLump, at + 8))
            local sprp = f:Read(I32(gameLump, at + 12)) or ""
            local dictCount = I32(sprp, 1)
            local models = {}
            for d = 0, dictCount - 1 do
                models[d] = string.lower(CString(sprp, 5 + d * 128)):gsub("\\", "/")
            end
            local p = 5 + dictCount * 128
            p = p + 4 + I32(sprp, p) * 2 -- leaf list
            local propCount = I32(sprp, p)
            p = p + 4
            local size = propCount > 0 and (#sprp - p + 1) / propCount or 0
            if size >= 26 and size == math.floor(size) then
                for n = 0, propCount - 1 do
                    local at2 = p + n * size
                    local model = models[U16(sprp, at2 + 24)]
                    if model then
                        table.insert(staticProps, {
                            index = n,
                            model = model,
                            pos = Vector(F32(sprp, at2), F32(sprp, at2 + 4), F32(sprp, at2 + 8)),
                            ang = Angle(F32(sprp, at2 + 12), F32(sprp, at2 + 16), F32(sprp, at2 + 20))
                        })
                    end
                end
            end
        end
    end
    f:Close()
    return staticProps
end

-- Whether a world position is inside a static prop's bounding box (plus `pad`).
function PCF.InStaticProp(prop, pos, pad)
    local bounds = PCF.ModelBounds(prop.model)
    if not bounds then return false end
    local localPos = WorldToLocal(pos, Angle(0, 0, 0), prop.pos, prop.ang)
    return localPos.x >= bounds.mins.x - pad and localPos.x <= bounds.maxs.x + pad
        and localPos.y >= bounds.mins.y - pad and localPos.y <= bounds.maxs.y + pad
        and localPos.z >= bounds.mins.z - pad and localPos.z <= bounds.maxs.z + pad
end

-- The static prop a world position is on: the smallest one whose box holds it.
function PCF.FindStaticProp(pos)
    local best, bestVolume
    for _, prop in ipairs(PCF.StaticProps()) do
        if prop.pos:DistToSqr(pos) < 4096 * 4096 and PCF.InStaticProp(prop, pos, 2) then
            local b = PCF.ModelBounds(prop.model)
            local size = b.maxs - b.mins
            local volume = size.x * size.y * size.z
            if not bestVolume or volume < bestVolume then best, bestVolume = prop, volume end
        end
    end
    return best
end
