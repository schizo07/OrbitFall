--!strict
-- Downed state rules, shared by the server (server/Downed.luau, WeaponService, CallInService) and the client
-- (client/DownedFx.luau, Movement, CellCarry gates), so both sides agree.
--   Player + character attribute `Downed` = true while that trooper is down (server-set).
--   Player attribute `DownedEnd` = server time the bleed-out would finish at the current rate (HUD bar; server-set).
-- While down: sidearm (slot 2) only, no grenades, no call-ins, no stand / sprint / dive / jump.
local Downed = {}

Downed.ATTR = "Downed"
Downed.END_ATTR = "DownedEnd"
Downed.PROMPT = "RevivePrompt" -- ProximityPrompt name on the downed body's HumanoidRootPart

function Downed.isDowned(who: Instance?): boolean
	return who ~= nil and who:GetAttribute(Downed.ATTR) == true
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
