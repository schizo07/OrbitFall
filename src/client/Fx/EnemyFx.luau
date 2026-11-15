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
local UserInputService = game:GetService("UserInputService")

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
-- Studio A/B Feel_PerfSaver ("touch" = phones only, "all" = everywhere): bolts more than SAVER_FAR studs from the camera
-- raycast every 2nd frame; the ray then sweeps from the last checked position, so the doubled segment cannot tunnel.
local SAVER_FAR = 60
local function stepBolt(b: any, now: number, camPos: Vector3?): boolean
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
	local skipRay = false
	if camPos and prev and (pos - camPos).Magnitude > SAVER_FAR then
		b.skipRay = not b.skipRay
		skipRay = b.skipRay
	end
	if prev and not skipRay then
		local seg = pos - prev
		local m = seg.Magnitude
		if m > 0.05 and m < 2000 and workspace:Raycast(prev, seg, boltRay) then
			return true -- reached the ground: the slug vanishes there (BoltEnd plays the impact)
		end
	end
	if not skipRay then
		b.prev = pos
	end
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
		-- perf saver (Studio A/B): far bolts raycast every 2nd frame; camPos stays nil when the saver is off
		local camPos: Vector3? = nil
		if RunService:IsStudio() then
			local mode = workspace:GetAttribute("Feel_PerfSaver")
			if mode == "all" or (mode == "touch" and UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) then
				local cam = workspace.CurrentCamera
				camPos = if cam then cam.CFrame.Position else nil
			end
		end
		-- one bad bolt must never abort the loop (that would freeze every bolt after it in place, forever)
		for id, b in bolts do
			local ok, done = pcall(stepBolt, b, now, camPos)
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

-- STAGED DAMAGE + HEAVY DEATH (footage spec §3.4.4, takeaway 6) ---------------------------------------------------------
-- Kinds with Data/Enemies def.stages (Bulwark, Charger, Colossus, Titan, Bastion) carry model attribute DmgStage 0..3 (server
-- EnemyService, thresholds EnemyData.Stages):
--   1  smoke wisps from the top              (bugs: goo drips underneath)
--   2  + glowing orange breach crack, spark bursts, darker smoke   (bugs: glowing green split, goo spurts)
--   3  + flames with a flickering light, black smoke               (bugs: bubbling ooze, heavier drips)
-- HitSeq + HitAt (server, bullet hits only) -> an impact puff at the hit point. Bastion AtkSeq with AtkKind "cannon" -> both
-- eyes (EyeL / EyeR) swell, whiten and light up over the wind-up (always on: it is the dodge telegraph).
-- Fx "Death" for these kinds -> armour plates (bugs: shell chunks) flung outward that keep burning / smoking (dripping) for a
-- few seconds; the Bastion also gets a size L fireball.
-- Studio A/B: workspace attribute Feel_StageFx (number, default 1, 0 = all of the above off except the eye telegraph);
-- client/Variants.luau group "DAMAGE STAGES". Emitters / lights / crack parts live inside the enemy model (gone with it); the
-- death plates are swept by expire(). One shared 4 Hz loop does spark bursts + fire flicker (no per-frame work per enemy).

local EnemyData = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Enemies"))

local IS_STUDIO = RunService:IsStudio()
local SMOKE_TEX = "rbxasset://textures/particles/smoke_main.dds"
local FIRE_TEX = "rbxasset://textures/particles/fire_main.dds"
local SPARK_TEX = "rbxasset://textures/particles/sparkles_main.dds"
local BREACH_ORANGE = C3(255, 130, 40)
local SPLIT_GREEN = C3(120, 255, 80)
local GOO_GREEN = C3(110, 220, 70)
local EYE_HOT = C3(255, 200, 150)
local MAX_PLATES = 36
local rngS = Random.new()

local function stageK(): number
	if not IS_STUDIO then
		return 1
	end
	local v = workspace:GetAttribute("Feel_StageFx")
	return if type(v) == "number" then math.clamp(v, 0, 3) else 1
end

local function quality(): number
	return if Fx and type(Fx.quality) == "number" then Fx.quality else 1
end

local function kp(t: number, v: number): NumberSequenceKeypoint
	return NumberSequenceKeypoint.new(t, v)
end

local function emitter(parent: Instance, props: { [string]: any }): ParticleEmitter
	local em = Instance.new("ParticleEmitter")
	em.LightInfluence = 1
	em.Rotation = NumberRange.new(0, 360)
	em.RotSpeed = NumberRange.new(-40, 40)
	for k, v in props do
		(em :: any)[k] = v
	end
	em.Parent = parent
	return em
