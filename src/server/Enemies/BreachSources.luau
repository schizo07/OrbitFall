--!nonstrict
-- Breach sources (Director v2, docs/intensity-spec.md section 2): the places a BREACH pours out of.
-- A source is a SERVER object, not an enemy: an anchored Model (plus a hitbox part) with HP that explosions close.
--   BROOD  = a ground hole (dark crater, glowing rim, rock ring)
--   COG    = a drop pod (falls in over IT.Sources.descent.COG seconds with a streak, lands with a shockwave)
--   LUMEN  = a rift shard (a crystal that rises out of the ground)
-- Visuals are deliberately simple; a VFX pass comes later and hooks in through:
--   * the model: CollectionService tag "BreachSource", attributes Faction / Hp / MaxHp / Descending (bool) / Closed (bool) / SourceId
--   * Store "intensity" (Director snapshot): .sources = { {id, f, p, hp, max, ready} }, .ev = { k = "open" | "close", id, f, p, why, n }
--
-- API (used by Director.luau, which also drives the emission):
--   BreachSources.init(S, { groundPos = fn(x, z) -> Vector3? })
--   BreachSources.pickSpots(center, bearing, arcDeg, rMin, rMax, n, players) -> { Vector3 }   out-of-LOS / flat / free-of-parts first
--   BreachSources.open(faction, pos, hpScale?) -> src          src = { id, faction, pos, model, hitbox, hp, maxHp, readyAt, closed, emit }
--   BreachSources.onExplosion(pos, radius, core, dmg, source)  EnemyService.explode -> Director.onExplosion -> here
--   BreachSources.damage(src, amount, source) / BreachSources.close(src, why)   why = "destroyed" | "expired" | "cleared"
--   BreachSources.all() / count() / isReady(src) / describe(src, refPos) / publicList() / clear()
--   BreachSources.onOpen / BreachSources.onClose = function(src, why?)   set by the Director

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Damage = require(Shared.Damage)
local IT = require(Shared.Data.Intensity)

local BreachSources = {}

local S: { [string]: any } = {}
local G: { groundPos: ((number, number) -> Vector3?)? } = {}
local rng = Random.new()
local list: { [number]: any } = {}
local nextId = 0
local folder: Folder? = nil

BreachSources.onOpen = nil :: ((any) -> ())?
BreachSources.onClose = nil :: ((any, string) -> ())?

local V = Vector3.new

local function now(): number
	return workspace:GetServerTimeNow()
end

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = workspace:FindFirstChild("BreachSources")
	if not f then
		f = Instance.new("Folder")
		f.Name = "BreachSources"
		f.Parent = workspace
	end
	folder = f :: Folder
	return folder :: Folder
end

function BreachSources.init(s: { [string]: any }, g: any)
	S = s
	G = g or {}
end

