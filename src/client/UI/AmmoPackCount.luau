-- "PACK n" count in the HUD own card (next to MAG) while the local trooper wears an ammo backpack for the weapon in
-- hand. Reads the character attributes AmmoPack (reloads left) and AmmoPackFor (weapon id) set by server/WeaponService.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Store = require(script.Parent.Parent.Store)
local WeaponBlock = require(script.Parent.WeaponBlock)

local AmmoPackCount = {}
local player = Players.LocalPlayer

local label: TextLabel? = nil
local lastText: string? = nil

-- clone the HUD's MAG count cell so the pack count matches its style; nil until the HUD is built
local function ensureLabel(): TextLabel?
	if label and label.Parent then
		return label
	end
	local l = WeaponBlock.addCount("AmmoPack")
	if l then
		label = l
		lastText = nil
	end
	return l
end

function AmmoPackCount.init()
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.15 then
			return
		end
		acc = 0
		local l = ensureLabel()
		if not l then
			return
		end
		local c = player.Character
		local n = c and c:GetAttribute("AmmoPack")
		local forId = c and c:GetAttribute("AmmoPackFor")
		local me = Store.get("me")
		local ws = me and me.weapons and me.weapons[me.weapon or 1]
		local text = ""
		if type(n) == "number" and n > 0 and ws and ws.id == forId then
			text = "PACK " .. tostring(n)
		end
		if text ~= lastText then
			lastText = text
			l.Text = text
			l.Visible = text ~= ""
		end
	end)
end

return AmmoPackCount