end

type StageEntry = {
	model: Model,
	def: any,
	k: number, -- size factor (def.size / 5)
	brood: boolean,
	seed: number,
	stage: number,
	fx: { Instance },
	burstEm: ParticleEmitter?,
	nextBurst: number,
	flicker: { { light: PointLight, base: number } },
	conns: { RBXScriptConnection },
	lastPuff: number,
	eyeBase: { [BasePart]: { size: Vector3, color: Color3 } },
}
local staged: { [Model]: StageEntry } = {}
local platesLive = 0

local function bodyOf(m: Model): BasePart?
	-- mesh rigs (and most fallback builds) name the hull "Body"; by volume alone the Bulwark's front Shield plate could win
	local named = m:FindFirstChild("Body") or m:FindFirstChild("Hull")
	if named and named:IsA("BasePart") and named.Transparency < 0.9 then
		return named
	end
	local best: BasePart? = nil
	local bestV = 0
	for _, d in m:GetChildren() do
		if d:IsA("BasePart") and d.Name ~= "Root" and d.Transparency < 0.9 then
			local s = d.Size
			local v = s.X * s.Y * s.Z * (if d.Material == Enum.Material.Neon then 0.2 else 1)
			if v > bestV then
				best, bestV = d, v
			end
		end
	end
	return best
end

local function clearStageFx(s: StageEntry)
	for _, i in s.fx do
		if i.Parent then
			i:Destroy()
		end
	end
	table.clear(s.fx)
	table.clear(s.flicker)
	s.burstEm = nil
end

local function addAtt(s: StageEntry, body: BasePart, cf: CFrame): Attachment
	local a = Instance.new("Attachment")
	a.Name = "StageFx"
	a.CFrame = cf
	a.Parent = body
	table.insert(s.fx, a)
	return a
end

local function addLight(s: StageEntry, parent: Instance, color: Color3, range: number, bright: number, flicker: boolean)
	if quality() < 0.75 then
		return -- phones: no extra dynamic lights
	end
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = bright
	l.Shadows = false
	l.Parent = parent
	table.insert(s.fx, l)
	if flicker then
		table.insert(s.flicker, { light = l, base = bright })
	end
end

-- welded glowing crack on a side face of the body part, lower half ("breach in its base"); same spot every rebuild (seeded)
local function crack(s: StageEntry, body: BasePart, color: Color3, I: number, r: Random): CFrame
	local S = body.Size
	local faces = { Vector3.xAxis, -Vector3.xAxis, Vector3.zAxis, -Vector3.zAxis }
	local n = faces[r:NextInteger(1, 4)]
	local w = if n.X ~= 0 then S.Z else S.X
	local L = math.clamp(math.min(w, S.Y) * 0.5, 0.8, 7)
	local u = r:NextNumber(-0.2, 0.2) * w
	local v = r:NextNumber(-0.25, 0.1) * S.Y
	local depth = if n.X ~= 0 then S.X / 2 else S.Z / 2
	local pos = n * depth + Vector3.new(if n.X ~= 0 then 0 else u, v, if n.X ~= 0 then u else 0)
	local faceCF = CFrame.lookAt(pos, pos + n) -- local -Z = outward normal; the crack lies in local XY
	local base = body.CFrame * faceCF
	local thick = math.clamp(L * 0.07, 0.14, 0.5) * math.clamp(I, 0.6, 1.4)
	local function slab(size: Vector3, cf: CFrame, transp: number): Part
		local p = Instance.new("Part")
		p.Anchored = false
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Massless = true
		p.Material = Enum.Material.Neon
		p.Color = color
		p.Transparency = transp
		p.Size = size
		p.CFrame = cf
		p.Name = "StageCrack"
		local wc = Instance.new("WeldConstraint")
		wc.Part0 = body
		wc.Part1 = p
		wc.Parent = p
		p.Parent = body
		table.insert(s.fx, p)
		return p
	end
	-- zig-zag: a middle segment plus one off each end, bent the other way
	local a0 = r:NextNumber(-0.6, 0.6)
	local l1, l2, l3 = L * 0.45, L * 0.35, L * 0.3
	local d1 = Vector3.new(math.cos(a0), math.sin(a0), 0)
	local a2, a3 = a0 + r:NextNumber(0.6, 1.1), a0 - r:NextNumber(0.6, 1.1)
	local d2 = Vector3.new(math.cos(a2), math.sin(a2), 0)
	local d3 = Vector3.new(math.cos(a3), math.sin(a3), 0)
	local out = CFrame.new(0, 0, -0.03)
	slab(Vector3.new(l1, thick, 0.12), base * out * CFrame.Angles(0, 0, a0), 0)
	slab(Vector3.new(l2, thick * 0.8, 0.12), base * out * CFrame.new(d1 * l1 / 2 + d2 * l2 / 2) * CFrame.Angles(0, 0, a2), 0)
	slab(Vector3.new(l3, thick * 0.7, 0.12), base * out * CFrame.new(-d1 * l1 / 2 - d3 * l3 / 2) * CFrame.Angles(0, 0, a3), 0)
	-- soft breach glow behind the crack
	local glow = slab(Vector3.new(L * 0.55, L * 0.3, 0.08), base * CFrame.new(0, 0, -0.01) * CFrame.Angles(0, 0, a0), 0.45)
	addLight(s, glow, color, 6 + 3 * s.k, 1.6 * I, false)
	return faceCF
