AddCSLuaFile()

-- Prop Curve Finder as a weapon. Same as the console commands:
-- primary probes what you're looking at, secondary clears, reload shows the last result.
SWEP.PrintName = "Prop Curve Finder"
SWEP.Author = "Fluffer-oss"
SWEP.Instructions = "Primary: probe the surface. Secondary: clear. Reload: show the last result."
SWEP.Category = "Prop Curve Finder"
SWEP.Spawnable = true
SWEP.AdminOnly = false

SWEP.ViewModel = "models/weapons/c_pistol.mdl"
SWEP.WorldModel = "models/weapons/w_pistol.mdl"
SWEP.UseHands = true
SWEP.Slot = 5
SWEP.SlotPos = 10
SWEP.DrawAmmo = false

SWEP.Primary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }
SWEP.Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }

-- The probe runs on the client (it reads the map's static props and shows the
-- result there). The server tells the owner's client, which also covers
-- singleplayer, where weapons only run on the server.
local function Tell(weapon, message)
    if CLIENT then return end
    local owner = weapon:GetOwner()
    if IsValid(owner) and owner:IsPlayer() then
        net.Start(message)
        net.Send(owner)
    end
end

function SWEP:PrimaryAttack()
    self:SetNextPrimaryFire(CurTime() + 0.5)
    self:EmitSound("buttons/button17.wav")
    Tell(self, "PropCurveFinder.Probe")
end

function SWEP:SecondaryAttack()
    self:SetNextSecondaryFire(CurTime() + 0.5)
    if SERVER and PropCurveFinder.ClearTestInterface then PropCurveFinder.ClearTestInterface(self:GetOwner()) end
    Tell(self, "PropCurveFinder.Clear")
end

function SWEP:Reload()
    if (self.NextReopen or 0) > CurTime() then return end
    self.NextReopen = CurTime() + 0.5
    Tell(self, "PropCurveFinder.Reopen")
end