-- Placement -------------------------------------------------------------------------------
local function flatDist(a: Vector3, b: Vector3): number
	return V(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function characters(): { Instance }
	local out: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(out, p.Character)
		end
	end
	return out
end

-- Picks `n` spots in the arc `bearing` +- arcDeg / 2, rMin..rMax studs from `center`, one per sector of the arc, preferring spots
-- that are out of line of sight of `center`, on flat walkable ground with no part inside the footprint. Falls back to relaxed rules.
function BreachSources.pickSpots(center: Vector3, bearing: number, arcDeg: number, rMin: number, rMax: number, n: number, players: { Vector3 }): { Vector3 }
	local groundPos = G.groundPos
	local out: { Vector3 } = {}
	if not groundPos or n <= 0 then
		return out
	end
	local SC = IT.Sources
	local ignore: { Instance } = characters()
	local enemies = workspace:FindFirstChild("Enemies")
	if enemies then
		table.insert(ignore, enemies)
	end
	table.insert(ignore, getFolder())
	local ray = RaycastParams.new()
	ray.FilterType = Enum.RaycastFilterType.Exclude
	ray.FilterDescendantsInstances = ignore
	ray.IgnoreWater = true
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	local ignoreBox = table.clone(ignore)
	table.insert(ignoreBox, workspace.Terrain)
	overlap.FilterDescendantsInstances = ignoreBox
	overlap.RespectCanCollide = true
	overlap.MaxParts = 1

	local half = arcDeg / 2
	local eye = center + V(0, 3, 0)

	local function try(a0: number, a1: number, strict: boolean): (Vector3?, number)
		local best: Vector3? = nil
		local bestScore = -math.huge
		for _ = 1, SC.candidates do
			local v = IT.bearingVector(rng:NextNumber(a0, a1))
			local r = rng:NextNumber(rMin, rMax)
			local wx, wz = center.X + v.X * r, center.Z + v.Z * r
			local g = groundPos(wx, wz)
			-- groundPos clamps to the map edge: a moved spot is off the map
			if g and math.abs(g.X - wx) < 0.5 and math.abs(g.Z - wz) < 0.5 then
				local ok = true
				for _, o in out do
					if flatDist(o, g) < SC.minSpacing then
						ok = false
						break
					end
				end
				if ok then
					for _, pp in players do
						if flatDist(pp, g) < 24 then -- never open on top of a squad member
							ok = false
							break
						end
					end
				end
				local score = rng:NextNumber() * 0.5
				if ok and strict then
					-- flat enough to stand on
					local slope = 0
					for _, o in { V(6, 0, 0), V(-6, 0, 0), V(0, 0, 6), V(0, 0, -6) } do
						local g2 = groundPos(g.X + o.X, g.Z + o.Z)
						if not g2 then
							ok = false
							break
						end
						slope = math.max(slope, math.abs(g2.Y - g.Y))
					end
					if ok and slope > 3.5 then
						ok = false
					end
					score -= slope * 0.1
					-- not inside a prop
					if ok and #workspace:GetPartBoundsInBox(CFrame.new(g + V(0, 3.6, 0)), V(13, 6, 13), overlap) > 0 then
						ok = false
					end
					-- out of sight is worth a lot
					if ok then
						local to = g + V(0, 3, 0)
						if workspace:Raycast(eye, to - eye, ray) then
							score += 2
						end
					end
				end
				if ok and score > bestScore then
					bestScore = score
					best = g
				end
			end
		end
		return best, bestScore
	end

	for i = 1, n do
		local a0 = bearing - half + (i - 1) / n * arcDeg
		local a1 = bearing - half + i / n * arcDeg
		local spot = try(a0, a1, true)
		if not spot then
			spot = try(bearing - half * 1.3, bearing + half * 1.3, true)
		end
		if not spot then
			spot = try(bearing - half * 1.3, bearing + half * 1.3, false)
		end
		if spot then
			table.insert(out, spot)
		end
	end
	return out
end

-- Models ----------------------------------------------------------------------------------
local function mk(model: Model, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?, transparency: number?): Part
	local p = Instance.new("Part")
	p.Name = name
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Transparency = transparency or 0
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false -- bullets and rays pass: only explosions close a source
	p.CanTouch = false
	p.CastShadow = size.Magnitude > 8 and p.Material ~= Enum.Material.Neon
	p.Parent = model
	return p
end

local function light(parent: Instance, color: Color3, brightness: number, range: number)
	local l = Instance.new("PointLight")
	l.Color = color
	l.Brightness = brightness
	l.Range = range
	l.Shadows = false
	l.Parent = parent
end

local CYL = Enum.PartType.Cylinder
local FLAT = CFrame.Angles(0, 0, math.pi / 2) -- a Cylinder part's axis is X: this stands it up (a disc lying on the ground)

local function buildBrood(model: Model, pos: Vector3)
	mk(model, "Crater", V(0.6, 16, 16), CFrame.new(pos + V(0, 0.2, 0)) * FLAT, Color3.fromRGB(36, 27, 21), Enum.Material.Slate, CYL)
	local glow = mk(model, "Glow", V(0.3, 11.5, 11.5), CFrame.new(pos + V(0, 0.35, 0)) * FLAT, Color3.fromRGB(120, 210, 60), Enum.Material.Neon, CYL, 0.45)
	mk(model, "Pit", V(0.4, 8.6, 8.6), CFrame.new(pos + V(0, 0.5, 0)) * FLAT, Color3.fromRGB(7, 6, 5), Enum.Material.SmoothPlastic, CYL)
	light(glow, Color3.fromRGB(130, 255, 80), 2.5, 22)
	local rocks = 11
	for i = 1, rocks do
		local a = (i - 1) / rocks * math.pi * 2 + rng:NextNumber(-0.18, 0.18)
		local r = 8.4 + rng:NextNumber(-0.6, 0.9)
		local size = V(rng:NextNumber(1.8, 3.4), rng:NextNumber(1.2, 2.8), rng:NextNumber(1.8, 3.6))
		local cf = CFrame.new(pos + V(math.cos(a) * r, size.Y * 0.3, math.sin(a) * r))
			* CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, math.pi * 2), rng:NextNumber(-0.3, 0.3))
		local c = if i % 2 == 0 then Color3.fromRGB(78, 60, 46) else Color3.fromRGB(62, 49, 40)
		mk(model, "Rim", size, cf, c, Enum.Material.Slate)
	end