end

local function buildStage(s: StageEntry)
	clearStageFx(s)
	local stage = s.stage
	local I = stageK()
	if stage <= 0 or I <= 0 then
		return
	end
	local body = bodyOf(s.model)
	if not body then
		return
	end
	local q = quality()
	local k = s.k
	local S = body.Size
	local r = Random.new(s.seed)
	local function topAt(): CFrame
		return CFrame.new(r:NextNumber(-0.3, 0.3) * S.X, S.Y * 0.45, r:NextNumber(-0.3, 0.3) * S.Z)
	end
	if not s.brood then
		-- smoke wisps: grey at 1, darker and thicker at 2, black at 3
		local col = if stage >= 3 then { C3(52, 48, 46), C3(18, 18, 18) } elseif stage == 2 then { C3(84, 80, 76), C3(36, 34, 32) } else { C3(118, 114, 108), C3(60, 58, 56) }
		emitter(addAtt(s, body, topAt()), {
			Texture = SMOKE_TEX,
			Color = ColorSequence.new(col[1], col[2]),
			Size = NumberSequence.new({ kp(0, 0.8 * k), kp(1, (2.6 + stage * 0.5) * k) }),
			Transparency = NumberSequence.new({ kp(0, 0.4), kp(1, 1) }),
			Lifetime = NumberRange.new(1.4, 2.2 + stage * 0.3),
			Rate = (3 + stage * 3) * I * q,
			Speed = NumberRange.new(3, 5),
			SpreadAngle = Vector2.new(14, 14),
			Acceleration = Vector3.new(0.8, 1.6, 0),
			EmissionDirection = Enum.NormalId.Top,
		})
		if stage >= 2 then
			local faceCF = crack(s, body, BREACH_ORANGE, I, r)
			s.burstEm = emitter(addAtt(s, body, faceCF * CFrame.new(0, 0, -0.3)), {
				Texture = SPARK_TEX,
				Color = ColorSequence.new(C3(255, 236, 160), C3(255, 120, 40)),
				LightEmission = 1,
				LightInfluence = 0,
				Size = NumberSequence.new({ kp(0, 0.35 * math.sqrt(k)), kp(1, 0) }),
				Lifetime = NumberRange.new(0.3, 0.6),
				Rate = 0,
				Speed = NumberRange.new(12, 22),
				SpreadAngle = Vector2.new(50, 50),
				Acceleration = Vector3.new(0, -45, 0),
				Drag = 2,
				EmissionDirection = Enum.NormalId.Front,
			})
		end
		if stage >= 3 then
			for i = 1, (if k >= 2 then 3 else 2) do
				local att = addAtt(s, body, topAt())
				emitter(att, {
					Texture = FIRE_TEX,
					Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, C3(255, 230, 140)), ColorSequenceKeypoint.new(0.5, C3(255, 130, 40)), ColorSequenceKeypoint.new(1, C3(200, 50, 20)) }),
					LightEmission = 0.9,
					LightInfluence = 0,
					Size = NumberSequence.new({ kp(0, 1.4 * k), kp(1, 0.2 * k) }),
					Transparency = NumberSequence.new({ kp(0, 0.15), kp(1, 1) }),
					Lifetime = NumberRange.new(0.5, 0.9),
					Rate = 16 * I * q,
					Speed = NumberRange.new(2, 4),
					SpreadAngle = Vector2.new(10, 10),
					Acceleration = Vector3.new(0, 4, 0),
					EmissionDirection = Enum.NormalId.Top,
				})
				if i == 1 then
					addLight(s, att, C3(255, 140, 60), 10 + 4 * k, 2 * I, true)
				end
			end
		end
	else
		-- bugs: goo drips from the underside
		emitter(addAtt(s, body, CFrame.new(r:NextNumber(-0.3, 0.3) * S.X, -S.Y * 0.3, r:NextNumber(-0.3, 0.3) * S.Z)), {
			Texture = SMOKE_TEX,
			Color = ColorSequence.new(GOO_GREEN),
			LightEmission = 0.2,
			Size = NumberSequence.new({ kp(0, 0.45 * k), kp(1, 0.25 * k) }),
			Transparency = NumberSequence.new({ kp(0, 0.05), kp(1, 0.4) }),
			Lifetime = NumberRange.new(0.6, 1.0),
			Rate = (2 + stage * 2.5) * I * q,
			Speed = NumberRange.new(0.5, 2),
			Acceleration = Vector3.new(0, -55, 0),
			EmissionDirection = Enum.NormalId.Bottom,
			RotSpeed = NumberRange.new(0, 0),
		})
		if stage >= 2 then
			local faceCF = crack(s, body, SPLIT_GREEN, I, r)
			s.burstEm = emitter(addAtt(s, body, faceCF * CFrame.new(0, 0, -0.3)), {
				Texture = SMOKE_TEX,
				Color = ColorSequence.new(C3(150, 255, 110), GOO_GREEN),
				LightEmission = 0.3,
				Size = NumberSequence.new({ kp(0, 0.6 * math.sqrt(k)), kp(1, 0.25) }),
				Lifetime = NumberRange.new(0.4, 0.7),
				Rate = 0,
				Speed = NumberRange.new(6, 12),
				SpreadAngle = Vector2.new(35, 35),
				Acceleration = Vector3.new(0, -50, 0),
				EmissionDirection = Enum.NormalId.Front,
			})
		end
		if stage >= 3 then
			for _ = 1, (if k >= 2 then 3 else 2) do
				emitter(addAtt(s, body, topAt()), {
					Texture = SMOKE_TEX,
					Color = ColorSequence.new(C3(170, 255, 130), C3(80, 190, 60)),
					LightEmission = 0.5,
					Size = NumberSequence.new({ kp(0, 0.3 * k), kp(0.7, 0.9 * k), kp(1, 0.1 * k) }),
					Transparency = NumberSequence.new({ kp(0, 0.15), kp(1, 0.7) }),
					Lifetime = NumberRange.new(0.5, 0.9),
					Rate = 14 * I * q,
					Speed = NumberRange.new(1, 2.5),
					SpreadAngle = Vector2.new(25, 25),
					EmissionDirection = Enum.NormalId.Top,
				})
			end
		end
	end
