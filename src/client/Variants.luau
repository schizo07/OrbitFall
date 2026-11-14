--!nonstrict
-- Studio-only A/B switcher. Each group is a list of named presets; a preset is a set of workspace attributes
-- (CamTune_* read by CameraController, PoseTune_* read by CombatPose, ...). Keys cycle the active group's presets
-- live during Play so the user can pick by feel instead of describing it.
--   [  /  ]   previous / next preset in the current group
--   \         next group (when there is more than one)
-- A small label in the top-centre shows the group and preset. Live games never load this (Main.client: IsStudio).

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local Variants = {}

-- Every preset lists the full set of keys its group touches, so switching never leaves a stale value behind.
-- nil-valued keys are written as "clear" (attribute removed -> the code's default is used).
local GROUPS = {
	{
		name = "FRAMING",
		keys = { "CamTune_Shoulder", "CamTune_PivotUp", "CamTune_Fov", "CamTune_DistAdd", "PoseTune_Pocket", "PoseTune_Blade" },
		presets = {
			{ name = "A current", set = {} },
			{
				-- trooper smaller in the frame, camera further back and a bit lower (closer to the user's mood reference)
				name = "B further back, lower",
				set = { CamTune_Shoulder = Vector3.new(2.4, 0.5, 0), CamTune_PivotUp = 1.5, CamTune_DistAdd = 3, CamTune_Fov = 66 },
			},
			{
				name = "C high + back",
				set = { CamTune_Shoulder = Vector3.new(2.0, 1.8, 0), CamTune_PivotUp = 1.9, CamTune_DistAdd = 3, CamTune_Fov = 66 },
			},
			{
				-- current camera, rifle raised to cheek height and out of the right glove's shadow
				name = "D gun at cheek",
				set = { PoseTune_Pocket = Vector3.new(0.85, 0.95, -0.4), PoseTune_Blade = 0.35 },
			},
		},
	},
	{
		-- client/FootPlant.luau: leg IK that keeps feet on slopes / bumps instead of sinking into them
		name = "FEET",
		keys = { "FootPlant" },
		presets = {
			{ name = "A planted (new)", set = {} },
			{ name = "B old (feet sink on slopes)", set = { FootPlant = false } },
		},
	},
	{
		-- carbine main crack layer (Sounds.ShotRifle layer 1); the body thump / click / sub / far-tail layers stay.
		-- Candidates from a Creator Store search; names that say they are ripped from other games were skipped.
		name = "CARBINE SHOT",
		keys = {},
		presets = {
			{ name = "A current", sounds = {} },
			{ name = "B store 113879008765178", sounds = { ShotRifle = { [1] = "rbxassetid://113879008765178" } } },
			{ name = "C store 131480162950556", sounds = { ShotRifle = { [1] = "rbxassetid://131480162950556" } } },
			{ name = "D store 122876890028097", sounds = { ShotRifle = { [1] = "rbxassetid://122876890028097" } } },
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
		label.Text = string.format("%s: %s  (%d/%d)   [ ] switch   \\ next group", g.name, p.name, presetIdx, #g.presets)
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
		if io.KeyCode == Enum.KeyCode.RightBracket then
			presetIdx = presetIdx % #g.presets + 1
			apply()
		elseif io.KeyCode == Enum.KeyCode.LeftBracket then
			presetIdx = (presetIdx - 2) % #g.presets + 1
			apply()
		elseif io.KeyCode == Enum.KeyCode.BackSlash and #GROUPS > 1 then
			groupIdx = groupIdx % #GROUPS + 1
			presetIdx = 1
			apply()
		end
	end)
end

return Variants