end

local function buildCog(model: Model, pos: Vector3)
	local base = CFrame.new(pos + V(0, 4.4, 0)) * CFrame.Angles(rng:NextNumber(-0.1, 0.1), rng:NextNumber(0, math.pi * 2), rng:NextNumber(-0.1, 0.1))
	mk(model, "Body", V(11, 6.4, 6.4), base * FLAT, Color3.fromRGB(62, 68, 80), Enum.Material.Metal, CYL)
	mk(model, "Dome", V(6.4, 6.4, 6.4), base * CFrame.new(0, 5.4, 0), Color3.fromRGB(44, 48, 58), Enum.Material.Metal, Enum.PartType.Ball)
	local band = mk(model, "Band", V(0.7, 6.8, 6.8), base * CFrame.new(0, 2.2, 0) * FLAT, Color3.fromRGB(255, 60, 38), Enum.Material.Neon, CYL)
	mk(model, "Band", V(0.5, 6.7, 6.7), base * CFrame.new(0, -1.8, 0) * FLAT, Color3.fromRGB(255, 150, 40), Enum.Material.Neon, CYL)
	for i = 1, 3 do
		local a = (i - 1) / 3 * math.pi * 2
		mk(model, "Fin", V(0.5, 4.5, 3), base * CFrame.Angles(0, a, 0) * CFrame.new(3.6, -3.2, 0) * CFrame.Angles(0, 0, -0.35), Color3.fromRGB(40, 44, 52), Enum.Material.Metal)
	end
	light(band, Color3.fromRGB(255, 80, 50), 2.5, 24)
	-- the descent streak (tweened away on landing)
	mk(model, "Streak", V(1.4, 90, 1.4), base * CFrame.new(0, 53, 0), Color3.fromRGB(255, 170, 80), Enum.Material.Neon, nil, 0.3)
end

local function buildLumen(model: Model, pos: Vector3)
	mk(model, "Disc", V(0.4, 13, 13), CFrame.new(pos + V(0, 0.15, 0)) * FLAT, Color3.fromRGB(30, 20, 45), Enum.Material.SmoothPlastic, CYL)
	mk(model, "Ring", V(0.3, 15, 15), CFrame.new(pos + V(0, 0.25, 0)) * FLAT, Color3.fromRGB(170, 90, 255), Enum.Material.Neon, CYL, 0.55)
	local main = mk(model, "Crystal", V(2.8, 12, 2.8), CFrame.new(pos + V(0, 6.2, 0)) * CFrame.Angles(0.12, math.rad(45), 0.1), Color3.fromRGB(190, 110, 255), Enum.Material.Neon, nil, 0.12)
	for i = 1, 4 do
		local a = (i - 1) / 4 * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
		local h = 6 + rng:NextNumber(0, 2.5)
		mk(
			model,
			"Shard",
			V(1.6, h, 1.6),
			CFrame.new(pos + V(math.cos(a) * 3.4, h * 0.5, math.sin(a) * 3.4)) * CFrame.Angles(0, -a, 0) * CFrame.Angles(0, 0, -rng:NextNumber(0.35, 0.6)),
			Color3.fromRGB(150, 80, 230),
			Enum.Material.Neon,
			nil,
			0.2
		)
	end
	light(main, Color3.fromRGB(190, 110, 255), 3, 28)
end

local BUILDERS = { BROOD = buildBrood, COG = buildCog, LUMEN = buildLumen }

local function setHp(src: any)
	if src.model and src.model.Parent then
		src.model:SetAttribute("Hp", math.max(0, math.ceil(src.hp)))
	end
end

