-- Wrecks: destroyed COG walkers / heavies (and Brood heavy husks) leave a cheap part-built wreck that stays ~60 s, then sinks
-- into the ground and is removed (footage spec §4.1: wrecked walker hulks litter the field).
--   Wrecks.spawn(e)   called by EnemyService.kill for kinds with def.wreck (never fodder)
--   Wrecks.clear()    EnemyService.clear
-- Budget: <= 7 parts per wreck, at most MAX_WRECKS alive (the oldest starts sinking early). Parts are anchored, CanQuery = false
-- (bullets, prompts and enemy line of sight pass through), CanTouch = false; only the hull of a big wreck collides (cover / climb).
-- A COG wreck smokes for the first SMOKE_TIME seconds and its ember glow cools down; a Brood husk leaves a goo pool.

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local Wrecks = {}

local LIFE = 60 -- seconds before sinking
local SINK_TIME = 4
local SMOKE_TIME = 20
local MAX_WRECKS = 10

local rng = Random.new()
local live: { { model: Model, sinking: boolean } } = {}
local folder: Folder? = nil

local RGB = Color3.fromRGB
local SCORCH = RGB(28, 25, 24) -- heavily charred post-cook-off hull
local PLATE = RGB(48, 50, 56)
local RUST = RGB(128, 66, 34)
local EMBER = RGB(255, 130, 32)
local HUSK = RGB(70, 46, 40)
local HUSK2 = RGB(58, 36, 66)
local GOO = RGB(70, 170, 45)

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = workspace:FindFirstChild("Wrecks")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Wrecks"
		f.Parent = workspace
	end
	folder = f :: Folder
	return folder :: Folder
end

local function part(m: Model, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, collide: boolean?, ball: boolean?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = collide == true
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = size.Magnitude > 5
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.Metal
	if ball then
		local sm = Instance.new("SpecialMesh")
		sm.MeshType = Enum.MeshType.Sphere
		sm.Parent = p
	end
	p.Parent = m
	return p
end

local function smoke(p: BasePart, k: number)
	local em = Instance.new("ParticleEmitter")
	em.Texture = "rbxasset://textures/particles/smoke_main.dds"
	em.Color = ColorSequence.new(RGB(31, 27, 24), RGB(74, 67, 60))
	em.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5 * k), NumberSequenceKeypoint.new(1, 5.2 * k) })
	em.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(0.65, 0.55), NumberSequenceKeypoint.new(1, 1) })
	em.Lifetime = NumberRange.new(3.0, 4.5)
	em.Rate = 4.5
	em.Speed = NumberRange.new(4, 7)
	em.SpreadAngle = Vector2.new(10, 10)
	em.Acceleration = Vector3.new(1.0, 2.5, 0.4)
	em.LightInfluence = 0.4
	em.EmissionDirection = Enum.NormalId.Top
	em.Parent = p
	task.delay(SMOKE_TIME, function()
		if em.Parent then
			em.Enabled = false
		end
	end)
end

local function rnd(a: number, b: number): number
	return rng:NextNumber(a, b)
end

-- tilted slab lying on the ground: centre sunk by `sink` of its height
local function lying(base: CFrame, x: number, z: number, size: Vector3, sink: number, maxTilt: number): CFrame
	return base * CFrame.new(x, size.Y * (0.5 - sink), z) * CFrame.Angles(math.rad(rnd(-maxTilt, maxTilt)), rnd(0, math.pi * 2), math.rad(rnd(-maxTilt, maxTilt)))
end

local function buildCog(m: Model, base: CFrame, s: number, kind: string)
	local k = s / 5
	if kind == "BASTION" then
		-- the plinth stays, the bunker is a broken stump, the roof lies beside it, barrels on the ground
		part(m, Vector3.new(11, 1.6, 11), base * CFrame.new(0, 0.6, 0), SCORCH, Enum.Material.Slate, true)
		local hull = part(m, Vector3.new(8.6, 2.6, 7.8), base * CFrame.new(0.4, 2.4, 0.4) * CFrame.Angles(math.rad(6), 0.1, math.rad(-5)), SCORCH, nil, true)
		part(m, Vector3.new(7.4, 1, 7), base * CFrame.new(rnd(5, 7), 0.4, rnd(-3, 3)) * CFrame.Angles(math.rad(rnd(8, 18)), rnd(0, 6.28), 0), PLATE)
		part(m, Vector3.new(0.7, 0.7, 2.6), lying(base, rnd(-6, -3), rnd(-7, -5), Vector3.new(0.7, 0.7, 2.6), 0.2, 10), RUST)
		part(m, Vector3.new(0.7, 0.7, 2.6), lying(base, rnd(2, 5), rnd(-8, -6), Vector3.new(0.7, 0.7, 2.6), 0.2, 10), RUST)
		local ember = part(m, Vector3.new(3, 0.4, 2.4), base * CFrame.new(0.4, 3.75, 0.4) * CFrame.Angles(math.rad(6), 0.1, math.rad(-5)), EMBER, Enum.Material.Neon)
		TweenService:Create(ember, TweenInfo.new(SMOKE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Color = RGB(60, 40, 36) }):Play()
		smoke(hull, 1.4)
		return
	end
	local hs = Vector3.new(1.5, 0.55, 1.7) * s
	local hull = part(m, hs, lying(base, 0, 0, hs, 0.3, 14), SCORCH, nil, s >= 4)
	local n = if s >= 8 then 3 else 2
	for i = 1, n do
		local ps = Vector3.new(rnd(0.5, 0.9), rnd(0.12, 0.2), rnd(0.5, 0.9)) * s
		local ang = rnd(0, math.pi * 2)
		local r = rnd(0.9, 1.5) * s
		part(m, ps, lying(base, math.cos(ang) * r, math.sin(ang) * r, ps, 0.25, 35), if i == 1 then RUST else PLATE)
	end
	if s >= 8 then
		-- giant walker: one long leg strut lying out of the hull
		local ls = Vector3.new(0.25 * s, 0.25 * s, 1.6 * s)
		part(m, ls, lying(base, rnd(-0.6, 0.6) * s, rnd(-0.6, 0.6) * s, ls, 0.35, 8), PLATE)
	end
	local es = Vector3.new(0.45, 0.12, 0.35) * s
	local ember = part(m, es, hull.CFrame * CFrame.new(0, hs.Y * 0.5, 0), EMBER, Enum.Material.Neon)
	TweenService:Create(ember, TweenInfo.new(SMOKE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Color = RGB(60, 40, 36) }):Play()
	smoke(hull, math.clamp(k, 0.6, 2.4))
