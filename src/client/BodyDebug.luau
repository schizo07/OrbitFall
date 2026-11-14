--!nonstrict
-- Studio-only body readout for the local character (toggled by DebugKeys, key N; hidden by default, costs nothing while off).
-- Shows, live:
--   * stance / Movement mode, Humanoid state, FloorMaterial, HipHeight, Waist twist (deg)
--   * FootPlant on/off and lift per foot
--   * per leg joint (plus Root / Waist): who wrote Transform last this frame ("Anim" = nobody overwrote the Animator's
--     value), who wrote C0 this frame, and the largest frame-to-frame change of the joint (deg, last 0.5 s) to spot flicker
--   * PreSimulation handler runs per rendered frame (min / max over the last 0.5 s), FPS
--   * the Animator's playing tracks (name, weight)
-- Writers report through BodyDebug.mark(joint, slot, who); each call is a single boolean check while the readout is off.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local BodyDebug = {}
BodyDebug.on = false

local player = Players.LocalPlayer
local frame = 0
local simThisFrame, simMin, simMax = 0, math.huge, 0

type Mark = { t: string?, tf: number, c: string?, cf: number }
local marks: { [any]: Mark } = setmetatable({}, { __mode = "k" }) :: any

function BodyDebug.mark(j: any, slot: string, who: string)
	if not BodyDebug.on then
		return
	end
	local m = marks[j]
	if not m then
		m = { tf = -1, cf = -1 }
		marks[j] = m
	end
	if slot == "C0" then
		m.c, m.cf = who, frame
	else
		m.t, m.tf = who, frame
	end
end

local JOINTS = {
	{ "LowerTorso", "Root" },
	{ "UpperTorso", "Waist" },
	{ "LeftUpperLeg", "LeftHip" },
	{ "LeftLowerLeg", "LeftKnee" },
	{ "LeftFoot", "LeftAnkle" },
	{ "RightUpperLeg", "RightHip" },
	{ "RightLowerLeg", "RightKnee" },
	{ "RightFoot", "RightAnkle" },
}

local gui: ScreenGui? = nil
local label: TextLabel? = nil
local conns: { RBXScriptConnection } = {}
local last: { [any]: CFrame } = setmetatable({}, { __mode = "k" }) :: any
local peak: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any
local window, textAt = 0, 0
local fpsFrames, fps = 0, 0
local tracksText = ""
local tracksAt = 0
local Movement: any = nil
local FootPlant: any = nil

local function deg(r: number): string
	return string.format("%5.1f", math.deg(r))
end

local function angleBetween(a: CFrame, b: CFrame): number
	local _, ang = (a:Inverse() * b):ToAxisAngle()
	return math.abs(ang)
end

