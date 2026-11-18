--!strict
-- Haul objective ("Recover Core Cells") carry rules, shared by the server (WeaponService / MovementService hooks,
-- server/Objectives/HaulCells) and the client (client/CellCarry, CombatPose, Movement), so both sides agree.
--   Player + character attribute `CarryCell` = true while that trooper carries a core cell (server-set).
--   workspace attribute `HaulCarryRule` = "STRICT" | "SIDEARM" (server-set; Studio A/B "CARRY RULES" switches it).
--     STRICT  : no firing, aiming or grenades while carrying
--     SIDEARM : the secondary (slot 2) can aim and fire while carrying; grenades stay blocked
local Carry = {}

Carry.ATTR = "CarryCell"
Carry.RULE_ATTR = "HaulCarryRule"
Carry.SPEED_MULT = 0.8 -- walk speed while carrying
Carry.SPRINT_MULT = 0.8 -- sprint speed while carrying (sprint stays allowed, stamina drains as usual)
-- cell placement in UpperTorso space (+X right, +Y up, -Z forward): held against the belly with both hands
Carry.HOLD = CFrame.new(0, -0.55, -1.05)
Carry.SIZE = Vector3.new(1.5, 1.0, 0.9)
Carry.COLOR = Color3.fromRGB(110, 225, 255)

function Carry.rule(): string
	return if workspace:GetAttribute(Carry.RULE_ATTR) == "SIDEARM" then "SIDEARM" else "STRICT"
end

-- speed factor for a carrier; Studio A/B "CARRY SPEED" (client/Variants.luau) overrides through Feel_CarryWalk / Feel_CarrySprint
function Carry.speedMult(sprinting: boolean): number
	local v = workspace:GetAttribute(if sprinting then "Feel_CarrySprint" else "Feel_CarryWalk")
	if type(v) == "number" then
		return v
	end
	return if sprinting then Carry.SPRINT_MULT else Carry.SPEED_MULT
end

function Carry.isCarrying(who: Instance?): boolean
	return who ~= nil and who:GetAttribute(Carry.ATTR) == true
end

-- what: "fire" | "aim" | "grenade"; slot: the weapon slot in hand (1 primary, 2 secondary, 3 support)
function Carry.blocks(player: Player?, what: string, slot: number?): boolean
	if not player or player:GetAttribute(Carry.ATTR) ~= true then
		return false
	end
	if what == "grenade" then
		return true
	end
	if Carry.rule() == "SIDEARM" and slot == 2 then
		return false
	end
	return true
end

return Carry