end

local function onStage(s: StageEntry)
	local v = s.model:GetAttribute("DmgStage")
	local st = if type(v) == "number" then math.clamp(math.floor(v), 0, 3) else 0
	if st ~= s.stage then
		s.stage = st
		local ok, err = pcall(buildStage, s)
		if not ok then
			warn("[EnemyFx] stage fx failed: " .. tostring(err))
		end
	end
end

local function onHitPuff(s: StageEntry)
	local p = s.model:GetAttribute("HitAt")
	if typeof(p) ~= "Vector3" or not Fx then
		return
	end
	local now = os.clock()
	if now - s.lastPuff < 0.05 then
		return
	end
	s.lastPuff = now
	local I = stageK()
	if I <= 0 or (Fx.camDistance and Fx.camDistance(p) > 260) then
		return
	end
	local sc = math.clamp(s.k, 0.7, 1.6) * math.sqrt(I)
	if s.brood then
		Fx.burst("goo", p, 4 * I, { scale = 0.5 * sc })
		Fx.burst("puff", p, 2 * I, { scale = 0.55 * sc, color = C3(150, 200, 120) })
	else
		Fx.burst("puff", p, 3 * I, { scale = 0.65 * sc })
		Fx.burst("sparks", p, 5 * I, { scale = 0.7 })
	end
end

