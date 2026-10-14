local BASE = "propcurvefinder/"

if SERVER then
    AddCSLuaFile(BASE .. "sh_math.lua")
    AddCSLuaFile(BASE .. "cl_staticprops.lua")
    AddCSLuaFile(BASE .. "cl_probe.lua")
    AddCSLuaFile(BASE .. "cl_display.lua")
end

include(BASE .. "sh_math.lua")

if SERVER then
    include(BASE .. "sv_interface.lua")
else
    include(BASE .. "cl_staticprops.lua")
    include(BASE .. "cl_probe.lua")
    include(BASE .. "cl_display.lua")
end
