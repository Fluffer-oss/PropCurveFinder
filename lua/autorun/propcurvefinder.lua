local BASE = "propcurvefinder/"

if SERVER then
    AddCSLuaFile(BASE .. "sh_math.lua")
    AddCSLuaFile(BASE .. "sh_curve.lua")
    AddCSLuaFile(BASE .. "cl_curved.lua")
    AddCSLuaFile(BASE .. "cl_staticprops.lua")
    AddCSLuaFile(BASE .. "cl_modelmesh.lua")
    AddCSLuaFile(BASE .. "cl_probe.lua")
    AddCSLuaFile(BASE .. "cl_display.lua")
end

include(BASE .. "sh_math.lua")
include(BASE .. "sh_curve.lua")

if SERVER then
    include(BASE .. "sv_interface.lua")
else
    include(BASE .. "cl_staticprops.lua")
    include(BASE .. "cl_modelmesh.lua")
    include(BASE .. "cl_probe.lua")
    include(BASE .. "cl_display.lua")
    include(BASE .. "cl_curved.lua")
end

-- So you can see in the console that the addon is installed and loaded.
MsgN("[PropCurveFinder] loaded (" .. (SERVER and "server" or "client") .. "): console command 'propcurvefinder', or the Prop Curve Finder weapon")