-- Bastion: both cannon eyes swell, whiten and light up over the wind-up, then cool back down
local function onAttackFlare(s: StageEntry)
	if s.def.id ~= "BASTION" or s.model:GetAttribute("AtkKind") ~= "cannon" then
		return
	end
	local wind = math.clamp(tonumber(s.model:GetAttribute("AtkWindup")) or 0.8, 0.1, 3)
	for _, name in { "EyeL", "EyeR" } do
		local eye = s.model:FindFirstChild(name)
		if eye and eye:IsA("BasePart") then
			local base = s.eyeBase[eye]
			if not base then
				base = { size = eye.Size, color = eye.Color }
				s.eyeBase[eye] = base
			end
			local light = eye:FindFirstChild("StageFlare") :: PointLight?
			if not light then
				local l = Instance.new("PointLight")
				l.Name = "StageFlare"
				l.Color = C3(255, 90, 60)
				l.Range = 16
				l.Brightness = 0
				l.Shadows = false
				l.Parent = eye
				light = l
			end
			tween(eye, wind, { Size = base.size * 1.45, Color = EYE_HOT }, Quad, In)
			tween(light :: PointLight, wind, { Brightness = 8 }, Quad, In)
			task.delay(wind + 0.08, function()
				tween(eye, 0.35, { Size = base.size, Color = base.color }, Quad, Out)
				if light and light.Parent then
					tween(light, 0.35, { Brightness = 0 }, Quad, Out)
				end
			end)
		end
	end
end

local function untrackStaged(m: Instance)
	local s = staged[m :: Model]
	if not s then
		return
	end
	staged[m :: Model] = nil
	for _, c in s.conns do
		c:Disconnect()
	end
end

local function trackStaged(m: Instance)
	if not m:IsA("Model") or staged[m] then
		return
	end
	local kind = m:GetAttribute("Kind")
	local def = type(kind) == "string" and EnemyData.get(kind) or nil
	if not def or not def.stages or m:GetAttribute("Fodder") then
		return
	end
	local id = m:GetAttribute("EnemyId")
	local s: StageEntry = {
		model = m,
		def = def,
		k = math.clamp(def.size / 5, 0.6, 2.6),
		brood = def.faction == "BROOD",
		seed = if type(id) == "number" then id else rngS:NextInteger(1, 1e6),
		stage = 0,
		fx = {},
		burstEm = nil,
		nextBurst = 0,
		flicker = {},
		conns = {},
		lastPuff = 0,
		eyeBase = {},
	}
	staged[m] = s
	table.insert(s.conns, m:GetAttributeChangedSignal("DmgStage"):Connect(function()
		onStage(s)
	end))
	table.insert(s.conns, m:GetAttributeChangedSignal("HitSeq"):Connect(function()
		onHitPuff(s)
	end))
	if def.id == "BASTION" then
		table.insert(s.conns, m:GetAttributeChangedSignal("AtkSeq"):Connect(function()
			onAttackFlare(s)
		end))
	end
	onStage(s) -- joined mid-fight
end

-- spark / spurt bursts and fire flicker for every staged enemy, 4 Hz
local function stageTick()
	local now = os.clock()
	local I = stageK()
	local q = quality()
	local cam = workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else Vector3.zero
	for m, s in staged do
		if not m.Parent then
			continue
		end
		local root = m.PrimaryPart
		local near = root == nil or (root.Position - camPos).Magnitude < 220
		local em = s.burstEm
		if em and em.Parent and near and now >= s.nextBurst then
			em:Emit(math.max(1, math.floor(rngS:NextNumber(6, 12) * I * q + 0.5)))
			s.nextBurst = now + rngS:NextNumber(0.4, 1.3) / (if s.stage >= 3 then 1.6 else 1)
		end
		for _, f in s.flicker do
			if f.light.Parent then
				f.light.Brightness = f.base * rngS:NextNumber(0.55, 1.2)
			end
		end
	end
end

-- Foundry drones (model attribute Drone = "COG" | "BROOD", server/Enemies/DroneAI.luau) ------------------------------
-- Local-only extras that follow the server-moved model: COG = a translucent blur disc + spinning blade over each Rotor*
-- part; BROOD = two translucent wings flapping at the Wing* parts. Parts live in camera.DroneFx (not the swept EnemyFx
-- folder) and go back to a pool when the drone is gone; drones further than DRONE_FX_DIST skip the extras.
local DRONE_FX_DIST = 220
local DRONE_POOL_MAX = 48
local droneFolder: Folder? = nil
local dronePool: { Part } = {}
local droneTracked: { [Model]: { any } } = {}
local droneConn: RBXScriptConnection? = nil

local function droneFxFolder(): Folder
	local cam = workspace.CurrentCamera or workspace
	if droneFolder and droneFolder.Parent == cam then
		return droneFolder
	end
	local f = cam:FindFirstChild("DroneFx")
	if not f then
		f = Instance.new("Folder")
		f.Name = "DroneFx"
		f.Parent = cam
	end
	droneFolder = f :: Folder
	return droneFolder :: Folder