end

local function buildBrood(m: Model, base: CFrame, s: number)
	-- the shell cracked in two halves, a few plates, a dim goo pool
	local hs = Vector3.new(1.1, 0.55, 0.9) * s
	part(m, hs, base * CFrame.new(-0.35 * s, hs.Y * 0.25, 0) * CFrame.Angles(0, rnd(-0.4, 0.4), math.rad(-24)), HUSK, Enum.Material.SmoothPlastic, s >= 4, true)
	part(m, hs, base * CFrame.new(0.4 * s, hs.Y * 0.25, 0.2 * s) * CFrame.Angles(0, rnd(-0.4, 0.4), math.rad(28)), HUSK2, Enum.Material.SmoothPlastic, false, true)
	for _ = 1, 2 do
		local ps = Vector3.new(rnd(0.4, 0.7), 0.12, rnd(0.4, 0.7)) * s
		local ang = rnd(0, math.pi * 2)
		part(m, ps, lying(base, math.cos(ang) * s, math.sin(ang) * s, ps, 0.2, 30), HUSK, Enum.Material.SmoothPlastic)
	end
	local pool = part(m, Vector3.new(0.2, 2.2 * s, 2.2 * s), base * CFrame.new(0, 0.08, 0) * CFrame.Angles(0, 0, math.rad(90)), GOO, Enum.Material.Neon)
	pool.Shape = Enum.PartType.Cylinder
	pool.Transparency = 0.35
	TweenService:Create(pool, TweenInfo.new(SMOKE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Color = RGB(40, 70, 34), Transparency = 0.5 }):Play()
end

local function sink(w: { model: Model, sinking: boolean })
	if w.sinking then
		return
	end
	w.sinking = true
	local m = w.model
	task.spawn(function()
		local ext = m:GetExtentsSize()
		local depth = ext.Y + 1
		local start = m:GetPivot()
		local steps = math.floor(SINK_TIME / 0.1)
		for i = 1, steps do
			if not m.Parent then
				break
			end
			m:PivotTo(start - Vector3.new(0, depth * (i / steps), 0))
			task.wait(0.1)
		end
		m:Destroy()
		for i, x in live do
			if x == w then
				table.remove(live, i)
				break
			end
		end
	end)
end

function Wrecks.spawn(e: any)
	if not e or e.fodder or not e.def or not e.def.wreck then
		return
	end
	local ok, err = pcall(function()
		local pos: Vector3 = e.pos or (e.root and e.root.Position) or Vector3.zero
		local yaw: number = e.yaw or 0
		local base = CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
		local m = Instance.new("Model")
		m.Name = "Wreck_" .. tostring(e.kind)
		m:SetAttribute("Wreck", e.kind)
		local s = e.def.size or 4
		if e.faction == "BROOD" then
			buildBrood(m, base, s)
		else
			buildCog(m, base, s, e.kind)
		end
		m.Parent = getFolder()
		local w = { model = m, sinking = false }
		table.insert(live, w)
		-- over budget: the oldest wreck that is not already going sinks now
		local alive = 0
		for _, x in live do
			if not x.sinking then
				alive += 1
			end
		end
		if alive > MAX_WRECKS then
			for _, x in live do
				if not x.sinking then
					sink(x)
					break
				end
			end
		end
		task.delay(LIFE, function()
			if m.Parent then
				sink(w)
			end
		end)
		Debris:AddItem(m, LIFE + SINK_TIME + 10) -- hard backstop
	end)
	if not ok then
		warn("[Wrecks] spawn failed:", err)
	end
end

function Wrecks.clear()
	table.clear(live)
	local f = workspace:FindFirstChild("Wrecks")
	if f then
		f:ClearAllChildren()
	end
end

return Wrecks
