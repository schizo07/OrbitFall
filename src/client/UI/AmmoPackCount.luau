-- "PACK n" count in the HUD own card (next to MAG) while the local trooper wears an ammo backpack for the weapon in
-- hand. Reads the character attributes AmmoPack (reloads left) and AmmoPackFor (weapon id) set by server/WeaponService.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Store = require(script.Parent.Parent.Store)
local HudSkin = require(script.Parent.HudSkin)
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
	-- UI STYLE new skins: a count cell in the weapon block (UI/WeaponBlock); a style switch destroys it and a new one is made
	if HudSkin.isNew() then
		local l = WeaponBlock.addCount("AmmoPack")
		if l then
			label = l
			lastText = nil
		end
		return l
	end
	local hud = player:FindFirstChild("PlayerGui") and player.PlayerGui:FindFirstChild("OrbitHUD")
	local card = hud and hud:FindFirstChild("OwnCard", true)
	local counts = card and card:FindFirstChild("Counts")
	local mags = counts and counts:FindFirstChild("Mags")
	if not mags or not mags:IsA("TextLabel") then
		return nil
	end
	local l = mags:Clone()
	l.Name = "AmmoPack"
	l.LayoutOrder = mags.LayoutOrder + 1
	l.Text = ""
	l.Visible = false
	l.Parent = counts
	label = l
	lastText = nil
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