end

local function dronePart(size: Vector3, color: Color3, mat: Enum.Material, transp: number, shape: Enum.PartType): Part
	local p = table.remove(dronePool)
	if not p then
		p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
	end
	local q = p :: Part
	q.Shape = shape
	q.Size = size
	q.Color = color
	q.Material = mat
	q.Transparency = transp
	q.Parent = droneFxFolder()
	return q
end

local function droneRelease(p: Part)
	if #dronePool < DRONE_POOL_MAX then
		p.Parent = nil
		table.insert(dronePool, p)
	else
		p:Destroy()
	end
end

local function untrackDrone(m: Instance)
	local items = droneTracked[m :: Model]
	if not items then
		return
	end
	droneTracked[m :: Model] = nil
	for _, it in items do
		for _, p in it.parts do
			droneRelease(p)
		end
	end
end

local function droneStep()
	local cam = workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else Vector3.zero
	local t = os.clock()
	for m, items in droneTracked do
		if not m.Parent then
			untrackDrone(m)
			continue
		end
		local root = m.PrimaryPart
		local near = root ~= nil and (root.Position - camPos).Magnitude < DRONE_FX_DIST
		for _, it in items do
			local anchor: BasePart = it.anchor
			if not anchor.Parent then
				continue
			end
			if not near then
				if not it.hidden then
					it.hidden = true
					for _, p in it.parts do
						p.Transparency = 1
					end
				end
				continue
			end
			if it.hidden then
				it.hidden = false
				for k, p in it.parts do
					p.Transparency = it.transp[k]
				end
			end
			if it.kind == "rotor" then
				-- the hub is a cylinder whose X axis points up: the blur disc and the blade sit on top and spin about X
				local top = anchor.CFrame * CFrame.new(0.4, 0, 0)
				it.parts[1].CFrame = top
				it.parts[2].CFrame = top * CFrame.Angles(t * 42 + it.a, 0, 0)
			else
				local flap = math.sin(t * 38 + it.a) * 0.65 + 0.15
				it.parts[1].CFrame = anchor.CFrame * CFrame.Angles(0, 0, it.side * flap) * CFrame.new(it.side * 1.2, 0, 0.1)
			end
		end
	end
end

local function trackDrone(m: Instance, tries: number?)
	if not m:IsA("Model") or droneTracked[m] then
		return
	end
	local style = m:GetAttribute("Drone")
	if style ~= "COG" and style ~= "BROOD" then
		return
	end
	local items = {}
	for _, c in m:GetChildren() do
		if not c:IsA("BasePart") then
			continue
		end
		if style == "COG" and string.sub(c.Name, 1, 5) == "Rotor" then
			local disc = dronePart(Vector3.new(0.1, 3.4, 3.4), Color3.fromRGB(205, 210, 220), Enum.Material.SmoothPlastic, 0.75, Enum.PartType.Cylinder)
			local blade = dronePart(Vector3.new(0.14, 0.32, 3.1), Color3.fromRGB(60, 64, 72), Enum.Material.Metal, 0.3, Enum.PartType.Block)
			table.insert(items, { kind = "rotor", anchor = c, parts = { disc, blade }, transp = { 0.75, 0.3 }, a = math.random() * 6 })
		elseif style == "BROOD" and string.sub(c.Name, 1, 4) == "Wing" then
			local wing = dronePart(Vector3.new(2.4, 0.08, 1.3), Color3.fromRGB(205, 255, 200), Enum.Material.Glass, 0.45, Enum.PartType.Block)
			table.insert(items, { kind = "wing", anchor = c, parts = { wing }, transp = { 0.45 }, side = if c.Name == "WingL" then -1 else 1, a = math.random() * 6 })
		end
	end
	if #items == 0 then
		-- children not replicated yet
		local n = tries or 0
		if n < 5 then
			task.delay(0.3, trackDrone, m, n + 1)
		end
		return
	end
	droneTracked[m] = items
	if not droneConn then
		droneConn = RunService.RenderStepped:Connect(function()
			local ok, err = pcall(droneStep)
			if not ok then
				warn("[EnemyFx] drone step failed: " .. tostring(err))
			end
		end)
	end
end

