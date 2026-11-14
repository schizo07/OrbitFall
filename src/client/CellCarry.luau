-- Haul objective ("Recover Core Cells"), client side of carrying a core cell.
-- Server: server/Objectives/HaulCells.luau (pickup prompt, weld, drop, delivery). Rules: shared/Carry.luau.
--   * Input gates while the local trooper carries (Player attribute `CarryCell`): Fire and Aim read as released
--     (STRICT; SIDEARM rule lets slot 2 through), Grenade throws are skipped (WeaponController checks Input.isGated).
--   * Interact (E) or Grenade (G / R1 / the touch GRENADE button) drops the cell: Action "cellDrop".
--   * Sidearm rule: picking a cell up switches to the secondary.
--   * Studio A/B "CARRY RULES" (client/Variants.luau, workspace attribute CarryTune_Rule) is forwarded to the server,
--     which owns the rule (workspace attribute HaulCarryRule).
-- Speed x0.8 / no sprint lives in client/Movement.luau, the carry pose in client/CombatPose.luau.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Carry = require(Shared.Carry)
local Input = require(script.Parent.Input)
local Store = require(script.Parent.Store)

local CellCarry = {}

local player = Players.LocalPlayer
local actionEv: RemoteEvent? = nil
local lastDrop = 0

local function slot(): number?
	local m = Store.get("me")
	return if type(m) == "table" and type(m.weapon) == "number" then m.weapon else nil
end

function CellCarry.isCarrying(): boolean
	return player:GetAttribute(Carry.ATTR) == true
end

local function dropKeyText(): string
	if Input.isTouch() then
		return "GRENADE"
	elseif Input.isGamepad() then
		return "R1"
	end
	return "E / G"
end

function CellCarry.init()
	actionEv = Net.event("Action")
	Input.setGate("Fire", function()
		return Carry.blocks(player, "fire", slot())
	end)
	Input.setGate("Aim", function()
		return Carry.blocks(player, "aim", slot())
	end)
	Input.setGate("Grenade", function()
		return Carry.blocks(player, "grenade")
	end)

	local function tryDrop(d: boolean)
		if d and CellCarry.isCarrying() and os.clock() - lastDrop > 0.3 and actionEv then
			lastDrop = os.clock()
			actionEv:FireServer("cellDrop")
		end
	end
	Input.on("Interact", tryDrop)
	Input.on("Grenade", tryDrop)

	player:GetAttributeChangedSignal(Carry.ATTR):Connect(function()
		if not CellCarry.isCarrying() then
			return
		end
		Store.set("toast", "Core cell in hand. Load it at the cargo lifter. [" .. dropKeyText() .. "] drop")
		if Carry.rule() == "SIDEARM" then
			local m = Store.get("me")
			if type(m) == "table" and m.weapons and m.weapons[2] and m.weapon ~= 2 and actionEv then
				actionEv:FireServer("swap", 2)
			end
		end
	end)

	if RunService:IsStudio() then
		local function send()
			if actionEv then
				actionEv:FireServer("carryRule", workspace:GetAttribute("CarryTune_Rule"))
			end
		end
		workspace:GetAttributeChangedSignal("CarryTune_Rule"):Connect(send)
		send()
	end
end

return CellCarry
