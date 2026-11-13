--!nonstrict
-- Client renderers for enemy Fx kinds (server: src/server/Enemies/*).
--   Bolt      {id, a, v, g, style, c, life, r}     moving projectile  (pos = a + v t - (0, g t^2 / 2, 0))
--   BoltEnd   {id, p, style, r, pd?, miss?, blocked?}
--   Telegraph {shape="circle", p, r, t} | {shape="line", a, b, w, t}   red ground warning that fills over t
--   DropShip  {a, b, t?, hold?}            robot cargo drone flies in from a, drops a pod at b
--   Breach    {p}                          burrow breach (ground burst + rocks)
--   EnemyAttack {id, kind, e, p, t, ...}   roars / horns / footsteps; kind="sweepBeam" draws the Colossus laser
-- Everything lives in workspace.CurrentCamera.EnemyFx (local only, no collisions, auto-cleaned).

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local EnemyFx = {}

local Fx: any
local Audio: any
local Juice: any

local C3 = Color3.fromRGB
local RED = C3(255, 52, 40)
local RED_FILL = C3(255, 90, 50)
local ACID = C3(140, 255, 58)
local BOLT_RED = C3(255, 84, 58)
local ORANGE = C3(255, 160, 50)

local Linear = Enum.EasingStyle.Linear
local Quad = Enum.EasingStyle.Quad
local Out = Enum.EasingDirection.Out
local In = Enum.EasingDirection.In

local MAX_BOLTS = 140
local MAX_TELEGRAPHS = 48
local MAX_LIT_BOLTS = 6 -- bolts that carry a PointLight at once
local litBolts = 0
local BOLT_CORE = C3(255, 90, 40) -- robot laser: red-orange body ...
local BOLT_HOT = C3(255, 200, 170) -- ... with a warm white-hot centre (pure white Neon blooms into a blown-out blob)

-- Every instance we create gets a hard deadline. A sweeper on its own thread (independent of RenderStepped, Debris and
-- any per-effect task.delay) destroys anything past its deadline, so no code path can leave a glowing part behind.
local DEFAULT_LIFE = 8 -- anything found in the folder without a deadline lives at most this long
local MAX_LIFE = 20
local expiry: { [Instance]: number } = {}

local function expire(inst: Instance, life: number)
	expiry[inst] = os.clock() + math.clamp(life, 0, MAX_LIFE)
end

-- Helpers ---------------------------------------------------------------------------
local folder: Folder? = nil
local function getFolder(): Folder
	local cam = workspace.CurrentCamera or workspace
	if folder and folder.Parent == cam then
		return folder
	end
	local f = cam:FindFirstChild("EnemyFx")
	if not f then
		f = Instance.new("Folder")
		f.Name = "EnemyFx"
		f.Parent = cam
	end
	folder = f :: Folder
	return folder :: Folder
end

-- `life` = hard maximum lifetime (seconds); the sweeper destroys the part after it no matter what else happens
local function mk(size: Vector3, color: Color3, cf: CFrame, shape: Enum.PartType?, material: Enum.Material?, transparency: number?, life: number?): Part
	local p = Instance.new("Part")
	expire(p, life or DEFAULT_LIFE)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.Shape = shape or Enum.PartType.Block
	p.Material = material or Enum.Material.Neon
	p.Size = size
	p.Color = color
	p.Transparency = transparency or 0
	p.CFrame = cf
	p.Parent = getFolder()
	return p
end

local function tween(inst: Instance, dur: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween?
	if not inst.Parent then
		return nil
	end
	local t = TweenService:Create(inst, TweenInfo.new(dur, style or Quad, dir or Out), props)
	t:Play()
	return t
end

local function sweep()
	local now = os.clock()
	for inst, dl in expiry do
		if not inst.Parent then
			expiry[inst] = nil
		elseif now >= dl then
			expiry[inst] = nil
			inst:Destroy()
		end
	end
	-- anything that reached the folder without a deadline (or an old folder left behind by a camera swap)
	local f = folder
	if f then
		for _, c in f:GetChildren() do
			if not expiry[c] then
				expire(c, DEFAULT_LIFE)
			end
		end
	end
end

task.spawn(function()
	while true do
		task.wait(0.5)
		local ok, err = pcall(sweep)
		if not ok then
			warn("[EnemyFx] sweep failed: " .. tostring(err))
		end
	end
end)

-- Bolts are short straight slugs (rounded cylinders, axis = flight direction), never Trails or curved Beams: a Trail on a
-- moving part draws a flat ribbon that kinks where the path bends and lingers after the part is gone.
local CYL_ALONG_Z = CFrame.Angles(0, math.pi / 2, 0) -- cylinders have their axis on X; this lines it up with lookAt's -Z

-- Actors (generic per-frame callbacks) ---------------------------------------------
local actors: { (number) -> boolean } = {}
local actorCleanup: { [any]: () -> () } = {}
local bolts: { [number]: any } = {}
local boltCount = 0
local conn: RBXScriptConnection? = nil

-- bolts stop at the ground on the client too (terrain + the map's collidable parts), so a lost BoltEnd can never leave a
-- bolt lying on the ground or hanging in the air
local boltRay = RaycastParams.new()
boltRay.FilterType = Enum.RaycastFilterType.Include
boltRay.RespectCanCollide = true
boltRay.IgnoreWater = true
local boltRayMap: Instance? = nil
local boltRayInit = false
local function refreshBoltRay()
	local map = workspace:FindFirstChild("Map")
	if map ~= boltRayMap or not boltRayInit then
		boltRayInit = true
		boltRayMap = map
		boltRay.FilterDescendantsInstances = if map then { workspace.Terrain, map } else { workspace.Terrain }
	end
end
refreshBoltRay()

local function destroyBolt(b: any)
	if b.dead then
		return
	end
	b.dead = true
	b.part:Destroy()
	if b.halo then
		b.halo:Destroy()
	end
	if b.lit then
		litBolts -= 1
	end
end

local function removeBolt(id: any, b: any)
	destroyBolt(b)
	if bolts[id] == b then
		bolts[id] = nil
		boltCount -= 1
	end
end

-- returns true when the bolt is finished
local function stepBolt(b: any, now: number): boolean
	local t = now - b.t0
	if t > b.life + 0.15 or not b.part.Parent then
		return true
	end
	local pos = b.a + b.v * t
	local vel = b.v
	if b.g > 0 then
		pos -= Vector3.new(0, 0.5 * b.g * t * t, 0)
		vel = b.v - Vector3.new(0, b.g * t, 0)
	end
	local prev = b.prev
	if prev then
		local seg = pos - prev
		local m = seg.Magnitude
		if m > 0.05 and m < 2000 and workspace:Raycast(prev, seg, boltRay) then
			return true -- reached the ground: the slug vanishes there (BoltEnd plays the impact)
		end
	end
	b.prev = pos
	local cf
	if b.oriented and vel.Magnitude > 0.1 then
		local dir = vel.Unit
		local c = pos - dir * b.back -- the head of the slug sits on the projectile position, the body trails behind it
		cf = CFrame.lookAt(c, c + dir) * CYL_ALONG_Z
	else
		cf = CFrame.new(pos)
	end
	b.part.CFrame = cf
	if b.halo then
		b.halo.CFrame = cf
	end
	if b.style == "acid" then
		-- wobbling blob
		local k = 1 + 0.14 * math.sin(t * 20)
		b.part.Size = Vector3.new(1.3 * k, 1.3 / k, 1.3 * k)
	end
	return false
end

local stepWarned = false
local function stepWarn(what: string, err: any)
	if not stepWarned then
		stepWarned = true
		warn("[EnemyFx] " .. what .. " failed: " .. tostring(err))
	end
end

local function step(dt: number)
	if next(bolts) then
		refreshBoltRay()
		local now = os.clock()
		-- one bad bolt must never abort the loop (that would freeze every bolt after it in place, forever)
		for id, b in bolts do
			local ok, done = pcall(stepBolt, b, now)
			if not ok then
				stepWarn("bolt", done)
			end
			if not ok or done then
				pcall(removeBolt, id, b)
			end
		end
	end
	for i = #actors, 1, -1 do
		local fn = actors[i]
		local ok, done = pcall(fn, dt)
		if not ok then
			stepWarn("actor", done)
			local cleanup = actorCleanup[fn]
			if cleanup then
				pcall(cleanup)
			end
		end
		if not ok or done then
			actorCleanup[fn] = nil
			-- swap-remove (the actor at i may have moved if an earlier removal happened; find it again)
			local j = if actors[i] == fn then i else table.find(actors, fn)
			if j then
				local n = #actors
				actors[j] = actors[n]
				actors[n] = nil
			end
		end
	end
end

local function ensureConn()
	if not conn then
		conn = RunService.RenderStepped:Connect(step)
	end
end

-- `cleanup` runs if the actor ever errors (the actor is then dropped), so its parts never freeze on screen
local function addActor(fn: (number) -> boolean, cleanup: (() -> ())?)
	table.insert(actors, fn)
	if cleanup then
		actorCleanup[fn] = cleanup
	end
	ensureConn()
end

-- Bolts ------------------------------------------------------------------------------
local function flash(p: Vector3, color: Color3, size: number, life: number)
	if typeof(p) ~= "Vector3" then
		return
	end
	local part = mk(Vector3.one * size * 0.3, color, CFrame.new(p), Enum.PartType.Ball, nil, 0.1, life + 0.15)
	tween(part, life, { Size = Vector3.one * size, Transparency = 1 })
	task.delay(life + 0.05, function()
		if part.Parent then
			part:Destroy()
		end
	end)
end

local BOLT_SOUND = { bolt = "EnemyBolt", cannon = "EnemyCannon", acid = "AcidSpit", mortar = "Mortar" }

local function onBolt(d: any)
	if type(d) ~= "table" or d.id == nil or typeof(d.a) ~= "Vector3" or typeof(d.v) ~= "Vector3" then
		return
	end
	if boltCount >= MAX_BOLTS or bolts[d.id] then
		return
	end
	local style = d.style or "bolt"
	local life = math.clamp(tonumber(d.life) or 4, 0.1, 12)
	local partLife = life + 0.6 -- hard cap for the sweeper (stepBolts normally removes it at life + 0.15)
	local part: Part
	local halo: Part? = nil
	local oriented = false
	local back = 0 -- how far the slug's centre trails behind the projectile position (half its length)
	local lightColor: Color3? = nil
	local hq = if Fx and type(Fx.quality) == "number" then Fx.quality else 1
	local camDist = if Fx and Fx.camDistance then Fx.camDistance(d.a) else 0
	local v0: Vector3 = d.v
	local start = if v0.Magnitude > 0.1 then CFrame.lookAt(d.a, d.a + v0) * CYL_ALONG_Z else CFrame.new(d.a)
	-- straight slug: white-hot rounded core inside a soft glowing halo, both oriented along the velocity
	local function slug(len: number, coreW: number, haloW: number, haloCol: Color3, haloAlpha: number)
		part = mk(Vector3.new(len, coreW, coreW), BOLT_HOT, start, Enum.PartType.Cylinder, nil, 0, partLife)
		if hq >= 0.6 then
			halo = mk(Vector3.new(len * 1.2, haloW, haloW), haloCol, start, Enum.PartType.Cylinder, nil, haloAlpha, partLife)
		else
			part.Color = haloCol
			part.Size = Vector3.new(len, coreW * 1.6, coreW * 1.6)
		end
		oriented = v0.Magnitude > 0.1
		back = len * 0.5
	end
	local col: Color3 = if typeof(d.c) == "Color3" then d.c else BOLT_CORE
	if style == "bolt" then
		slug(4, 0.3, 0.9, col, 0.45)
	elseif style == "cannon" then
		slug(4, 0.8, 1.9, if typeof(d.c) == "Color3" then d.c else ORANGE, 0.5)
		lightColor = ORANGE
	elseif style == "mortar" then
		slug(3.5, 1.0, 2.3, if typeof(d.c) == "Color3" then d.c else ORANGE, 0.5)
		lightColor = ORANGE
	else -- acid: green-yellow blob (wobbles in stepBolts), arcs with the projectile's gravity
		style = "acid"
		part = mk(Vector3.one * 1.3, C3(190, 240, 80), CFrame.new(d.a), Enum.PartType.Ball, nil, 0.05, partLife)
		if hq >= 0.6 then
			halo = mk(Vector3.one * 2.1, ACID, CFrame.new(d.a), Enum.PartType.Ball, nil, 0.5, partLife)
		end
		lightColor = ACID
	end
	-- register immediately: nothing below may orphan the parts if it errors
	local b = {
		part = part,
		halo = halo,
		lit = false,
		a = d.a,
		v = v0,
		g = math.max(tonumber(d.g) or 0, 0),
		t0 = os.clock(),
		life = life,
		oriented = oriented,
		back = back,
		prev = nil,
		style = style,
		dead = false,
	}
	bolts[d.id] = b
	boltCount += 1
	ensureConn()

	if lightColor and hq >= 0.75 and litBolts < MAX_LIT_BOLTS then
		litBolts += 1
		b.lit = true
		local l = Instance.new("PointLight")
		l.Color = lightColor
		l.Range = 14
		l.Brightness = 1.6
		l.Shadows = false
		l.Parent = part
	end
	if style == "bolt" then
		flash(d.a, col, 1.4, 0.08)
	elseif style == "cannon" then
		flash(d.a, ORANGE, 3.2, 0.12)
	elseif style == "mortar" then
		flash(d.a, ORANGE, 3.6, 0.14)
	end
	if Fx and Fx.burst then
		if style == "acid" and camDist < 120 then
			Fx.burst("goo", d.a, 2, { scale = 0.4, speed = 0.4 })
		elseif camDist < 100 and (style == "bolt" or style == "cannon") then
			Fx.burst("sparks", d.a, 2, { scale = 0.4, speed = 0.5, color = col })
		end
	end
	local key = BOLT_SOUND[style]
	if key and Audio then
		Audio.play(key, d.a)
	end
end

local function puddle(p: Vector3, r: number, dur: number)
	dur = math.clamp(tonumber(dur) or 3, 0.3, 15)
	local pos = p
	local gp = Fx and Fx.groundAt and Fx.groundAt(p, 3, 10)
	if gp then
		pos = gp
	end
	local disc = mk(
		Vector3.new(0.12, r * 0.4, r * 0.4),
		ACID,
		CFrame.new(pos + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Enum.PartType.Cylinder,
		nil,
		0.35,
		dur + 0.2
	)
	tween(disc, 0.25, { Size = Vector3.new(0.12, r * 1.8, r * 1.8) })
	task.delay(math.max(dur - 0.9, 0.2), function()
		tween(disc, 0.9, { Transparency = 1 }, Linear)
	end)
end

local function onBoltEnd(d: any)
	if type(d) ~= "table" then
		return
	end
	local b = d.id ~= nil and bolts[d.id]
	if b then
		removeBolt(d.id, b)
	end
	if d.miss or typeof(d.p) ~= "Vector3" then
		return
	end
	local p = d.p
	local style = d.style or "bolt"
	if d.blocked then
		flash(p, C3(120, 200, 255), 3, 0.25)
		if Audio then
			Audio.play("BoltImpact", p)
		end
		return
	end
	if style == "bolt" then
		flash(p, BOLT_RED, 1.8, 0.14)
		if Fx and Fx.burst then
			Fx.burst("sparks", p, 4)
		end
		if Audio then
			Audio.play("BoltImpact", p)
		end
	elseif style == "acid" then
		local r = math.max(d.r or 4, 2)
		flash(p, ACID, r * 1.6, 0.25)
		if Fx then
			if Fx.burst then
				Fx.burst("goo", p, 8)
			end
			if Fx.splat then
				Fx.splat(p, r * 0.8, ACID)
			end
		end
		if d.pd then
			puddle(p, r * 0.9, d.pd)
		end
		if Audio then
			Audio.play("AcidSplat", p)
		end
	else
		-- cannon / mortar: the server also sends a core Explosion; add a quick scorch flash
		flash(p, ORANGE, math.max(d.r or 4, 3) * 1.2, 0.2)
	end
end

-- Telegraphs -------------------------------------------------------------------------
local telegraphs = 0

local function telegraphCircle(p: Vector3, r: number, t: number)
	local base = CFrame.new(p) * CFrame.Angles(0, 0, math.pi / 2)
	local outer = mk(Vector3.new(0.1, r * 2, r * 2), RED, base, Enum.PartType.Cylinder, nil, 0.84, t + 0.4)
	local inner = mk(Vector3.new(0.14, 0.4, 0.4), RED_FILL, base, Enum.PartType.Cylinder, nil, 0.52, t + 0.4)
	tween(inner, t, { Size = Vector3.new(0.14, r * 2, r * 2) }, Linear)
	-- pulse the rim as the fill completes
	task.delay(t, function()
		tween(outer, 0.18, { Transparency = 1 })
		tween(inner, 0.18, { Transparency = 1 })
	end)
end

local function telegraphLine(a: Vector3, b: Vector3, w: number, t: number)
	local len = (b - a).Magnitude
	if len < 0.5 then
		return
	end
	local dir = (b - a) / len
	local mid = (a + b) / 2
	local outer = mk(Vector3.new(w, 0.1, len), RED, CFrame.lookAt(mid, b), nil, nil, 0.84, t + 0.4)
	local inner = mk(Vector3.new(w * 0.94, 0.14, 0.3), RED_FILL, CFrame.lookAt(a + dir * 0.15, b), nil, nil, 0.52, t + 0.4)
	tween(inner, t, { Size = Vector3.new(w * 0.94, 0.14, len), CFrame = CFrame.lookAt(mid, b) }, Linear)
	task.delay(t, function()
		tween(outer, 0.18, { Transparency = 1 })
		tween(inner, 0.18, { Transparency = 1 })
	end)
end

local function onTelegraph(d: any)
	if type(d) ~= "table" or telegraphs >= MAX_TELEGRAPHS then
		return
	end
	if d.shape == "line" then
		if typeof(d.a) ~= "Vector3" or typeof(d.b) ~= "Vector3" then
			return
		end
	elseif typeof(d.p) ~= "Vector3" then
		return
	end
	telegraphs += 1
	local t = math.clamp(tonumber(d.t) or 1, 0.1, 6)
	task.delay(t + 0.4, function()
		telegraphs -= 1
	end)
	if d.shape == "line" then
		telegraphLine(d.a, d.b, d.w or 3, t)
	else
		telegraphCircle(d.p, d.r or 5, t)
		if Audio then
			Audio.play("Telegraph", d.p)
		end
	end
end

-- Breach -----------------------------------------------------------------------------
local DIRT = C3(110, 86, 62)

local function onBreach(d: any)
	if type(d) ~= "table" or typeof(d.p) ~= "Vector3" then
		return
	end
	local p = d.p
	local pos = p
	if Fx and Fx.groundAt then
		local gp = Fx.groundAt(p, 3, 10)
		if gp then
			pos = gp
		end
	end
	-- crater
	local crater = mk(
		Vector3.new(0.1, 4, 4),
		C3(52, 40, 32),
		CFrame.new(pos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Enum.PartType.Cylinder,
		Enum.Material.Slate,
		0.15,
		6
	)
	tween(crater, 0.3, { Size = Vector3.new(0.1, 9, 9) })
	task.delay(4, function()
		tween(crater, 1.5, { Transparency = 1 }, Linear)
	end)
	-- shock ring
	local ring = mk(
		Vector3.new(0.2, 2, 2),
		DIRT,
		CFrame.new(pos + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Enum.PartType.Cylinder,
		nil,
		0.35,
		0.6
	)
	tween(ring, 0.4, { Size = Vector3.new(0.2, 16, 16), Transparency = 1 })
	if Fx then
		if Fx.debris then
			Fx.debris(pos, { n = 9, style = "rock", speed = 0.9, up = 1.3, scale = 1.2 })
		end
		if Fx.burst then
			Fx.burst("dust", pos + Vector3.new(0, 1, 0), 16, { scale = 1.4 })
		end
	end
	if Juice then
		Juice.shake(0.5, 0.3, pos, 80)
	end
	if Audio then
		Audio.play("Breach", pos)
	end
end

-- DropShip ---------------------------------------------------------------------------
local function easeOut(u: number): number
	return 1 - (1 - u) * (1 - u)
end

local function onDropShip(d: any)
	if type(d) ~= "table" or typeof(d.a) ~= "Vector3" or typeof(d.b) ~= "Vector3" then
		return
	end
	local a: Vector3, b: Vector3 = d.a, d.b
	local tIn = math.clamp(tonumber(d.t) or 2.4, 0.2, 8)
	local hold = math.clamp(tonumber(d.hold) or 1.4, 0, 6)
	local total = tIn + hold + 3.5
	local hover = b + Vector3.new(0, 52, 0)
	local dir = hover - a
	local flatDir = Vector3.new(dir.X, 0, dir.Z)
	flatDir = if flatDir.Magnitude > 0.1 then flatDir.Unit else Vector3.new(0, 0, -1)

	local model = Instance.new("Model")
	model.Name = "DropShip"
	expire(model, total + 0.5)
	model.Parent = getFolder()
	local function part(size: Vector3, color: Color3, off: CFrame, mat: Enum.Material?): (Part, CFrame)
		local p = mk(size, color, CFrame.new(a) * off, nil, mat or Enum.Material.Metal, 0, total + 0.5)
		p.Parent = model
		return p, off
	end
	local rel: { { part: Part, off: CFrame } } = {}
	local function add(size: Vector3, color: Color3, off: CFrame, mat: Enum.Material?)
		local p = part(size, color, off, mat)
		table.insert(rel, { part = p, off = off })
		return p
	end
	add(Vector3.new(7, 2.4, 16), C3(58, 62, 74), CFrame.new(0, 0, 0))
	add(Vector3.new(14, 0.6, 5), C3(44, 47, 57), CFrame.new(0, 0.5, 1))
	add(Vector3.new(2.2, 2.2, 2.2), RED, CFrame.new(-4.6, 0.2, 4), Enum.Material.Neon)
	add(Vector3.new(2.2, 2.2, 2.2), RED, CFrame.new(4.6, 0.2, 4), Enum.Material.Neon)
	add(Vector3.new(2.6, 0.6, 2.6), ORANGE, CFrame.new(-4.6, -1.4, 4), Enum.Material.Neon)
	add(Vector3.new(2.6, 0.6, 2.6), ORANGE, CFrame.new(4.6, -1.4, 4), Enum.Material.Neon)
	local cargo = add(Vector3.new(5, 3.6, 5), C3(70, 74, 86), CFrame.new(0, -3.4, 0))
	local cargoOff = CFrame.new(0, -3.4, 0)
	local stripe = add(Vector3.new(5.2, 0.7, 5.2), C3(196, 108, 44), CFrame.new(0, -3.4, 0))
	local cargoParts = { cargo, stripe }
	for _, c in cargoParts do
		c.Anchored = true
	end

	local startT = os.clock()
	local leaveDir = Vector3.new(flatDir.X, 0.35, flatDir.Z).Unit
	local dropT = tIn + 0.15
	local dropDur = 0.75
	local dropped = false
	local landed = false
	local lastCF = CFrame.new(hover)

	if Audio then
		Audio.play("DropShip", hover)
	end

	addActor(function()
		local t = os.clock() - startT
		local pos: Vector3
		if t < tIn then
			pos = a:Lerp(hover, easeOut(t / tIn))
		elseif t < tIn + hold then
			pos = hover + Vector3.new(0, math.sin((t - tIn) * 3) * 0.4, 0)
		else
			local u = t - tIn - hold
			pos = hover + leaveDir * (u * u * 28 + u * 6)
		end
		local cf = CFrame.lookAt(pos, pos + flatDir) * CFrame.Angles(0, 0, 0)
		lastCF = cf
		for _, r in rel do
			if r.part.Parent and not (dropped and (r.part == cargo or r.part == stripe)) then
				r.part.CFrame = cf * r.off
			end
		end
		-- cargo pod falls to the ground
		if t >= dropT and not dropped then
			dropped = true
		end
		if dropped and not landed then
			local u = math.clamp((t - dropT) / dropDur, 0, 1)
			local from = (lastCF * cargoOff).Position
			local to = b + Vector3.new(0, 1.8, 0)
			local cp = from:Lerp(to, u * u)
			cargo.CFrame = CFrame.new(cp)
			stripe.CFrame = CFrame.new(cp)
			if u >= 1 then
				landed = true
				if Fx then
					if Fx.burst then
						Fx.burst("dust", b + Vector3.new(0, 1, 0), 14, { scale = 1.3 })
					end
					if Fx.shockwave then
						Fx.shockwave(b, 8, C3(255, 220, 180))
					end
				end
				if Juice then
					Juice.shake(0.6, 0.3, b, 90)
				end
				tween(cargo, 0.5, { Transparency = 1 })
				tween(stripe, 0.5, { Transparency = 1 })
			end
		end
		if t > total then
			model:Destroy()
			return true
		end
		return false
	end, function()
		model:Destroy()
	end)
end

-- EnemyAttack: roars, horns, footsteps, laser beam -------------------------------
local function onSweepBeam(d: any)
	if typeof(d.a) ~= "Vector3" or typeof(d.d) ~= "Vector3" then
		return
	end
	local o: Vector3, dir: Vector3 = d.a, d.d
	local sw: number = tonumber(d.sw) or 0
	local len: number = math.clamp(tonumber(d.len) or 60, 1, 400)
	local dur: number = math.clamp(tonumber(d.dur) or 1, 0.1, 8)
	local t0: number = tonumber(d.t0) or workspace:GetServerTimeNow()
	local core = mk(Vector3.new(1.1, 1.1, len), C3(255, 70, 60), CFrame.new(o), nil, nil, 0, dur + 1)
	local glow = mk(Vector3.new(3, 3, len), C3(255, 110, 90), CFrame.new(o), nil, nil, 0.7, dur + 1)
	if Audio then
		Audio.play("LaserSweep", o)
	end
	local function kill()
		core:Destroy()
		glow:Destroy()
	end
	addActor(function()
		local u = (workspace:GetServerTimeNow() - t0) / dur
		if u >= 1 or not core.Parent or not glow.Parent then
			kill()
			return true
		end
		u = math.max(u, 0)
		local ang = sw * (2 * u - 1)
		local dd = CFrame.Angles(0, ang, 0) * dir
		local mid = o + dd * (len / 2)
		local cf = CFrame.lookAt(mid, o + dd * len)
		core.CFrame = cf
		glow.CFrame = cf
		return false
	end, kill)
end

local function onEnemyAttack(d: any)
	local kind = d.kind
	local e = d.e
	local p = d.p
	if kind == "sweepBeam" then
		onSweepBeam(d)
		return
	end
	if not Audio then
		return
	end
	if kind == "step" then
		Audio.play("RobotStep", p)
		if Juice and (e == "COLOSSUS" or e == "TITAN") then
			Juice.shake(0.28, 0.22, p, 90)
		end
	elseif kind == "screech" then
		Audio.play("BugScreech", p)
	elseif kind == "charge" then
		Audio.play("ChargerRoar", p)
	elseif kind == "summon" then
		Audio.play("TitanRoar", p)
		if Juice then
			Juice.shake(0.7, 0.6, p, 120)
		end
	elseif e == "COLOSSUS" and (kind == "mortar" or kind == "sweep" or kind == "stomp") then
		Audio.play("ColossusHorn", p)
	elseif e == "TITAN" and (kind == "stomp" or kind == "spit") then
		Audio.play("TitanRoar", p)
	elseif kind == "cannon" then
		Audio.play("EnemyCannon", p)
	end
end

-- Init -------------------------------------------------------------------------------
function EnemyFx.init(fx: any, audio: any, juice: any)
	Fx = fx
	Audio = audio
	Juice = juice
	Fx.register("Bolt", onBolt)
	Fx.register("BoltEnd", onBoltEnd)
	Fx.register("Telegraph", onTelegraph)
	Fx.register("DropShip", onDropShip)
	Fx.register("Breach", onBreach)
	Fx.register("EnemyAttack", onEnemyAttack)
end

return EnemyFx