-- Open / close ----------------------------------------------------------------------------
-- COG: falls `from` studs in `dur` s (accelerating, like a pod); LUMEN: rises out of the ground (decelerating); BROOD: erupts at once
local function animate(src: any, final: CFrame, offsetY: number, dur: number, falling: boolean, onDone: () -> ())
	local model: Model = src.model
	task.spawn(function()
		local t0 = os.clock()
		while true do
			if src.closed or not model.Parent then
				return
			end
			local a = math.clamp((os.clock() - t0) / dur, 0, 1)
			local k = if falling then a * a else 1 - (1 - a) * (1 - a)
			model:PivotTo(final + V(0, offsetY * (1 - k), 0))
			if a >= 1 then
				break
			end
			RunService.Heartbeat:Wait()
		end
		onDone()
	end)
end

local function landFx(src: any)
	local fx = S.Fx
	if not fx then
		return
	end
	local p = src.pos
	if src.faction == "COG" then
		fx.play("Shockwave", { p = p, r = 18 })
		fx.play("Debris", { p = p, n = 14, style = "scrap" })
		fx.play("Shake", { p = p, mag = 1.6, r = 110 })
	elseif src.faction == "BROOD" then
		fx.play("Shockwave", { p = p, r = 14 }) -- the dust / rocks ("Breach" fx) went off when the hole opened
		fx.play("Shake", { p = p, mag = 1.2, r = 100 })
	else
		fx.play("Explosion", { p = p + V(0, 3, 0), r = 8, size = "S", style = "emp" })
		fx.play("Shake", { p = p, mag = 0.8, r = 90 })
	end
end

function BreachSources.open(faction: string, pos: Vector3, hpScale: number?): any
	local build = BUILDERS[faction] or buildCog
	nextId += 1
	local id = nextId
	local SC = IT.Sources
	local model = Instance.new("Model")
	model.Name = "BreachSource_" .. faction
	build(model, pos)
	local hitbox = mk(model, "Hitbox", V(13, 8, 13), CFrame.new(pos + V(0, 3, 0)), Color3.new(1, 0, 1), nil, nil, 1)
	model.PrimaryPart = hitbox

	local maxHp = SC.hp * (hpScale or 1)
	local descent = SC.descent[faction] or 1
	local t = now()
	local src: any = {
		id = id,
		faction = faction,
		pos = pos,
		model = model,
		hitbox = hitbox,
		hp = maxHp,
		maxHp = maxHp,
		openedAt = t,
		readyAt = t + descent,
		closed = false,
		emit = {}, -- the Director's emission state
	}
	model:SetAttribute("SourceId", id)
	model:SetAttribute("Faction", faction)
	model:SetAttribute("Hp", math.ceil(maxHp))
	model:SetAttribute("MaxHp", math.ceil(maxHp))
	model:SetAttribute("Descending", true)
	model:SetAttribute("Closed", false)
	CollectionService:AddTag(model, "BreachSource")

	-- starting pose for the animated entrances (set before parenting so nothing flashes at the ground)
	local landed = false
	local function onLanded()
		if landed or src.closed then
			return
		end
		landed = true
		model:SetAttribute("Descending", false)
		landFx(src)
		local streak = model:FindFirstChild("Streak")
		if streak and streak:IsA("BasePart") then
			TweenService:Create(streak, TweenInfo.new(0.4), { Transparency = 1 }):Play()
			task.delay(0.5, function()
				if streak.Parent then
					streak:Destroy()
				end
			end)
		end
		if faction == "COG" then
			-- scorch under the landed pod
			mk(model, "Scorch", V(0.3, 14, 14), CFrame.new(pos + V(0, 0.12, 0)) * FLAT, Color3.fromRGB(22, 20, 20), Enum.Material.Slate, CYL)
		end
	end

	local final = model:GetPivot()
	if faction == "COG" then
		model:PivotTo(final + V(0, 150, 0))
		model.Parent = getFolder()
		animate(src, final, 150, descent, true, onLanded)
	elseif faction == "LUMEN" then
		model:PivotTo(final + V(0, -13, 0))
		model.Parent = getFolder()
		animate(src, final, -13, descent, false, onLanded)
	else
		model.Parent = getFolder()
		task.delay(descent, onLanded)
		if S.Fx then
			S.Fx.play("Breach", { p = pos })
		end
	end

	list[id] = src
	local cb = BreachSources.onOpen
	if cb then
		local ok, err = pcall(cb, src)
		if not ok then
			warn("[BreachSources] onOpen failed:", err)
		end
	end
	return src
end

