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
	{
		-- client/Fx/Blast.luau: the shared explosion effect (visual size only; gameplay radius is Data/Blasts.luau)
		name = "EXPLOSIONS",
		keys = { "Feel_BlastScale" },
		presets = {
			{ name = "A Big (new effect)", set = {} },
			{ name = "B Huge (new effect x1.4)", set = { Feel_BlastScale = 1.4 } },
			{ name = "C Current (old effect)", set = { Feel_BlastScale = 0 } },
		},
	},
	{
		-- client/Fx/Blast.luau: camera shake + FOV punch of the new explosion effect
		name = "BLAST SHAKE",
		keys = { "Feel_BlastShake" },
		presets = {
			{ name = "A normal (x1)", set = {} },
			{ name = "B soft (x0.5)", set = { Feel_BlastShake = 0.5 } },
			{ name = "C strong (x1.6)", set = { Feel_BlastShake = 1.6 } },
			{ name = "D off", set = { Feel_BlastShake = 0 } },
		},
	},
	{
		-- server/PlayerService passive regen (mirrored to the server by client/Fx/VitalsFx, Action "studioFeel")
		name = "REGEN",
		keys = { "Feel_Regen" },
		presets = {
			{ name = "A slow (above 50 %, after 6 s)", set = {} },
			{ name = "B off (stims only)", set = { Feel_Regen = "off" } },
			{ name = "C old (up to 60 %, after 5 s)", set = { Feel_Regen = "current" } },
		},
	},
	{
		-- client/Fx/VitalsFx: red edge + desaturation + heartbeat strength, big-hit visor overlay
		name = "DAMAGE FX",
		keys = { "Feel_DmgFx", "Feel_DmgOverlay" },
		presets = {
			{ name = "A default (static >= 15 %, cracks >= 28 %)", set = {} },
			{ name = "B subtle (x0.6)", set = { Feel_DmgFx = 0.6 } },
			{ name = "C strong (x1.4)", set = { Feel_DmgFx = 1.4 } },
			{ name = "D cracks only", set = { Feel_DmgOverlay = "crack" } },
			{ name = "E no visor overlay", set = { Feel_DmgOverlay = "none" } },
		},
	},
	{
		-- client/CallInController + UI/UplinkCodes: how a call-in gets armed on PC / gamepad (touch always uses the dial)
		name = "UPLINK ARM",
		keys = { "Feel_UplinkArm", "Feel_UplinkListPos" },
		presets = {
			{ name = "A codes, list left of crosshair", set = {} },
			{ name = "B codes, list far left", set = { Feel_UplinkListPos = "left" } },
			{ name = "C old Slot + Sync dial", set = { Feel_UplinkArm = "slot" } },
		},
	},
	{
		-- UI/CallInCards: squad call-in cards mid-left
		name = "CALL-IN CARDS",
		keys = { "Feel_CallInCardLife", "Feel_CallInCardOwn" },
		presets = {
			{ name = "A 4 s, own call-ins shown", set = {} },
			{ name = "B 6 s", set = { Feel_CallInCardLife = 6 } },
			{ name = "C 4 s, squadmates only", set = { Feel_CallInCardOwn = false } },
		},
	},
	{
		-- client/Fx/EnemyFx: heavy-target damage stages (smoke / breach / fire), impact puffs, burning death plates
		name = "DAMAGE STAGES",
		keys = { "Feel_StageFx" },
		presets = {
			{ name = "A default (x1)", set = {} },
			{ name = "B subtle (x0.5)", set = { Feel_StageFx = 0.5 } },
			{ name = "C heavy (x1.6)", set = { Feel_StageFx = 1.6 } },
			{ name = "D off (old look)", set = { Feel_StageFx = 0 } },
		},
	},
	{
		-- haul objective (client/CellCarry forwards it to the server, shared/Carry.luau): what a core-cell carrier may use
		name = "CARRY RULES",
		keys = { "CarryTune_Rule" },
		presets = {
			{ name = "A strict (no shooting while carrying)", set = {} },
			{ name = "B sidearm (secondary can fire)", set = { CarryTune_Rule = "SIDEARM" } },
		},
	},
	{
		-- UI/SquadTags: floating teammate tags (S-tag + name) shown through walls
		name = "SQUAD TAGS",
		keys = { "TagTune_Mode" },
		presets = {
			{ name = "A fade when close / at screen centre", set = {} },
			{ name = "B always solid", set = { TagTune_Mode = "solid" } },
			{ name = "C off", set = { TagTune_Mode = "off" } },
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
