PropCurveFinder = PropCurveFinder or {}
local PCF = PropCurveFinder

-- A model's visual triangles, read from its files: .mdl (materials, meshes),
-- .vvd (vertex positions and normals) and .dx90.vtx (triangles). Traces hit a
-- prop's collision model, which can sit in front of what you see (a screen's
-- glass, a simplified hull); these are the real surfaces and their materials.

local function U8(s, i) return s:byte(i) end
local function U16(s, i) local a, b = s:byte(i, i + 1) return a + b * 256 end
local function I16(s, i) local v = U16(s, i) return v >= 32768 and v - 65536 or v end
local function I32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    local v = a + b * 256 + c * 65536 + d * 16777216
    return v >= 2147483648 and v - 4294967296 or v
end
local F32 = function(s, i) return PCF.Bytes.F32(s, i) end
local function CString(s, i)
    local stop = s:find("\0", i, true)
    return s:sub(i, (stop or #s + 1) - 1)
end
local function Normalize(path)
    return (string.lower(path):gsub("\\", "/"):gsub("/+", "/"):gsub("^/", ""):gsub("%.vmt$", ""))
end
PCF.NormalizePath = Normalize

local function ReadAll(path)
    local f = file.Open(path, "rb", "GAME")
    if not f then return nil end
    local data = f:Read(f:Size()) or ""
    f:Close()
    return data
end

-- Byte offsets (0-based) in the formats, +1 for Lua strings.
local MDL_VERSION, MDL_TEXTURES, MDL_CDTEXTURES = 4, 204, 212
local MDL_SKINREFS, MDL_SKINFAMILIES, MDL_SKININDEX, MDL_BODYPARTS = 220, 224, 228, 232
local BODYPART_SIZE, MODEL_SIZE, MESH_SIZE, TEXTURE_SIZE = 16, 148, 116, 64
local VERTEX_SIZE = 48 -- mstudiovertex_t in the .vvd
local STRIP_TRILIST, STRIP_TRISTRIP = 1, 2

-- The material paths of a model's textures (each texture under each of its
-- material folders; the first that exists wins).
local function TextureNames(mdl)
    local folders = {}
    local folderCount, folderAt = I32(mdl, MDL_CDTEXTURES + 1), I32(mdl, MDL_CDTEXTURES + 5)
    for i = 0, folderCount - 1 do
        folders[#folders + 1] = CString(mdl, I32(mdl, folderAt + i * 4 + 1) + 1)
    end
    local names = {}
    local count, at = I32(mdl, MDL_TEXTURES + 1), I32(mdl, MDL_TEXTURES + 5)
    for i = 0, count - 1 do
        local structAt = at + i * TEXTURE_SIZE
        local name = CString(mdl, structAt + I32(mdl, structAt + 1) + 1)
        local chosen
        for _, folder in ipairs(folders) do
            local candidate = Normalize(folder .. "/" .. name)
            local mat = Material(candidate)
            if mat and not mat:IsError() then chosen = candidate break end
        end
        names[i] = chosen or Normalize((folders[1] or "") .. "/" .. name)
    end
    return names
end

-- The .vvd's vertices for the full-detail model (with its fixups applied):
-- list of { pos = Vector, normal = Vector }, 0-based.
local function Vertices(vvd)
    if vvd:sub(1, 4) ~= "IDSV" then return nil end
    local lod0Count = I32(vvd, 16 + 1)
    local fixupCount, fixupAt = I32(vvd, 48 + 1), I32(vvd, 52 + 1)
    local dataAt = I32(vvd, 56 + 1)
    local function Read(index)
        local at = dataAt + index * VERTEX_SIZE + 1
        return {
            pos = Vector(F32(vvd, at + 16), F32(vvd, at + 20), F32(vvd, at + 24)),
            normal = Vector(F32(vvd, at + 28), F32(vvd, at + 32), F32(vvd, at + 36))
        }
    end
    local list = {}
    if fixupCount == 0 then
        for i = 0, lod0Count - 1 do list[i] = Read(i) end
    else
        local n = 0
        for f = 0, fixupCount - 1 do
            local at = fixupAt + f * 12 + 1
            if I32(vvd, at) >= 0 then
                local source, count = I32(vvd, at + 4), I32(vvd, at + 8)
                for v = 0, count - 1 do
                    list[n] = Read(source + v)
                    n = n + 1
                end
            end
        end
    end
    return list
end

-- Triangles of one mesh from the .vtx: lists of three mesh-local vertex ids.
-- stripGroupSize is 25 for most models (33 for some newer ones).
local function MeshTriangles(vtx, meshAt, meshVertexCount, stripGroupSize)
    local triangles = {}
    local groupCount, groupOffset = I32(vtx, meshAt + 1), I32(vtx, meshAt + 5)
    for g = 0, groupCount - 1 do
        local groupAt = meshAt + groupOffset + g * stripGroupSize
        local vertCount, vertOffset = I32(vtx, groupAt + 1), I32(vtx, groupAt + 5)
        local indexCount, indexOffset = I32(vtx, groupAt + 9), I32(vtx, groupAt + 13)
        local stripCount, stripOffset = I32(vtx, groupAt + 17), I32(vtx, groupAt + 21)
        if vertCount < 0 or indexCount < 0 or stripCount < 0 or groupAt + vertOffset + vertCount * 9 > #vtx
            or groupAt + indexOffset + indexCount * 2 > #vtx then
            return nil
        end
        local function MeshVertex(index)
            if index < 0 or index >= indexCount then return nil end
            local v = U16(vtx, groupAt + indexOffset + index * 2 + 1)
            if v >= vertCount then return nil end
            local id = U16(vtx, groupAt + vertOffset + v * 9 + 4 + 1) -- origMeshVertID
            if id >= meshVertexCount then return nil end
            return id
        end
        for s = 0, stripCount - 1 do
            local stripAt = groupAt + stripOffset + s * 27
            local count, first = I32(vtx, stripAt + 1), I32(vtx, stripAt + 5)
            local flags = U8(vtx, stripAt + 18 + 1)
            if flags % 4 >= STRIP_TRISTRIP and flags % 2 < STRIP_TRILIST then
                for i = 0, count - 3 do
                    local a, b, c = MeshVertex(first + i), MeshVertex(first + i + 1), MeshVertex(first + i + 2)
                    if not (a and b and c) then return nil end
                    if i % 2 == 1 then a, b = b, a end
                    if a ~= b and b ~= c and a ~= c then triangles[#triangles + 1] = { a, b, c } end
                end
            else
                for i = 0, count - 3, 3 do
                    local a, b, c = MeshVertex(first + i), MeshVertex(first + i + 1), MeshVertex(first + i + 2)
                    if not (a and b and c) then return nil end
                    triangles[#triangles + 1] = { a, b, c }
                end
            end
        end
    end
    return triangles
end

-- All of a model's visible triangles (body 0 of each part, full detail):
-- list of { a, b, c (Vectors), na, nb, nc (vertex normals), material },
-- in the model's own coordinates. nil if its files can't be read.
local meshCache = {}
function PCF.ModelMesh(model, skin)
    model = Normalize(model)
    skin = skin or 0
    local key = model .. "#" .. skin
    if meshCache[key] ~= nil then return meshCache[key] or nil end
    meshCache[key] = false

    local base = model:gsub("%.mdl$", "")
    local mdl = ReadAll(model)
    local vvd = ReadAll(base .. ".vvd")
    local vtx = ReadAll(base .. ".dx90.vtx") or ReadAll(base .. ".vtx") or ReadAll(base .. ".dx80.vtx")
    if not (mdl and vvd and vtx) or mdl:sub(1, 4) ~= "IDST" then return nil end

    local names = TextureNames(mdl)
    local skinRefs, families, skinAt = I32(mdl, MDL_SKINREFS + 1), I32(mdl, MDL_SKINFAMILIES + 1), I32(mdl, MDL_SKININDEX + 1)
    if skin >= families then skin = 0 end
    local function MaterialOf(ref)
        local texture = skinRefs > 0 and I16(mdl, skinAt + (skin * skinRefs + ref) * 2 + 1) or ref
        return names[texture] or ("texture " .. tostring(texture))
    end

    local vertices = Vertices(vvd)
    if not vertices then return nil end

    local function Build(stripGroupSize)
        local triangles = {}
        local partCount, partAt = I32(mdl, MDL_BODYPARTS + 1), I32(mdl, MDL_BODYPARTS + 5)
        local vtxPartAt = I32(vtx, 32 + 1)
        for p = 0, partCount - 1 do
            local part = partAt + p * BODYPART_SIZE
            local vtxPart = vtxPartAt + p * 8
            local modelCount = I32(mdl, part + 4 + 1)
            if modelCount > 0 then
                -- Body 0: the first model of each part.
                local m = part + I32(mdl, part + 12 + 1)
                local vtxModel = vtxPart + I32(vtx, vtxPart + 4 + 1)
                local vtxLod = vtxModel + I32(vtx, vtxModel + 4 + 1)
                local meshCount, meshAt = I32(mdl, m + 72 + 1), m + I32(mdl, m + 76 + 1)
                local modelVertexBase = I32(mdl, m + 84 + 1) / VERTEX_SIZE
                local vtxMeshAt = vtxLod + I32(vtx, vtxLod + 4 + 1)
                for k = 0, meshCount - 1 do
                    local mesh = meshAt + k * MESH_SIZE
                    local material = MaterialOf(I32(mdl, mesh + 1))
                    local meshVertexCount, vertexOffset = I32(mdl, mesh + 8 + 1), I32(mdl, mesh + 12 + 1)
                    local tris = MeshTriangles(vtx, vtxMeshAt + k * 9, meshVertexCount, stripGroupSize)
                    if not tris then return nil end
                    for _, t in ipairs(tris) do
                        local va = vertices[modelVertexBase + vertexOffset + t[1]]
                        local vb = vertices[modelVertexBase + vertexOffset + t[2]]
                        local vc = vertices[modelVertexBase + vertexOffset + t[3]]
                        if not (va and vb and vc) then return nil end
                        triangles[#triangles + 1] = { a = va.pos, b = vb.pos, c = vc.pos, na = va.normal, nb = vb.normal, nc = vc.normal, material = material }
                    end
                end
            end
        end
        return triangles
    end

    local triangles = Build(25) or Build(33)
    if not triangles then return nil end
    local mesh = { triangles = triangles, version = I32(mdl, MDL_VERSION + 1) }
    meshCache[key] = mesh
    return mesh
end

-- Where a ray first crosses a triangle (Moller-Trumbore), or nil.
local function RayTriangle(origin, dir, a, b, c)
    local e1, e2 = b - a, c - a
    local p = dir:Cross(e2)
    local det = e1:Dot(p)
    if math.abs(det) < 1e-9 then return nil end
    local inv = 1 / det
    local s = origin - a
    local u = s:Dot(p) * inv
    if u < 0 or u > 1 then return nil end
    local q = s:Cross(e1)
    local v = dir:Dot(q) * inv
    if v < 0 or u + v > 1 then return nil end
    local t = e2:Dot(q) * inv
    return t > 0 and t or nil
end

-- The triangle a ray (in the model's coordinates) hits first: index and distance.
function PCF.RayMesh(mesh, origin, dir)
    local best, bestT
    for i, tri in ipairs(mesh.triangles) do
        local t = RayTriangle(origin, dir, tri.a, tri.b, tri.c)
        if t and (not bestT or t < bestT) then best, bestT = i, t end
    end
    return best, bestT
end

-- Every separate piece of `material`: lists of triangle indices, largest
-- first. Triangles are in the same piece when they share an edge (two
-- corners), so panels that only touch at a corner, or have a gap between
-- them, are separate. Slivers under 1% of the largest piece's area are dropped.
function PCF.MaterialPieces(mesh, material)
    local function Key(v) return string.format("%.2f %.2f %.2f", v.x, v.y, v.z) end
    local function EdgeKey(a, b)
        local ka, kb = Key(a), Key(b)
        if ka > kb then ka, kb = kb, ka end
        return ka .. "|" .. kb
    end
    local byEdge, members = {}, {}
    for i, tri in ipairs(mesh.triangles) do
        if tri.material == material then
            members[#members + 1] = i
            for _, edge in ipairs({ { tri.a, tri.b }, { tri.b, tri.c }, { tri.c, tri.a } }) do
                local k = EdgeKey(edge[1], edge[2])
                byEdge[k] = byEdge[k] or {}
                table.insert(byEdge[k], i)
            end
        end
    end

    local pieceOf, pieces = {}, {}
    for _, start in ipairs(members) do
        if not pieceOf[start] then
            local piece = { triangles = {}, area = 0 }
            pieceOf[start] = piece
            local queue = { start }
            while #queue > 0 do
                local i = table.remove(queue)
                local tri = mesh.triangles[i]
                table.insert(piece.triangles, i)
                piece.area = piece.area + (tri.b - tri.a):Cross(tri.c - tri.a):Length() / 2
                for _, edge in ipairs({ { tri.a, tri.b }, { tri.b, tri.c }, { tri.c, tri.a } }) do
                    for _, j in ipairs(byEdge[EdgeKey(edge[1], edge[2])]) do
                        if not pieceOf[j] then pieceOf[j] = piece queue[#queue + 1] = j end
                    end
                end
            end
            table.sort(piece.triangles)
            pieces[#pieces + 1] = piece
        end
    end
    table.sort(pieces, function(a, b) return a.area > b.area end)

    local result = {}
    for _, piece in ipairs(pieces) do
        if piece.area >= (pieces[1].area * 0.01) then result[#result + 1] = piece.triangles end
    end
    return result
end

-- The materials a model uses (for listing what you can pick).
function PCF.ModelMaterials(mesh)
    local seen, list = {}, {}
    for _, tri in ipairs(mesh.triangles) do
        if not seen[tri.material] then seen[tri.material] = true list[#list + 1] = tri.material end
    end
    return list
end
