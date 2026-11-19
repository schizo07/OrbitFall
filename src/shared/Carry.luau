--!strict
-- Haul objective ("Recover Core Cells") carry rules, shared by the server (WeaponService / MovementService hooks,
-- server/Objectives/HaulCells) and the client (client/CellCarry, CombatPose, Movement), so both sides agree.
--   Player + character attribute `CarryCell` = true while that trooper carries at least one core cell (server-set).
--   Player + character attribute `CarryCount` = 1 | 2 while carrying (server-set; nil when 0).
--   workspace attribute `HaulCarryRule` = "STRICT" | "SIDEARM" (server-set; Studio A/B "CARRY RULES" switches it).
--     STRICT  : no firing, aiming or grenades while carrying
--     SIDEARM : the secondary (slot 2) can aim and fire while carrying 1 cell; 2 cells & grenades stay blocked
local Carry = {}

Carry.ATTR = "CarryCell"
Carry.COUNT_ATTR = "CarryCount"
Carry.RULE_ATTR = "HaulCarryRule"
Carry.MAX_CELLS = 2
Carry.SPEED_MULT = 0.8 -- walk speed while carrying 1 cell
Carry.SPRINT_MULT = 0.6 -- sprint speed while carrying 1 cell (sprint stays allowed, stamina drains as usual)
Carry.TWO_SPEED_MULT = 0.6 -- walk speed while carrying 2 cells (no sprint)
Carry.ANIM_MULT = 0.76 -- slower walk/run animation cadence while hauling
-- cell placement in UpperTorso space (+X right, +Y up, -Z forward):
-- 1 cell: held in the left hand at the hip (rotated so the long axis runs front-to-back)
Carry.HOLD_ONE = CFrame.new(-1.48, -1.05, -0.08) * CFrame.Angles(0, math.pi / 2, 0) * CFrame.Angles(math.rad(8), 0, 0)
-- 2 cells: stacked at chest height held with both arms
Carry.HOLD = CFrame.new(0, 0.14, -1.24) * CFrame.Angles(math.rad(6), 0, 0)
Carry.HOLD_TWO_1 = CFrame.new(0, -0.48, -1.18) * CFrame.Angles(math.rad(6), 0, 0)
Carry.HOLD_TWO_2 = CFrame.new(0, 0.78, -1.22) * CFrame.Angles(math.rad(4), 0, 0)
Carry.SIZE = Vector3.new(1.8, 1.25, 1.1)
Carry.COLOR = Color3.fromRGB(110, 225, 255)

function Carry.rule(): string
	return if workspace:GetAttribute(Carry.RULE_ATTR) == "SIDEARM" then "SIDEARM" else "STRICT"
end

function Carry.count(who: Instance?): number
	if not who then
		return 0
	end
	local c = who:GetAttribute(Carry.COUNT_ATTR)
	if type(c) == "number" then
		return math.max(0, math.floor(c))
	end
	return if who:GetAttribute(Carry.ATTR) == true then 1 else 0
end

function Carry.canSprint(who: Instance?): boolean
	return Carry.count(who) < Carry.MAX_CELLS
end

-- speed factor for a carrier; Studio A/B "CARRY SPEED" (client/Variants.luau) overrides 1-cell speeds through Feel_CarryWalk / Feel_CarrySprint
function Carry.speedMult(sprinting: boolean, who: Instance?): number
	if Carry.count(who) >= Carry.MAX_CELLS then
		return Carry.TWO_SPEED_MULT
	end
	local v = workspace:GetAttribute(if sprinting then "Feel_CarrySprint" else "Feel_CarryWalk")
	if type(v) == "number" then
		return v
	end
	return if sprinting then Carry.SPRINT_MULT else Carry.SPEED_MULT
end

function Carry.isCarrying(who: Instance?): boolean
	return Carry.count(who) > 0
end

-- what: "fire" | "aim" | "grenade"; slot: the weapon slot in hand (1 primary, 2 secondary, 3 support)
function Carry.blocks(player: Player?, what: string, slot: number?): boolean
	local cnt = Carry.count(player)
	if cnt <= 0 then
		return false
	end
	if what == "grenade" or cnt >= Carry.MAX_CELLS then
		return true
	end
	if Carry.rule() == "SIDEARM" and slot == 2 then
		return false
	end
	return true
end

return Carry
