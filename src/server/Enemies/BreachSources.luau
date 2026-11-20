--!nonstrict
-- Breach sources (Director v2, docs/intensity-spec.md section 2): the places a BREACH pours out of.
-- A source is a SERVER object, not an enemy: an anchored Model (plus a hitbox part) with HP that explosions close.
--   BROOD  = a ground hole (dark crater, glowing rim, rock ring)
--   COG    = a drop pod (ground warning, sky streak, heavy impact, then four armoured blast doors blow open; all within IT.Sources.descent.COG seconds)
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

-- Terrain validation: a pod must land on walkable ground the squad can actually reach, not on a summit, a ridge or a cliff edge.
local DIRS8: { Vector3 } = {}
for i = 0, 7 do
	local a = i / 8 * math.pi * 2
	table.insert(DIRS8, V(math.cos(a), 0, math.sin(a)))
end

type Limits = {
	foot: number, -- max height change 6 studs away (the pod's footprint)
	foot2: number, -- ... 12 studs away (the opened doors)
	drop: number, -- max height above the ring 24 studs away (rejects peaks, ridges and cliff tops)
	rise: number, -- max height below that ring (rejects pits under walls)
	dy: number, -- max height difference to the squad
	grade: number, -- max rise / run on the approach from the squad
}
local STRICT: Limits = { foot = 2, foot2 = 4, drop = 7, rise = 14, dy = 12, grade = 0.7 }
local LOOSE: Limits = { foot = 3.5, foot2 = 6.5, drop = 12, rise = 20, dy = 20, grade = 0.95 }

local function terrainOk(groundPos: (number, number) -> Vector3?, g: Vector3, from: Vector3, refY: number, lim: Limits): (boolean, number)
	if math.abs(g.Y - refY) > lim.dy then
		return false, 0
	end
	local worst = 0
	for _, d in DIRS8 do
		local a = groundPos(g.X + d.X * 6, g.Z + d.Z * 6)
		local b = groundPos(g.X + d.X * 12, g.Z + d.Z * 12)
		local c = groundPos(g.X + d.X * 24, g.Z + d.Z * 24)
		if not a or not b or not c then
			return false, 0
		end
		local da = math.abs(a.Y - g.Y)
		if da > lim.foot or math.abs(b.Y - g.Y) > lim.foot2 or g.Y - c.Y > lim.drop or c.Y - g.Y > lim.rise then
			return false, 0
		end
		worst = math.max(worst, da)
	end
	-- reachable: no wall or cliff step on the straight approach from the squad
	local run = V(g.X - from.X, 0, g.Z - from.Z)
	local len = run.Magnitude
	if len > 1 then
		local steps = math.clamp(math.ceil(len / 7), 2, 12)
		local stepLen = len / steps
		local start = groundPos(from.X, from.Z)
		local prevY = if start then start.Y else from.Y
		for i = 1, steps do
			local p = groundPos(from.X + run.X * (i / steps), from.Z + run.Z * (i / steps))
			if not p or math.abs(p.Y - prevY) / stepLen > lim.grade then
				return false, 0
			end
			prevY = p.Y
		end
	end
	return true, worst
end

-- Picks `n` spots in the arc `bearing` +- arcDeg / 2, rMin..rMax studs from `center`, one per sector of the arc, preferring spots
-- that are out of line of sight of `center`, on flat walkable ground with no part inside the footprint. Falls back to relaxed rules
-- (props / sight ignored, looser terrain limits); a summit, cliff or unreachable ledge is never accepted.
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

	-- the squad's height: the spot must sit at about this level
	local refY = center.Y
	if #players > 0 then
		local sum = 0
		for _, pp in players do
			sum += pp.Y
		end
		refY = sum / #players
	end
	local function approachFrom(g: Vector3): Vector3
		local best = center
		local bestD = flatDist(center, g)
		for _, pp in players do
			local d = flatDist(pp, g)
			if d < bestD then
				bestD = d
				best = pp
			end
		end
		return best
	end

	local function try(a0: number, a1: number, strict: boolean): (Vector3?, number)
		local best: Vector3? = nil
		local bestScore = -math.huge
		local lim = if strict then STRICT else LOOSE
		for _ = 1, if strict then SC.candidates else SC.candidates * 2 do
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
				if ok then
					local good, worst = terrainOk(groundPos, g, approachFrom(g), refY, lim)
					if good then
						score -= worst * 0.1 + math.abs(g.Y - refY) * 0.04
					else
						ok = false
					end
				end
				if ok and strict then
					-- not inside a prop
					if #workspace:GetPartBoundsInBox(CFrame.new(g + V(0, 3.6, 0)), V(13, 6, 13), overlap) > 0 then
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

-- Orients a model to the terrain under `pos`: up = the ground normal over a 12-stud footprint (vertical on steep or unknown ground), random yaw.
local function surfaceCF(pos: Vector3): CFrame
	local up = Vector3.yAxis
	local gp = G.groundPos
	if gp then
		local px, nx = gp(pos.X + 6, pos.Z), gp(pos.X - 6, pos.Z)
		local pz, nz = gp(pos.X, pos.Z + 6), gp(pos.X, pos.Z - 6)
		if px and nx and pz and nz then
			local n = (pz - nz):Cross(px - nx)
			if n.Magnitude > 1e-3 and n.Unit.Y > 0.85 then
				up = n.Unit
			end
		end
	end
	local right = up:Cross(Vector3.zAxis)
	right = if right.Magnitude > 1e-3 then right.Unit else Vector3.xAxis
	return CFrame.fromMatrix(pos, right, up, right:Cross(up)) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
end

-- COG drop pod: an armoured, upright capsule ringed by four blast doors that fold out when it is ready (opened in dropPod below)
local METAL = Enum.Material.Metal
local POD_GUN = Color3.fromRGB(58, 61, 66)
local POD_CHAR = Color3.fromRGB(34, 36, 40)
local POD_IRON = Color3.fromRGB(80, 71, 64)
local POD_EMBER = Color3.fromRGB(214, 84, 22)
local POD_CRIMSON = Color3.fromRGB(176, 28, 26)
local DOOR_CLOSED = 0.06 -- radians, a hair inward
local DOOR_OPEN = -1.22 -- radians, folded outward
local DOOR_H = 7.6
local DOOR_R = 3.3 -- hinge radius (the outer foot of the door)
local STREAK_LEN = 220

local function buildCog(model: Model, pos: Vector3): any
	local base = surfaceCF(pos)
	mk(model, "Collar", V(1.2, 9.4, 9.4), base * CFrame.new(0, 0.5, 0) * FLAT, POD_CHAR, METAL, CYL)
	mk(model, "Core", V(11, 4.6, 4.6), base * CFrame.new(0, 5.6, 0) * FLAT, Color3.fromRGB(22, 21, 21), METAL, CYL)
	mk(model, "Nose", V(4.6, 4.6, 4.6), base * CFrame.new(0, 11.2, 0), POD_GUN, METAL, Enum.PartType.Ball)
	mk(model, "Beacon", V(1.2, 0.5, 1.2), base * CFrame.new(0, 13.5, 0), POD_CRIMSON, Enum.Material.Neon)
	-- the core's heat rings: dark until the doors open
	local rings = {}
	for _, y in { 3.2, 8.2 } do
		table.insert(rings, mk(model, "Ring", V(0.4, 4.85, 4.85), base * CFrame.new(0, y, 0) * FLAT, POD_EMBER, Enum.Material.Neon, CYL, 1))
	end
	local lamp = Instance.new("PointLight")
	lamp.Color = Color3.fromRGB(255, 96, 40)
	lamp.Brightness = 0
	lamp.Range = 18
	lamp.Shadows = false
	lamp.Parent = rings[1]

	local doors = {}
	for i = 1, 4 do
		local a = (i - 0.5) / 4 * math.pi * 2
		local hinge = base * CFrame.Angles(0, a, 0) * CFrame.new(DOOR_R, 0, 0)
		local d = { hinge = hinge, parts = {}, open = DOOR_OPEN + rng:NextNumber(-0.12, 0.1) }
		local function add(name: string, size: Vector3, rel: CFrame, color: Color3, mat: Enum.Material)
			local p = mk(model, name, size, hinge * CFrame.Angles(0, 0, DOOR_CLOSED) * rel, color, mat)
			table.insert(d.parts, { part = p, rel = rel })
		end
		add("Door", V(0.9, DOOR_H, 5.4), CFrame.new(-0.45, DOOR_H * 0.5, 0), if i % 2 == 0 then POD_GUN else POD_CHAR, METAL)
		add("Plate", V(1.3, 0.8, 5.8), CFrame.new(0.1, DOOR_H * 0.66, 0), POD_IRON, METAL)
		add("Vent", V(0.2, 0.35, 3.4), CFrame.new(0.1, DOOR_H * 0.38, 0), if i % 2 == 0 then POD_EMBER else POD_CRIMSON, Enum.Material.Neon)
		table.insert(doors, d)
	end

	-- retro-thruster flare under the pod and the entry streak above it (both fade on impact)
	local fade = {}
	table.insert(fade, mk(model, "Flare", V(7, 4.4, 4.4), base * CFrame.new(0, -2.4, 0) * FLAT, Color3.fromRGB(255, 110, 30), Enum.Material.Neon, CYL, 0.3))
	table.insert(fade, mk(model, "Streak", V(2.6, STREAK_LEN, 2.6), CFrame.new(pos + V(0, 14 + STREAK_LEN / 2, 0)), Color3.fromRGB(190, 60, 24), Enum.Material.Neon, nil, 0.6))
	table.insert(fade, mk(model, "StreakCore", V(0.9, STREAK_LEN, 0.9), CFrame.new(pos + V(0, 14 + STREAK_LEN / 2, 0)), Color3.fromRGB(255, 170, 80), Enum.Material.Neon, nil, 0.35))
	return { base = base, doors = doors, rings = rings, lamp = lamp, fade = fade }
end

-- Ground warning shown while the pod is still in the sky: a pulsing crimson ring and cross over the landing zone
local function buildMarker(base: CFrame): (Model, { [string]: Part })
	local m = Instance.new("Model")
	m.Name = "BreachWarning"
	local c = base * CFrame.new(0, 0.3, 0)
	local parts: { [string]: Part } = {}
	parts.Ring = mk(m, "Ring", V(0.15, 19, 19), c * FLAT, POD_CRIMSON, Enum.Material.Neon, CYL, 0.4)
	mk(m, "Mask", V(0.2, 17.2, 17.2), c * CFrame.new(0, 0.04, 0) * FLAT, Color3.fromRGB(18, 17, 17), Enum.Material.SmoothPlastic, CYL, 0.4)
	parts.Fill = mk(m, "Fill", V(0.15, 14, 14), c * CFrame.new(0, 0.1, 0) * FLAT, POD_CRIMSON, Enum.Material.Neon, CYL, 0.8)
	parts.CrossA = mk(m, "CrossA", V(15, 0.15, 0.9), c * CFrame.new(0, 0.14, 0), POD_EMBER, Enum.Material.Neon, nil, 0.5)
	parts.CrossB = mk(m, "CrossB", V(0.9, 0.15, 15), c * CFrame.new(0, 0.14, 0), POD_EMBER, Enum.Material.Neon, nil, 0.5)
	return m, parts
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
-- LUMEN: rises out of the ground (decelerating); BROOD: erupts at once; COG: see dropPod
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
	if src.faction == "BROOD" then
		fx.play("Shockwave", { p = p, r = 14 }) -- the dust / rocks ("Breach" fx) went off when the hole opened
		fx.play("Shake", { p = p, mag = 1.2, r = 100 })
	elseif src.faction ~= "COG" then
		fx.play("Explosion", { p = p + V(0, 3, 0), r = 8, size = "S", style = "emp" })
		fx.play("Shake", { p = p, mag = 0.8, r = 90 })
	end
end

-- COG pod: the whole descent (IT.Sources.descent.COG) is one timeline
--   0 .. 72 %    ground warning pulses while the pod streaks down from the sky (Juice shake via Fx "Shake" is distance-scaled)
--   72 %         impact: shockwave, scrap, heavy shake, scorch
--   +0.12 s ..   the four blast doors blow outward; the core's heat rings light up; the source is ready when they are open
local POD_ALT = 420
local function easeOutBack(x: number): number
	local c1 = 1.4
	local c3 = c1 + 1
	return 1 + c3 * (x - 1) ^ 3 + c1 * (x - 1) ^ 2
end

local function dropPod(src: any, info: any, final: CFrame, descent: number, onLanded: () -> ())
	local model: Model = src.model
	local pos: Vector3 = src.pos
	local mp: { [string]: Part }? = src.markerParts
	local fallDur = descent * 0.72
	local doorAt = fallDur + 0.12
	local doorDur = math.max(descent - doorAt, 0.25)
	task.spawn(function()
		local t0 = os.clock()
		-- entry + warning
		while true do
			if src.closed or not model.Parent then
				return
			end
			local el = os.clock() - t0
			local a = math.clamp(el / fallDur, 0, 1)
			model:PivotTo(final + V(0, POD_ALT * (1 - a ^ 1.8), 0))
			if mp then
				local pulse = 0.5 + 0.5 * math.sin(el * (10 + 14 * a)) -- blinks faster as the pod comes in
				mp.Fill.Transparency = 0.82 - 0.35 * pulse
				mp.Ring.Transparency = 0.5 - 0.25 * pulse
				mp.CrossA.Transparency = 0.55 - 0.3 * pulse
				mp.CrossB.Transparency = 0.55 - 0.3 * pulse
			end
			if a >= 1 then
				break
			end
			RunService.Heartbeat:Wait()
		end
		-- impact
		model:PivotTo(final)
		for _, p in info.fade do
			TweenService:Create(p, TweenInfo.new(0.35), { Transparency = 1 }):Play()
		end
		if src.marker then
			local m = src.marker
			for _, p in m:GetChildren() do
				if p:IsA("BasePart") then
					TweenService:Create(p, TweenInfo.new(0.3), { Transparency = 1 }):Play()
				end
			end
			task.delay(0.4, function()
				m:Destroy()
			end)
		end
		mk(model, "Scorch", V(0.3, 14, 14), info.base * CFrame.new(0, 0.12, 0) * FLAT, Color3.fromRGB(22, 20, 20), Enum.Material.Slate, CYL)
		local fx = S.Fx
		if fx then
			fx.play("Shockwave", { p = pos, r = 24 })
			fx.play("Debris", { p = pos, n = 16, style = "scrap" })
			fx.play("Debris", { p = pos, n = 8, style = "rock" })
			fx.play("Shake", { p = pos, mag = 2.4, r = 130 })
		end
		task.delay(0.5, function()
			for _, p in info.fade do
				p:Destroy()
			end
		end)
		-- blast doors
		local blown = false
		local doors = info.doors
		while true do
			if src.closed or not model.Parent then
				return
			end
			local el = os.clock() - t0
			if el >= doorAt then
				if not blown then
					blown = true
					info.lamp.Brightness = 0.1
					if fx then
						fx.play("Explosion", { p = pos + V(0, 4, 0), r = 7, size = "S", style = "fire" })
						fx.play("Debris", { p = pos + V(0, 5, 0), n = 8, style = "scrap" })
					end
				end
				local u = math.clamp((el - doorAt) / doorDur, 0, 1)
				for i, d in doors do
					local ua = math.clamp(u * 1.3 - (i - 1) * 0.07, 0, 1)
					local ang = DOOR_CLOSED + (d.open - DOOR_CLOSED) * easeOutBack(ua)
					local h = d.hinge * CFrame.Angles(0, 0, ang)
					for _, dp in d.parts do
						dp.part.CFrame = h * dp.rel
					end
				end
				for _, r in info.rings do
					r.Transparency = 1 - 0.9 * u
				end
				info.lamp.Brightness = 1.8 * u
				if u >= 1 then
					break
				end
			end
			RunService.Heartbeat:Wait()
		end
		onLanded()
	end)
end

function BreachSources.open(faction: string, pos: Vector3, hpScale: number?): any
	local build = BUILDERS[faction] or buildCog
	nextId += 1
	local id = nextId
	local SC = IT.Sources
	local model = Instance.new("Model")
	model.Name = "BreachSource_" .. faction
	local info = build(model, pos)
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
	end

	local final = model:GetPivot()
	if faction == "COG" and info then
		-- the warning marker is its own model: it stays on the ground while the pod falls
		local marker, markerParts = buildMarker(info.base)
		src.marker = marker
		src.markerParts = markerParts
		marker.Parent = getFolder()
		model:PivotTo(final + V(0, POD_ALT, 0))
		model.Parent = getFolder()
		dropPod(src, info, final, descent, onLanded)
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
	if src.marker then
		src.marker:Destroy()
		src.marker = nil
	end
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