local function startDrones()
	task.spawn(function()
		local f = workspace:WaitForChild("Enemies", 120)
		if not f then
			return
		end
		for _, m in f:GetChildren() do
			trackDrone(m)
		end
		f.ChildAdded:Connect(function(m)
			task.defer(trackDrone, m)
		end)
		f.ChildRemoved:Connect(untrackDrone)
	end)
end

-- Death pop: a quick bright puff + flat ring (COG orange spark, BROOD green spore burst); the generic burst still plays
local DRONE_POP = { DRONE_COG = C3(255, 150, 70), SPOREMITE = C3(160, 255, 100) }
local function dronePop(d: any)
	local col = DRONE_POP[d.kind]
	if not col or typeof(d.p) ~= "Vector3" then
		return
	end
	if Fx and Fx.camDistance and Fx.camDistance(d.p) > 300 then
		return
	end
	local ball = mk(Vector3.new(1.2, 1.2, 1.2), col, CFrame.new(d.p), Enum.PartType.Ball, Enum.Material.Neon, 0.1, 0.6)
	tween(ball, 0.22, { Size = Vector3.new(5.5, 5.5, 5.5), Transparency = 1 })
	local ring = mk(Vector3.new(0.2, 1.5, 1.5), col, CFrame.new(d.p) * CFrame.Angles(0, 0, math.pi / 2), Enum.PartType.Cylinder, Enum.Material.Neon, 0.3, 0.6)
	tween(ring, 0.3, { Size = Vector3.new(0.1, 9, 9), Transparency = 1 })
end

-- Death: armour plates / shell chunks flung outward, still burning / dripping for a few seconds
local function onHeavyDeath(d: any)
	if DRONE_POP[d.kind] then -- foundry drones: small pop only
		dronePop(d)
		return
	end
	if d.fodder == true or typeof(d.p) ~= "Vector3" or not Fx then
		return
	end
	local def = type(d.kind) == "string" and EnemyData.get(d.kind) or nil
	if not def or not def.stages then
		return
	end
	local I = stageK()
	if I <= 0 or (Fx.camDistance and Fx.camDistance(d.p) > 350) then
		return
	end
	local p: Vector3 = d.p
	local brood = def.faction == "BROOD"
	local k = math.clamp(def.size / 5, 0.7, 2.6)
	local q = quality()
	local bastion = def.id == "BASTION"
	if bastion and Fx.explosion then
		Fx.explosion(p + Vector3.new(0, 1.5, 0), { size = "L", style = "fire" })
	end
	local count = (if bastion then 8 elseif def.class == "behemoth" then 9 else 5) * math.min(I, 1.5) * q
	local n = math.floor(count + 0.5)
	local dir: Vector3? = if typeof(d.dir) == "Vector3" then d.dir else nil
	local folder = if Fx.folder then Fx.folder else getFolder()
	local palette = if brood
		then { C3(70, 46, 40), C3(58, 36, 66), C3(98, 56, 132) }
		else { C3(72, 78, 90), C3(44, 47, 57), C3(150, 84, 44) }
	for i = 1, n do
		if platesLive >= MAX_PLATES then
			break
		end
		local ang = rngS:NextNumber(0, math.pi * 2)
		local out = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local size = Vector3.new(rngS:NextNumber(1.0, 2.0) * k, rngS:NextNumber(0.2, 0.35) * k, rngS:NextNumber(0.8, 1.6) * k)
		local life = rngS:NextNumber(4.5, 6.5)
		local part = Instance.new("Part")
		expire(part, life + 0.5)
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = if brood then Enum.Material.SmoothPlastic else Enum.Material.Metal
		part.Color = palette[(i - 1) % #palette + 1]
		part.Size = size
		part.CFrame = CFrame.new(p + out * k * 1.2 + Vector3.new(0, rngS:NextNumber(0, 1.5) * k, 0))
			* CFrame.Angles(rngS:NextNumber(0, 6.28), rngS:NextNumber(0, 6.28), rngS:NextNumber(0, 6.28))
		part.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.6, 0.2, 1, 1)
		part.Parent = folder
		local vel = out * rngS:NextNumber(18, 32) * k ^ 0.35 + Vector3.new(0, rngS:NextNumber(26, 42), 0)
		if dir then
			vel += Vector3.new(dir.X, 0, dir.Z) * 10
		end
		part.AssemblyLinearVelocity = vel
		part.AssemblyAngularVelocity = Vector3.new(rngS:NextNumber(-1, 1), rngS:NextNumber(-1, 1), rngS:NextNumber(-1, 1)) * rngS:NextNumber(4, 10)
		platesLive += 1
		local att = Instance.new("Attachment")
		att.Parent = part
		local burnFor = life - 1.2
		local ems: { ParticleEmitter } = {}
		if brood then
			table.insert(ems, emitter(att, {
				Texture = SMOKE_TEX,
				Color = ColorSequence.new(GOO_GREEN),
				LightEmission = 0.2,
				Size = NumberSequence.new({ kp(0, 0.4 * k), kp(1, 0.2 * k) }),
				Transparency = NumberSequence.new({ kp(0, 0.05), kp(1, 0.4) }),
				Lifetime = NumberRange.new(0.5, 0.9),
				Rate = 8 * q,
				Speed = NumberRange.new(0.5, 2),
				Acceleration = Vector3.new(0, -50, 0),
			}))
		else
			table.insert(ems, emitter(att, {
				Texture = FIRE_TEX,
				Color = ColorSequence.new(C3(255, 200, 110), C3(220, 70, 20)),
				LightEmission = 0.9,
				LightInfluence = 0,
				Size = NumberSequence.new({ kp(0, 0.9 * k), kp(1, 0.1) }),
				Transparency = NumberSequence.new({ kp(0, 0.2), kp(1, 1) }),
				Lifetime = NumberRange.new(0.35, 0.6),
				Rate = 12 * q,
				Speed = NumberRange.new(1, 2),
				Acceleration = Vector3.new(0, 6, 0),
			}))
			table.insert(ems, emitter(att, {
				Texture = SMOKE_TEX,
				Color = ColorSequence.new(C3(60, 56, 52), C3(20, 20, 20)),
				Size = NumberSequence.new({ kp(0, 0.6 * k), kp(1, 2.4 * k) }),
				Transparency = NumberSequence.new({ kp(0, 0.45), kp(1, 1) }),
				Lifetime = NumberRange.new(1.2, 2),
				Rate = 5 * q,
				Speed = NumberRange.new(1.5, 3),
				Acceleration = Vector3.new(0.5, 3, 0),
			}))
			if i <= 2 and q >= 0.75 then
				local l = Instance.new("PointLight")
				l.Color = C3(255, 140, 60)
				l.Range = 8 + 2 * k
				l.Brightness = 1.6
				l.Shadows = false
				l.Parent = part
				task.delay(burnFor, function()
					tween(l, 0.8, { Brightness = 0 }, Quad, Out)
				end)
			end
		end
		task.delay(0.15, function()
			if part.Parent then
				part.CanCollide = true
			end
		end)
		task.delay(burnFor, function()
			for _, em in ems do
				if em.Parent then
					em.Enabled = false
				end
			end
			tween(part, 1.1, { Transparency = 1 }, Quad, In)
		end)
		task.delay(life, function()
			platesLive -= 1
			if part.Parent then
				part:Destroy()
			end
		end)
	end
