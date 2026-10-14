AddCSLuaFile()

-- Invisible holder for PropCurveFinder's STM test interface (STM interfaces
-- belong to an entity). Not drawn, not solid, but sent to every client, which
-- STM needs to place the windows.
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "PropCurveFinder Anchor"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:Initialize()
    self:SetModel("models/hunter/blocks/cube025x025x025.mdl")
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_NONE)
    self:DrawShadow(false)
end

function ENT:UpdateTransmitState()
    return TRANSMIT_ALWAYS
end

function ENT:Draw() end