local function sample(dt: number)
	local c = player.Character
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if not c or not hum then
		return
	end
	-- per-frame change of every joint's final Transform (after every writer)
	for _, pair in JOINTS do
		local part = c:FindFirstChild(pair[1])
		local j = part and part:FindFirstChild(pair[2])
		if j and (j:IsA("Motor6D") or j:IsA("AnimationConstraint")) then
			local tr = j.Transform
			local prev = last[j]
			if prev then
				peak[j] = math.max(peak[j] or 0, angleBetween(prev, tr))
			end
			last[j] = tr
		end
	end
	window += dt
	fpsFrames += 1
	local t = os.clock()
	if t - tracksAt > 0.25 then
		tracksAt = t
		local animator = hum:FindFirstChildOfClass("Animator")
		local list = {}
		if animator then
			for _, tr in animator:GetPlayingAnimationTracks() do
				local n = if tr.Animation then tr.Animation.Name else tr.Name
				table.insert(list, string.format("  %-14s w%.2f", string.sub(n, 1, 14), tr.WeightCurrent))
			end
		end
		tracksText = if #list > 0 then table.concat(list, "\n") else "  (none)"
	end
	if t - textAt < 0.1 then
		return
	end
	textAt = t
	local lines = {}
	local stance, mode = "?", "?"
	if Movement then
		local ok1, s = pcall(Movement.getStance)
		local ok2, m = pcall(Movement.getMode)
		stance = if ok1 then tostring(s) else "?"
		mode = if ok2 then tostring(m) else "?"
	end
	local twist = if Movement and Movement.getTwist then Movement.getTwist(c) else 0
	table.insert(lines, string.format("BODY  [N] hide   fps %d   presim/frame %d..%d", fps, if simMin == math.huge then 0 else simMin, simMax))
	table.insert(lines, string.format("stance %s  mode %s", stance, mode))
	table.insert(lines, string.format("state %s  floor %s", hum:GetState().Name, hum.FloorMaterial.Name))
	table.insert(lines, string.format("hip %.3f  twist %s deg", hum.HipHeight, deg(twist)))
	if FootPlant and FootPlant.debugState then
		local on, liftL, liftR = FootPlant.debugState()
		table.insert(lines, string.format("footplant %s  L %.2f  R %.2f", if on then "ON " else "off", liftL, liftR))
	end
	table.insert(lines, "joint        T-writer   C0-writer   peak deg/frame")
	for _, pair in JOINTS do
		local part = c:FindFirstChild(pair[1])
		local j = part and part:FindFirstChild(pair[2])
		if j then
			local m = marks[j]
			-- a mark from this frame (or the previous one: PreSimulation can skip a rendered frame) counts as current
			local tw = if m and m.t and frame - m.tf <= 1 then m.t else "Anim"
			local cw = if m and m.c and frame - m.cf <= 1 then m.c else "-"
			table.insert(lines, string.format("%-12s %-10s %-11s %s", pair[2], tw, cw, deg(peak[j] or 0)))
		end
	end
	table.insert(lines, "tracks:")
	table.insert(lines, tracksText)
	if label then
		label.Text = table.concat(lines, "\n")
	end
	if window >= 0.5 then
		fps = math.floor(fpsFrames / window + 0.5)
		window, fpsFrames = 0, 0
		table.clear(peak)
		simMin, simMax = math.huge, 0
	end
end

local function build()
	local g = Instance.new("ScreenGui")
	g.Name = "BodyDebug"
	g.ResetOnSpawn = false
	g.DisplayOrder = 61
	g.IgnoreGuiInset = true
	local l = Instance.new("TextLabel")
	l.Name = "Readout"
	l.Position = UDim2.fromOffset(8, 120)
	l.AutomaticSize = Enum.AutomaticSize.XY
	l.Size = UDim2.fromOffset(0, 0)
	l.BackgroundColor3 = Color3.new(0, 0, 0)
	l.BackgroundTransparency = 0.45
	l.BorderSizePixel = 0
	l.Font = Enum.Font.Code
	l.TextSize = 13
	l.TextColor3 = Color3.fromRGB(180, 255, 190)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.Text = ""
	l.Parent = g
	g.Parent = player:WaitForChild("PlayerGui")
	gui, label = g, l
end

function BodyDebug.toggle()
	if not RunService:IsStudio() then
		return
	end
	BodyDebug.on = not BodyDebug.on
	if not BodyDebug.on then
		for _, cn in conns do
			cn:Disconnect()
		end
		table.clear(conns)
		if gui then
			gui.Enabled = false
		end
		return
	end
	if not Movement then
		local ok, m = pcall(require, script.Parent:FindFirstChild("Movement"))
		Movement = if ok then m else nil
		local ok2, f = pcall(require, script.Parent:FindFirstChild("FootPlant"))
		FootPlant = if ok2 then f else nil
	end
	if not gui then
		build()
	end
	(gui :: ScreenGui).Enabled = true
	table.clear(last)
	table.clear(peak)
	table.insert(
		conns,
		RunService.PreRender:Connect(function()
			if simThisFrame > 0 or frame > 0 then
				simMin = math.min(simMin, simThisFrame)
				simMax = math.max(simMax, simThisFrame)
			end
			simThisFrame = 0
			frame += 1
		end)
	)
	table.insert(
		conns,
		RunService.PreSimulation:Connect(function()
			simThisFrame += 1
		end)
	)
	table.insert(
		conns,
		RunService.PostSimulation:Connect(function(dt)
			local ok, err = pcall(sample, dt)
			if not ok then
				warn("[BodyDebug] " .. tostring(err))
			end
		end)
	)
end

return BodyDebug