end

local function startStaged()
	task.spawn(function()
		local folder = workspace:WaitForChild("Enemies", 120)
		if not folder then
			return
		end
		for _, m in folder:GetChildren() do
			trackStaged(m)
		end
		folder.ChildAdded:Connect(function(m)
			task.defer(trackStaged, m)
		end)
		folder.ChildRemoved:Connect(untrackStaged)
	end)
	if IS_STUDIO then
		-- A/B: rebuild live stage fx when the preset changes
		workspace:GetAttributeChangedSignal("Feel_StageFx"):Connect(function()
			for _, s in staged do
				pcall(buildStage, s)
			end
		end)
		-- A/B "ENEMY AIM": the server reads Feel_EnemyAim (server/Enemies/EnemyAI.luau); Variants sets it on the client only
		local Net = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Net"))
		local function mirrorAim()
			Net.event("Action"):FireServer("studioFeel", "Feel_EnemyAim", workspace:GetAttribute("Feel_EnemyAim"))
		end
		workspace:GetAttributeChangedSignal("Feel_EnemyAim"):Connect(mirrorAim)
		if workspace:GetAttribute("Feel_EnemyAim") ~= nil then
			mirrorAim()
		end
	end
	task.spawn(function()
		while true do
			task.wait(0.25)
			local ok, err = pcall(stageTick)
			if not ok then
				warn("[EnemyFx] stage tick failed: " .. tostring(err))
			end
		end
	end)
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
	Fx.register("Death", onHeavyDeath) -- staged kinds: flung burning plates (the generic death burst stays in Fx/init.luau)
	startStaged()
	startDrones() -- foundry drones: rotor blur / wing flutter
end

return EnemyFx
