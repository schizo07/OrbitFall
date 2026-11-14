--!nonstrict
-- Studio-only A/B switcher. Each group is a list of named presets; a preset is a set of workspace attributes
-- (CamTune_* read by CameraController, PoseTune_* read by CombatPose, ...). Keys cycle the active group's presets
-- live during Play so the user can pick by feel instead of describing it.
--   K / L  (or [ / ])   previous / next preset in the current group
--   J      (or \)       next group (when there is more than one)
-- A small label in the top-centre shows the group and preset. Live games never load this (Main.client: IsStudio).
-- Picked presets get baked into the code defaults and their group is removed (2026-11-14: framing, gun feel,
-- enemy hit, feet picked; the store sound candidates were rejected in favour of in-house sounds).

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local Variants = {}

-- Every preset lists the full set of keys its group touches, so switching never leaves a stale value behind.
-- nil-valued keys are written as "clear" (attribute removed -> the code's default is used).
-- A preset may also carry `sounds = { SoundKey = { [layerIndex] = "rbxassetid://..." } }` to swap sound layers.
local GROUPS = {
	{
		name = "FRAMING",
		keys = { "CamTune_Shoulder", "CamTune_PivotUp", "CamTune_Fov", "CamTune_DistAdd", "PoseTune_Pocket", "PoseTune_Blade" },
		-- A = the 2026-11-14 pick baked into the code (camera "high + back" + rifle at the cheek); B-D are small
		-- variations around it, since the pick was a hybrid of two presets.
		presets = {
			{ name = "A picked (C camera + D gun)", set = {} },
			{ name = "B a bit lower", set = { CamTune_Shoulder = Vector3.new(2.0, 1.35, 0), CamTune_PivotUp = 1.75 } },
			{ name = "C a bit closer", set = { CamTune_DistAdd = 1.8 } },
			{ name = "D wider shoulder", set = { CamTune_Shoulder = Vector3.new(2.5, 1.8, 0) } },
		},
	},
	{
		-- client/Movement.luau: while prone / diving the upper body turns with the camera, the legs stay put
		name = "PRONE TWIST",
		keys = { "ProneTwist", "ProneTwistLimit", "ProneTurnRate" },
		presets = {
			{ name = "A new (75 deg limit, legs turn 5/s)", set = {} },
			{ name = "B tighter (50 deg)", set = { ProneTwistLimit = 50 } },
			{ name = "C wider (100 deg), legs slow", set = { ProneTwistLimit = 100, ProneTurnRate = 3 } },
			{ name = "D old (whole body turns)", set = { ProneTwist = false } },
		},
	},
}

-- sound layer swaps: Audio reads layer.id at play time, so editing the shared Sounds table is enough
local Sounds = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Sounds"))
local originalIds: { [string]: { [number]: string } } = {}
local function applySounds(g: any, p: any)
	-- restore every layer this group ever touched, then apply the preset's swaps
	for _, preset in g.presets do
		for key, swaps in (preset.sounds or {}) do
			local entry = Sounds[key]
			if entry then
				originalIds[key] = originalIds[key] or {}
				for i in swaps do
					local layer = entry.layers[i]
					if layer then
						if originalIds[key][i] == nil then
							originalIds[key][i] = layer.id
						end
						layer.id = originalIds[key][i]
					end
				end
			end
		end
	end
	for key, swaps in (p.sounds or {}) do
		local entry = Sounds[key]
		if entry then
			for i, id in swaps do
				if entry.layers[i] then
					entry.layers[i].id = id
				end
			end
		end
	end
end

local groupIdx, presetIdx = 1, 1
local label: TextLabel? = nil

local function apply()
	local g = GROUPS[groupIdx]
	local p = g.presets[presetIdx]
	for _, k in g.keys do
		workspace:SetAttribute(k, (p.set or {})[k])
	end
	applySounds(g, p)
	if label then
		label.Text = string.format("%s: %s  (%d/%d)   K / L switch   J next group", g.name, p.name, presetIdx, #g.presets)
	end
end

function Variants.init()
	if not RunService:IsStudio() then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "Variants"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.IgnoreGuiInset = true
	local l = Instance.new("TextLabel")
	l.AnchorPoint = Vector2.new(0.5, 0)
	l.Position = UDim2.new(0.5, 0, 0, 104)
	l.Size = UDim2.fromOffset(420, 20)
	l.BackgroundColor3 = Color3.new(0, 0, 0)
	l.BackgroundTransparency = 0.45
	l.BorderSizePixel = 0
	l.TextColor3 = Color3.fromRGB(255, 200, 120)
	l.Font = Enum.Font.GothamBold
	l.TextSize = 13
	l.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	label = l
	apply()

	UserInputService.InputBegan:Connect(function(io, processed)
		if processed or io.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		local g = GROUPS[groupIdx]
		local k = io.KeyCode
		-- letters work on every keyboard layout; [ ] \ kept as alternates
		if k == Enum.KeyCode.L or k == Enum.KeyCode.RightBracket then
			presetIdx = presetIdx % #g.presets + 1
			apply()
		elseif k == Enum.KeyCode.K or k == Enum.KeyCode.LeftBracket then
			presetIdx = (presetIdx - 2) % #g.presets + 1
			apply()
		elseif (k == Enum.KeyCode.J or k == Enum.KeyCode.BackSlash) and #GROUPS > 1 then
			groupIdx = groupIdx % #GROUPS + 1
			presetIdx = 1
			apply()
		end
	end)
end

return Variants