function BreachSources.isReady(src: any): boolean
	return src ~= nil and not src.closed and now() >= src.readyAt
end

-- why: "destroyed" (players closed it: fx), "expired" (breach over: quiet collapse), "cleared" (mission end: no events)
function BreachSources.close(src: any, why: string)
	if not src or src.closed then
		return
	end
	src.closed = true
	list[src.id] = nil
	local model: Model = src.model
	if model and model.Parent then
		model:SetAttribute("Closed", true)
		model:SetAttribute("Hp", 0)
	end
	if why == "destroyed" and S.Fx then
		local p = src.pos
		local style = if src.faction == "BROOD" then "goo" elseif src.faction == "LUMEN" then "emp" else "fire"
		S.Fx.play("Explosion", { p = p + V(0, 2, 0), r = 10, size = "M", style = style })
		S.Fx.play("Shockwave", { p = p, r = 18 })
		S.Fx.play("Shake", { p = p, mag = 1.4, r = 110 })
		S.Fx.play("Debris", { p = p, n = 12, style = if src.faction == "BROOD" then "rock" else "scrap" })
	end
	if model then
		local fade = if why == "destroyed" then 0.5 else 0.35
		if model.Parent and why ~= "cleared" then
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") and d ~= src.hitbox then
					TweenService:Create(d, TweenInfo.new(fade), { Transparency = 1 }):Play()
				elseif d:IsA("PointLight") then
					d.Enabled = false
				end
			end
			task.delay(fade + IT.Sources.closeDelay, function()
				if model.Parent then
					model:Destroy()
				end
			end)
		else
			model:Destroy()
		end
	end
	if why ~= "cleared" then
		local cb = BreachSources.onClose
		if cb then
			local ok, err = pcall(cb, src, why)
			if not ok then
				warn("[BreachSources] onClose failed:", err)
			end
		end
	end
end

function BreachSources.damage(src: any, amount: number, source: any?)
	if not src or src.closed or amount <= 0 or not BreachSources.isReady(src) then
		return
	end
	src.hp -= amount
	src.lastSource = source
	if src.hp <= 0 then
		BreachSources.close(src, "destroyed")
	else
		setHp(src)
	end
end

-- EnemyService.explode hook. Distance is measured to the edge of the source's hit radius (a grenade next to the hole counts).
function BreachSources.onExplosion(pos: Vector3, radius: number, core: number, dmg: number, source: any?)
	if next(list) == nil then
		return
	end
	local snapshot = {}
	for _, src in list do
		table.insert(snapshot, src)
	end
	for _, src in snapshot do
		if not src.closed and BreachSources.isReady(src) then
			local dist = math.max((src.pos + V(0, 2, 0) - pos).Magnitude - IT.Sources.hitRadius, 0)
			if dist < radius then
				local f = Damage.falloff(dist, core, radius)
				if f > 0 then
					BreachSources.damage(src, dmg * f, source)
				end
			end
		end
	end
end

-- Queries ---------------------------------------------------------------------------------
function BreachSources.all(): { any }
	local out = {}
	for _, src in list do
		table.insert(out, src)
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

function BreachSources.count(): number
	local n = 0
	for _ in list do
		n += 1
	end
	return n
end

-- Debug / DebugHook "sources"
function BreachSources.describe(src: any, ref: Vector3?): any
	return {
		id = src.id,
		faction = src.faction,
		hp = math.ceil(src.hp),
		maxHp = math.ceil(src.maxHp),
		dist = if ref then math.floor(flatDist(ref, src.pos) * 10 + 0.5) / 10 else nil,
		ready = BreachSources.isReady(src),
		pos = src.pos,
		age = math.floor(now() - src.openedAt),
	}
end

-- Replicated in the Director snapshot (Store "intensity".sources). hp is as of the last broadcast: live hp is the model attribute "Hp".
function BreachSources.publicList(): { any }
	local out = {}
	for _, src in BreachSources.all() do
		table.insert(out, { id = src.id, f = src.faction, p = src.pos, hp = math.ceil(src.hp), max = math.ceil(src.maxHp), ready = BreachSources.isReady(src) })
	end
	return out
end

function BreachSources.clear()
	for _, src in BreachSources.all() do
		BreachSources.close(src, "cleared")
	end
	table.clear(list)
	local f = workspace:FindFirstChild("BreachSources")
	if f then
		f:ClearAllChildren()
	end
end

return BreachSources
