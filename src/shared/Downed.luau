--!strict
-- Downed state rules, shared by the server (server/Downed.luau, WeaponService, CallInService) and the client
-- (client/DownedFx.luau, Movement, CellCarry gates), so both sides agree.
--   Player + character attribute `Downed` = true while that trooper is down (server-set).
--   Player attribute `DownedEnd` = server time the bleed-out would finish at the current rate (HUD bar; server-set).
--   Player attributes `ReviveBy` (UserId) + `ReviveStart` (server time) while a squadmate holds the revive prompt;
--   the reviver's character gets `Reviving` = true meanwhile (client/Movement kneels it).
-- While down: sidearm (slot 2) only, no grenades, no call-ins, no stand / sprint / dive / jump.
local RunService = game:GetService("RunService")
local Config = require(script.Parent.Config)

local Downed = {}

Downed.ATTR = "Downed"
Downed.END_ATTR = "DownedEnd"
Downed.PROMPT = "RevivePrompt" -- ProximityPrompt name on the downed body's HumanoidRootPart
Downed.REVIVE_BY = "ReviveBy"
Downed.REVIVE_START = "ReviveStart"
Downed.REVIVING = "Reviving"

local IS_STUDIO = RunService:IsStudio()

function Downed.isDowned(who: Instance?): boolean
	return who ~= nil and who:GetAttribute(Downed.ATTR) == true
end

-- Seconds the stim key must be held (client: VitalsFx fill; server: PlayerService checks the time since "stimstart").
-- 0 = a tap stims at once. Studio A/B: Feel_StimHold (number, mirrored to the server by Variants).
function Downed.stimHold(): number
	if IS_STUDIO then
		local a = workspace:GetAttribute("Feel_StimHold")
		if type(a) == "number" then
			return math.clamp(a, 0, 3)
		end
	end
	return Config.Stims.Hold or 0
end

-- what: "fire" | "aim" | "grenade" | "callin" | "swap"; slot: the weapon slot in hand / asked for
function Downed.blocks(player: Player?, what: string, slot: number?): boolean
	if not player or player:GetAttribute(Downed.ATTR) ~= true then
		return false
	end
	if what == "fire" or what == "aim" or what == "swap" then
		return slot ~= 2
	end
	return true
end

return Downed
