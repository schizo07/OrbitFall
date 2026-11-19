-- Enemy silhouette help at range: a faint faction-coloured outline + fill on the enemies that are hardest to pick out against
-- the terrain (40-150 studs away, on screen). Up close the models' own glow accents (EnemyModels COG_ACCENT / BROOD_ACCENT)
-- carry them.
--
-- Cheap on phones: a fixed pool of Highlights (6, 4 on low quality) re-assigned 5 times a second to the best candidates;
-- alerted enemies (model attribute Aware == "alert", server Awareness) go first and get a stronger outline. Elites already
-- carry their own outline (EnemyFx "EliteOutline") and are skipped. Highlights share the client's 31 limit with the hit
-- flash (EnemyAnim, up to 20) and the elite outlines, hence the small pool.
-- Studio A/B: workspace attribute Feel_EnemyOutline (number, default 1; 0 = off, 2 = twice as opaque).

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local EnemyData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Enemies"))

local EnemyLook = {}

local IS_STUDIO = RunService:IsStudio()
local NEAR, FAR = 40, 150
local HYST = 6 -- an outlined enemy keeps its outline a few studs past either edge (no flicker at the band edges)
local TICK = 0.2
local POOL_MAX = 6
local POOL_LOW = 4

type Look = { color: Color3, fill: number, outline: number, alertFill: number, alertOutline: number }
local LOOKS: { [string]: Look } = {
	COG = { color = Color3.fromRGB(255, 172, 112), fill = 0.80, outline = 0.34, alertFill = 0.68, alertOutline = 0.10 },
	BROOD = { color = Color3.fromRGB(140, 255, 90), fill = 0.86, outline = 0.5, alertFill = 0.76, alertOutline = 0.18 },
	LUMEN = { color = Color3.fromRGB(190, 160, 255), fill = 0.88, outline = 0.55, alertFill = 0.78, alertOutline = 0.22 },
}
local DEFAULT_LOOK = LOOKS.COG

type Tracked = { model: Model, root: BasePart?, look: Look, height: number }
local tracked: { [Model]: Tracked } = {}

type Slot = { hl: Highlight, model: Model?, alert: boolean? }
local slots: { Slot } = {}
local folder: Folder? = nil
local quality = 1

local function strengthK(): number
	if not IS_STUDIO then
		return 1
	end
	local v = Workspace:GetAttribute("Feel_EnemyOutline")
	return if type(v) == "number" then math.clamp(v, 0, 3) else 1
end

-- transparency t at strength k: k = 0 invisible, 1 = as given, > 1 more opaque
local function scaled(t: number, k: number): number
	return math.clamp(1 - (1 - t) * k, 0, 1)
end

local function newSlot(): Slot
	local hl = Instance.new("Highlight")
	hl.Name = "EnemyLook"
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.FillTransparency = 1
	hl.OutlineTransparency = 1
	hl.Enabled = false
	hl.Parent = folder
	return { hl = hl, model = nil, alert = nil }
end

local function track(m: Instance)
	if not m:IsA("Model") or tracked[m] then
		return
	end
	local kind = m:GetAttribute("Kind")
	local def = if type(kind) == "string" then EnemyData.get(kind) else nil
	local look = (def and LOOKS[def.faction]) or DEFAULT_LOOK
	tracked[m] = { model = m, root = nil, look = look, height = if def then def.size * 1.2 else 3 }
end

local function release(s: Slot)
	s.model = nil
	s.alert = nil
	s.hl.Enabled = false
	s.hl.Adornee = nil
end

local function apply(s: Slot, t: Tracked, alert: boolean, k: number, fresh: boolean)
	local hl = s.hl
	local lk = t.look
	local fill = scaled(if alert then lk.alertFill else lk.fill, k)
	local outline = scaled(if alert then lk.alertOutline else lk.outline, k)
	if fresh then
		hl.Adornee = t.model
		hl.FillColor = lk.color
		hl.OutlineColor = lk.color
		hl.FillTransparency = 1
		hl.OutlineTransparency = 1
		hl.Enabled = true
		TweenService:Create(hl, TweenInfo.new(0.3), { FillTransparency = fill, OutlineTransparency = outline }):Play()
	elseif s.alert ~= alert then
		TweenService:Create(hl, TweenInfo.new(0.2), { FillTransparency = fill, OutlineTransparency = outline }):Play()
	end
	s.model = t.model
	s.alert = alert
end

type Cand = { t: Tracked, score: number, alert: boolean }

local function tick()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local k = strengthK()
	local cap = if k <= 0 then 0 elseif quality < 0.75 then POOL_LOW else POOL_MAX
	while #slots < cap do
		table.insert(slots, newSlot())
	end
	local held: { [Model]: Slot } = {}
	for _, s in slots do
		if s.model then
			held[s.model] = s
		end
	end

	local camPos = cam.CFrame.Position
	local cands: { Cand } = {}
	if cap > 0 then
		for m, t in tracked do
			if not m.Parent then
				tracked[m] = nil
				continue
			end
			local root = t.root
			if not root then
				local r = m.PrimaryPart or m:FindFirstChild("Root")
				if not (r and r:IsA("BasePart")) then
					continue
				end
				t.root = r
				root = r
			end
			if m:FindFirstChild("EliteOutline") then
				continue
			end
			local p = (root :: BasePart).Position + Vector3.new(0, t.height * 0.5, 0)
			local d = (p - camPos).Magnitude
			local slack = if held[m] then HYST else 0
			if d < NEAR - slack or d > FAR + slack then
				continue
			end
			local _, onScreen = cam:WorldToViewportPoint(p)
			if not onScreen then
				continue
			end
			local alert = m:GetAttribute("Aware") == "alert"
			-- alert first, then nearest; a held outline gets a bonus so slots do not swap every tick
			local score = d - (if alert then 80 else 0) - (if held[m] then 15 else 0)
			table.insert(cands, { t = t, score = score, alert = alert })
		end
		table.sort(cands, function(a, b)
			return a.score < b.score
		end)
	end

	-- keep slots whose enemy is still chosen, then fill the free ones
	local chosen: { [Model]: Cand } = {}
	for i = 1, math.min(cap, #cands) do
		chosen[cands[i].t.model] = cands[i]
	end
	local free: { Slot } = {}
	for i, s in slots do
		local c = if s.model then chosen[s.model] else nil
		if i > cap then
			release(s)
		elseif c then
			apply(s, c.t, c.alert, k, false)
			chosen[c.t.model] = nil
		else
			if s.model then
				release(s)
			end
			table.insert(free, s)
		end
	end
	for _, c in chosen do
		local s = table.remove(free)
		if not s then
			break
		end
		apply(s, c.t, c.alert, k, true)
	end
end

function EnemyLook.init(Fx: any)
	quality = if Fx and type(Fx.quality) == "number" then Fx.quality else 1
	local f = Instance.new("Folder")
	f.Name = "EnemyLook"
	f.Parent = Workspace -- created on the client: never replicates
	folder = f
	task.spawn(function()
		local enemies = Workspace:WaitForChild("Enemies", 120)
		if not enemies then
			return
		end
		for _, m in enemies:GetChildren() do
			track(m)
		end
		enemies.ChildAdded:Connect(function(m)
			task.defer(track, m)
		end)
		enemies.ChildRemoved:Connect(function(m)
			if m:IsA("Model") then
				tracked[m] = nil
				for _, s in slots do
					if s.model == m then
						release(s)
					end
				end
			end
		end)
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < TICK then
			return
		end
		acc = 0
		debug.profilebegin("EnemyLook.tick")
		tick()
		debug.profileend()
	end)
end

return EnemyLook
