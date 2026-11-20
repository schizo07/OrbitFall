--!nonstrict
-- Client renderers for enemy Fx kinds (server: src/server/Enemies/*).
--   Bolt      {id, a, v, g, style, c, life, r, o?} moving projectile  (pos = a + v t - (0, g t^2 / 2, 0)); o = owner enemy id
--   BoltEnd   {id, p, style, r, pd?, miss?, blocked?, hit?}   hit = struck a trooper / decoy (bigger impact)
--   EnemyAttack kinds bolt / burst / cannon / needle with t > 0: muzzle charge-up glow over the wind-up t. Muzzle = d.m
--             (world Vector3) when sent, else d.p for bolt / burst, else the spot that kind's last bolt left from (cached
--             from Bolt.o), else a guess.
--   Straight bolts passing within ~5 studs of the local trooper play a whiz and flash the screen edge on that side.
--   Telegraph {shape="circle", p, r, t} | {shape="line", a, b, w, t}   red ground warning that fills over t
--   DropShip  {a, b, t?, hold?}            robot cargo drone flies in from a, drops a pod at b
--   Breach    {p}                          burrow breach (ground burst + rocks)
--   EnemyAttack {id, kind, e, p, t, ...}   roars / horns / footsteps; kind="sweepBeam" draws the Colossus laser
-- Everything lives in workspace.CurrentCamera.EnemyFx (local only, no collisions, auto-cleaned).

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local PlayersService = game:GetService("Players")
local SoundService = game:GetService("SoundService")

local CallInModels = require(script.Parent.Parent:WaitForChild("CallInModels"))
local EnemyDefs = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Enemies"))

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
local MAX_LIT_BOLTS = 8 -- bolts that carry a PointLight at once
local litBolts = 0
local BOLT_CORE = C3(255, 42, 20) -- #FF2A14 wide crimson-orange enemy fire bloom
local BOLT_ORANGE = C3(255, 85, 0) -- #FF5500 heavy bolt bloom accent
local BOLT_HOT = C3(255, 244, 210) -- #FFF4D2 unmistakable white-yellow core inside crimson bloom

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
	if b.tail then
		b.tail:Destroy()
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

-- Near miss: whiz + screen-edge flash + directional flinch/micro-shake on the side the shot passed ----------
local WHIZ_ID = "rbxassetid://123402454968182" -- short whoosh arc
local WHIZ_NEAR = 6.2 -- studs from the trooper's root (bolts)
local WHIZ_NEAR_HEAVY = 9.8 -- heavy cannon shells roar past wider
local WHIZ_HIT = 2.4 -- closer than this the server counts a hit (hitRadius ~2.2): no whiz
local lastWhiz = 0
local whizAtt: Attachment? = nil
local whizSound: Sound? = nil
local edgeGui: ScreenGui? = nil
local edges: { [string]: Frame } = {}

local function whizAudio(at: Vector3, heavy: boolean?)
	if not whizAtt or not whizAtt.Parent then
		local att = Instance.new("Attachment")
		att.Name = "BoltWhiz"
		att.Parent = workspace.Terrain
		local s = Instance.new("Sound")
		s.SoundId = WHIZ_ID
		s.Volume = 0.78
		s.RollOffMinDistance = 6
		s.RollOffMaxDistance = 55
		local master = SoundService:FindFirstChild("OrbitMaster")
		local group = master and master:FindFirstChild("Enemies")
		if group and group:IsA("SoundGroup") then
			s.SoundGroup = group
		end
		s.Parent = att
		whizAtt = att
		whizSound = s
	end
	local att = whizAtt :: Attachment
	local s = whizSound :: Sound
	att.WorldPosition = at
	s.Volume = if heavy then 1.05 else 0.78
	s.PlaybackSpeed = if heavy then (0.66 + math.random() * 0.14) else (1.45 + math.random() * 0.3)
	s.TimePosition = 0
	s:Play()
end

local function edgeFrame(gui: ScreenGui, name: string, pos: UDim2, size: UDim2, rot: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BorderSizePixel = 0
	f.BackgroundColor3 = BOLT_RED
	f.BackgroundTransparency = 1
	f.Position = pos
	f.Size = size
	local g = Instance.new("UIGradient")
	g.Rotation = rot
	g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	g.Parent = f
	f.Parent = gui
	return f
end

local function edgeHint(side: string, color: Color3)
	local lp = PlayersService.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	if not edgeGui or edgeGui.Parent ~= pg then
		if edgeGui then
			edgeGui:Destroy()
		end
		local gui = Instance.new("ScreenGui")
		gui.Name = "BoltWhizHint"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 2
		gui.Parent = pg
		edgeGui = gui
		edges = {
			left = edgeFrame(gui, "Left", UDim2.fromScale(0, 0), UDim2.fromScale(0.07, 1), 0),
			right = edgeFrame(gui, "Right", UDim2.fromScale(0.93, 0), UDim2.fromScale(0.07, 1), 180),
			top = edgeFrame(gui, "Top", UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.09), 90),
			bottom = edgeFrame(gui, "Bottom", UDim2.fromScale(0, 0.91), UDim2.fromScale(1, 0.09), 270),
		}
	end
	local f = edges[side]
	if not f then
		return
	end
	f.BackgroundColor3 = color
	f.BackgroundTransparency = 0.45
	TweenService:Create(f, TweenInfo.new(0.4, Quad, Out), { BackgroundTransparency = 1 }):Play()
end

-- q = closest point of the pass, lp = trooper root position
local function nearMiss(q: Vector3, lp: Vector3, color: Color3, heavy: boolean?)
	local now = os.clock()
	if now - lastWhiz < (if heavy then 0.08 else 0.12) then
		return
	end
	lastWhiz = now
	whizAudio(q, heavy)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local off = q - lp
	local rx = off:Dot(cam.CFrame.RightVector)
	local uy = off.Y
	local side = if math.abs(rx) >= math.abs(uy) * 0.8 then (if rx >= 0 then "right" else "left")
		else (if uy >= 0 then "top" else "bottom")
	edgeHint(side, color)
	if Juice then
		local flinchSign = if rx >= 0 then -1 else 1
		if heavy then
			Juice.shake(0.85, 0.24)
			Juice.kick(0.55, flinchSign * 1.05)
			Juice.punchFov(-1.2)
		else
			Juice.shake(0.34, 0.14)
			Juice.kick(0.22, flinchSign * 0.45)
		end
	end
end

local function closestOnSeg(a: Vector3, b: Vector3, p: Vector3): (Vector3, number)
	local ab = b - a
	local denom = ab:Dot(ab)
	local t = 0
	if denom > 1e-6 then
		t = math.clamp((p - a):Dot(ab) / denom, 0, 1)
	end
	return a + ab * t, t
end

-- returns true when the bolt is finished
-- Studio A/B Feel_PerfSaver ("touch" = phones only, "all" = everywhere): bolts more than SAVER_FAR studs from the camera
-- raycast every 2nd frame; the ray then sweeps from the last checked position, so the doubled segment cannot tunnel.
local SAVER_FAR = 60
local function stepBolt(b: any, now: number, camPos: Vector3?, viewPos: Vector3?, lpPos: Vector3?): boolean
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
	-- near miss: straight shots only, once per bolt, only when the segment passes the trooper
	local lastPos = b.lastPos
	b.lastPos = pos
	if lpPos and lastPos and not b.whizzed and b.oriented and b.g <= 0 then
		local dl = pos - lpPos
		if dl:Dot(dl) < 1200 then
			local q, u = closestOnSeg(lastPos, pos, lpPos)
			local d = (q - lpPos).Magnitude
			local nearR = if b.heavy then WHIZ_NEAR_HEAVY else WHIZ_NEAR
			if u > 0 and u < 1 and d <= nearR and d >= WHIZ_HIT then
				b.whizzed = true
				nearMiss(q, lpPos, b.col, b.heavy)
			end
		end
	end
	if not skipRay then
		b.prev = pos
	end
	-- far bolts get a fatter shell / tail so enemy fire reads across 100+ studs of desert haze
	if viewPos and (b.halo or b.tail) then
		local k = math.clamp((pos - viewPos).Magnitude / 52, 1, 2.35)
		if math.abs(k - b.k) > 0.1 then
			b.k = k
			if b.halo then
				local s = b.haloSize
				if b.isOrb then
					b.halo.Size = s * k
				else
					b.halo.Size = Vector3.new(s.X, s.Y * k, s.Z * k)
				end
			end
			if b.tail then
				local s = b.tailSize
				b.tail.Size = Vector3.new(s.X, s.Y * k, s.Z * k)
			end
			if b.beam then
				b.beam.Width0 = b.beamW0 * k
				b.beam.Width1 = b.beamW1 * k
			end
		end
	end
	local cf
	if b.oriented and vel.Magnitude > 0.1 then
		local dir = vel.Unit
		local c = pos - dir * b.back -- the head of the slug sits on the projectile position, the body trails behind it
		cf = CFrame.lookAt(c, c + dir) * CYL_ALONG_Z
		if b.tail then
			local ct = pos - dir * b.tailBack
			b.tail.CFrame = CFrame.lookAt(ct, ct + dir) * CYL_ALONG_Z
		end
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
		-- perf saver (on for phones / tablets; Studio A/B Feel_PerfSaver "off" / "all"): far bolts raycast every 2nd
		-- frame; camPos stays nil when the saver is off
		local camPos: Vector3? = nil
		local cam = workspace.CurrentCamera
		local viewPos: Vector3? = if cam then cam.CFrame.Position else nil
		local mode = if RunService:IsStudio() then workspace:GetAttribute("Feel_PerfSaver") else nil
		if mode == "all" or (mode ~= "off" and UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) then
			camPos = viewPos
		end
		local lpPos: Vector3? = nil
		local lp = PlayersService.LocalPlayer
		local ch = lp and lp.Character
		local root = ch and ch:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			lpPos = root.Position
		end
		-- one bad bolt must never abort the loop (that would freeze every bolt after it in place, forever)
		for id, b in bolts do
			local ok, done = pcall(stepBolt, b, now, camPos, viewPos, lpPos)
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
		conn = RunService.RenderStepped:Connect(function(dt) -- MicroProfiler label "EnemyFx.step"
			debug.profilebegin("EnemyFx.step")
			step(dt)
			debug.profileend()
		end)
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

-- Enemy models by EnemyId (workspace.Enemies), rescanned on a miss at most 4x a second
local idModels: { [any]: Model } = {}
local lastScan = 0
local function modelById(id: any): Model?
	if id == nil then
		return nil
	end
	local m = idModels[id]
	if m and m.Parent then
		return m
	end
	local now = os.clock()
	if now - lastScan < 0.25 then
		return nil
	end
	lastScan = now
	table.clear(idModels)
	local f = workspace:FindFirstChild("Enemies")
	if not f then
		return nil
	end
	for _, c in f:GetChildren() do
		if c:IsA("Model") then
			local cid = c:GetAttribute("EnemyId")
			if cid ~= nil then
				idModels[cid] = c
			end
		end
	end
	return idModels[id]
end

-- the frame a muzzle offset is stored in: the model pivot, or for a turret (TurretYaw attribute) its yawed base
local function muzzleFrame(m: Model): CFrame
	local pv = m:GetPivot()
	local yaw = m:GetAttribute("TurretYaw")
	if type(yaw) == "number" then
		return CFrame.new(pv.Position) * CFrame.Angles(0, yaw, 0)
	end
	return pv
end

local function kindOf(m: Model, id: any): any
	local k = m:GetAttribute("Kind")
	return if type(k) == "string" then k else id
end

-- last seen muzzle offset + bolt colour per enemy kind (from Bolt.o), used by the charge-up glow
local muzzleCache: { [any]: { off: Vector3, col: Color3 } } = {}
local function rememberMuzzle(id: any, a: Vector3, col: Color3)
	local m = modelById(id)
	if not m then
		return
	end
	local off = muzzleFrame(m):PointToObjectSpace(a)
	if off.Magnitude > 80 then
		return
	end
	muzzleCache[kindOf(m, id)] = { off = off, col = col }
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
	local tail: Part? = nil
	local tailBack = 0
	local streakBeam: Beam? = nil
	local beamW0, beamW1 = 0, 0
	local isOrb = false
	-- Unmistakable enemy fire lane: white-yellow core (#FFF4D2) inside wide crimson-orange bloom (#FF2A14 / #FF5500).
	-- Straight camera-facing tapered Beam ribbon attached rigidly along local -X (cylinder flight tail) never kinks and
	-- gives ~80-120 ms visual streak dwell across 100+ studs of haze.
	local function attachStreakBeam(host: Part, length: number, w0: number, w1: number, coreC: Color3, bloomC: Color3)
		if hq < 0.45 then
			return
		end
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(length * 0.15, 0, 0) -- head end (+X along CYL_ALONG_Z)
		a0.Parent = host
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(-length, 0, 0) -- tapered crimson tail behind head
		a1.Parent = host
		local bm = Instance.new("Beam")
		bm.Attachment0 = a0
		bm.Attachment1 = a1
		bm.FaceCamera = true
		bm.Segments = 1
		bm.LightEmission = 1
		bm.LightInfluence = 0
		bm.Brightness = 2.2
		bm.Width0 = w0
		bm.Width1 = w1
		bm.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, coreC),
			ColorSequenceKeypoint.new(0.22, bloomC),
			ColorSequenceKeypoint.new(1, bloomC),
		})
		bm.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.08),
			NumberSequenceKeypoint.new(0.45, 0.32),
			NumberSequenceKeypoint.new(1, 1),
		})
		bm.Parent = host
		streakBeam = bm
		beamW0, beamW1 = w0, w1
	end
	local function slug(coreLen: number, coreW: number, shellLen: number, shellW: number, tailLen: number, bloomCol: Color3, coreCol: Color3)
		part = mk(Vector3.new(coreLen, coreW, coreW), coreCol, start, Enum.PartType.Cylinder, nil, 0, partLife)
		if hq >= 0.4 then
			halo = mk(Vector3.new(shellLen, shellW, shellW), bloomCol, start, Enum.PartType.Cylinder, nil, 0.34, partLife)
		else
			part.Color = bloomCol
			part.Size = Vector3.new(coreLen, shellW * 0.78, shellW * 0.78)
		end
		if hq >= 0.6 then
			tail = mk(Vector3.new(tailLen, shellW * 0.46, shellW * 0.46), bloomCol, start, Enum.PartType.Cylinder, nil, 0.58, partLife)
		end
		attachStreakBeam(part, math.max(tailLen * 1.45, 9), shellW * 1.35, 0.14, coreCol, bloomCol)
		oriented = v0.Magnitude > 0.1
		back = shellLen * 0.42
		tailBack = shellLen * 0.5 + tailLen * 0.5
	end
	local function heavyOrb(coreD: number, haloD: number, tailLen: number, bloomCol: Color3, coreCol: Color3)
		isOrb = true
		part = mk(Vector3.one * coreD, coreCol, start, Enum.PartType.Ball, nil, 0, partLife)
		halo = mk(Vector3.one * haloD, bloomCol, start, Enum.PartType.Ball, nil, 0.36, partLife)
		if hq >= 0.55 then
			tail = mk(Vector3.new(tailLen, haloD * 0.42, haloD * 0.42), bloomCol, start, Enum.PartType.Cylinder, nil, 0.55, partLife)
		end
		attachStreakBeam(part, math.max(tailLen * 1.4, 11), haloD * 1.15, 0.22, coreCol, bloomCol)
		oriented = v0.Magnitude > 0.1
		back = 0
		tailBack = haloD * 0.35 + tailLen * 0.5
	end
	local rawCol: Color3? = if typeof(d.c) == "Color3" then d.c else nil
	local isCoolEnemy = rawCol ~= nil and rawCol.B > rawCol.R * 1.15 -- Lumen violet/cyan keeps its cool hue
	local col: Color3 = if isCoolEnemy then rawCol :: Color3 else BOLT_CORE
	local coreCol: Color3 = if isCoolEnemy then (rawCol :: Color3):Lerp(Color3.new(1, 1, 1), 0.75) else BOLT_HOT
	local cls = d.cls
	local ek = d.ek
	local isHeavy = d.hv == true or style == "cannon" or style == "mortar" or cls == "heavy" or cls == "behemoth"
	local isFodder = ek == "TINKER_SWARM" or ek == "DRONE_COG"
	local speedMag = v0.Magnitude
	-- ~80-120 ms visual streak length scaled by projectile speed (clamped for readability)
	local dwellLen = math.clamp(speedMag * 0.10, 7.5, 16.5)
	if style == "bolt" then
		if isFodder then
			slug(2.6, 0.42, 4.2, 1.2, dwellLen * 0.75, col, coreCol)
		elseif isHeavy then
			heavyOrb(1.65, 3.4, dwellLen * 1.1, if isCoolEnemy then col else BOLT_CORE, coreCol)
		else
			slug(4.2, 0.56, 6.8, 1.65, dwellLen, col, coreCol)
		end
		if camDist < 170 then
			lightColor = col
		end
	elseif style == "cannon" then
		col = if isCoolEnemy then col else BOLT_ORANGE
		heavyOrb(2.2, 4.6, dwellLen * 1.2, col, coreCol)
		lightColor = col
	elseif style == "mortar" then
		col = if isCoolEnemy then col else BOLT_ORANGE
		heavyOrb(2.0, 4.2, dwellLen * 0.95, col, coreCol)
		lightColor = col
	else -- acid: green-yellow blob (wobbles in stepBolts), arcs with the projectile's gravity
		col = ACID
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
		tail = tail,
		tailBack = tailBack,
		beam = streakBeam,
		beamW0 = beamW0,
		beamW1 = beamW1,
		isOrb = isOrb,
		haloSize = if halo then halo.Size else nil,
		tailSize = if tail then tail.Size else nil,
		k = 1,
		col = col,
		heavy = isHeavy,
		cls = cls,
		whizzed = false,
		lastPos = nil,
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
		l.Range = if isHeavy then 18 elseif style == "bolt" then 10 else 14
		l.Brightness = if isHeavy then 2.1 elseif style == "bolt" then 1.4 else 1.6
		l.Shadows = false
		l.Parent = part
	end
	if d.o ~= nil then
		rememberMuzzle(d.o, d.a, col)
	end
	if style == "bolt" then
		flash(d.a, col:Lerp(BOLT_HOT, 0.5), if isFodder then 1.9 else 2.8, 0.11)
	elseif style == "cannon" then
		flash(d.a, BOLT_HOT, 2.4, 0.1)
		flash(d.a, ORANGE, 5.2, 0.17)
		if Juice then
			Juice.shake(0.55, 0.22, d.a, 50)
		end
	elseif style == "mortar" then
		flash(d.a, BOLT_HOT, 2.6, 0.11)
		flash(d.a, ORANGE, 5.0, 0.18)
		if Juice then
			Juice.shake(0.65, 0.25, d.a, 65)
		end
	end
	if Fx and Fx.burst then
		if style == "acid" and camDist < 120 then
			Fx.burst("goo", d.a, 2, { scale = 0.4, speed = 0.4 })
		elseif style == "cannon" or style == "mortar" then
			if camDist < 160 then
				Fx.burst("sparks", d.a, 7, { scale = 0.85, speed = 0.9, color = ORANGE })
				Fx.burst("puff", d.a, 3, { scale = 1.0 })
			end
		elseif camDist < 110 and style == "bolt" then
			Fx.burst("sparks", d.a, if isFodder then 2 else 4, { scale = 0.5, speed = 0.6, color = col })
		end
	end
	local key = BOLT_SOUND[style]
	if key and Audio then
		if style == "cannon" then
			Audio.play(key, d.a, { volume = 1.25, pitch = if cls == "behemoth" then 0.78 else 0.88, priority = 4 })
		elseif style == "bolt" and isFodder then
			Audio.play(key, d.a, { volume = 0.75, pitch = 1.15 })
		else
			Audio.play(key, d.a)
		end
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

local lastBoltScorch = 0
local function onBoltEnd(d: any)
	if type(d) ~= "table" then
		return
	end
	local b = d.id ~= nil and bolts[d.id]
	local bcol: Color3 = if b and typeof(b.col) == "Color3" then b.col else BOLT_RED
	local bHeavy = d.hv == true or (b and b.heavy == true) or d.style == "cannon" or d.style == "mortar"
	if b then
		removeBolt(d.id, b)
	end
	if d.miss or typeof(d.p) ~= "Vector3" then
		return
	end
	local p = d.p
	local style = d.style or "bolt"
	if d.blocked then
		flash(p, C3(120, 200, 255), if bHeavy then 5.2 else 3, 0.25)
		if Fx and Fx.burst then
			Fx.burst("sparks", p, if bHeavy then 12 else 5, { color = C3(130, 220, 255) })
		end
		if bHeavy and Juice then
			Juice.trauma(1.2, 0.3, p, 85)
		end
		if Audio then
			Audio.play("BoltImpact", p, { volume = if bHeavy then 1.2 else 1 })
		end
		return
	end
	local hq = if Fx and type(Fx.quality) == "number" then Fx.quality else 1
	local cDist = if Fx and Fx.camDistance then Fx.camDistance(p) else 0
	if style == "bolt" then
		if d.hit then
			-- struck a trooper: crisp multi-layer impact flash + spark burst
			flash(p, bcol, 3.8, 0.18)
			flash(p, bcol:Lerp(BOLT_HOT, 0.65), 1.9, 0.11)
			if Fx and Fx.burst then
				Fx.burst("sparks", p, 11, { color = bcol, speed = 1.1 })
			end
		else
			-- ground / wall: crisp flash + sparks + lightweight scorch
			flash(p, bcol:Lerp(BOLT_HOT, 0.4), 2.1, 0.13)
			if Fx and Fx.burst and cDist < 150 then
				Fx.burst("sparks", p, 5, { color = bcol, scale = 0.8 })
				Fx.burst("puff", p, 1, { scale = 0.55 })
			end
			local now = os.clock()
			if Fx and Fx.scorch and hq >= 0.5 and cDist < 110 and now - lastBoltScorch > 0.22 then
				lastBoltScorch = now
				Fx.scorch(p, 1.1)
			end
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
		-- cannon / mortar: multi-layer flash + sparks + scorch (Blast handles the main fireball & explosion trauma)
		local r = math.max(d.r or 5, 3.5)
		flash(p, BOLT_HOT, r * 0.85, 0.12)
		flash(p, ORANGE, r * (if d.hit then 1.8 else 1.45), 0.24)
		if Fx and Fx.burst and cDist < 200 then
			Fx.burst("sparks", p, 14, { color = ORANGE, scale = 1.15, speed = 1.25 })
		end
		if Fx and Fx.scorch and hq >= 0.45 and cDist < 180 then
			Fx.scorch(p, r * 0.85)
		end
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
	-- Mesh ship (Data/Meshes callin_cog_dropship; nose -Z; Hook_1..4 grip the cargo from above). Its origin is the underside, so
	-- it is lowered by SHIP_DROP to keep the body centred on the old hover point. Part-built ship as the fallback.
	local SHIP_DROP = 6.5
	local meshShip = CallInModels.get("callin_cog_dropship")
	local hooks: { [Part]: { pivot: Vector3, sign: number } } = {}
	local cargo: Part
	local stripe: Part
	local cargoOff: CFrame
	if meshShip then
		local rig = CallInModels.rig(meshShip)
		local shift = CFrame.new(0, -SHIP_DROP, 0)
		for name, p in rig.parts do
			p.CastShadow = false
			p.Parent = model
			table.insert(rel, { part = p, off = shift * rig.rel[p] })
			local n = tonumber(string.match(name, "^Hook_(%d)$"))
			if n then
				hooks[p] = { pivot = CallInModels.pivot(rig, "callin_cog_dropship", name) + Vector3.new(0, -SHIP_DROP, 0), sign = if n % 2 == 0 then 1 else -1 }
			end
		end
		meshShip:Destroy()
		cargoOff = CFrame.new(0, -SHIP_DROP - 1.5, 0.53) -- hangs under the hooks
		cargo = add(Vector3.new(4.6, 3, 12.6), C3(70, 74, 86), cargoOff)
		stripe = add(Vector3.new(4.8, 0.8, 12.8), C3(196, 108, 44), cargoOff)
	else
		add(Vector3.new(7, 2.4, 16), C3(58, 62, 74), CFrame.new(0, 0, 0))
		add(Vector3.new(14, 0.6, 5), C3(44, 47, 57), CFrame.new(0, 0.5, 1))
		add(Vector3.new(2.2, 2.2, 2.2), RED, CFrame.new(-4.6, 0.2, 4), Enum.Material.Neon)
		add(Vector3.new(2.2, 2.2, 2.2), RED, CFrame.new(4.6, 0.2, 4), Enum.Material.Neon)
		add(Vector3.new(2.6, 0.6, 2.6), ORANGE, CFrame.new(-4.6, -1.4, 4), Enum.Material.Neon)
		add(Vector3.new(2.6, 0.6, 2.6), ORANGE, CFrame.new(4.6, -1.4, 4), Enum.Material.Neon)
		cargo = add(Vector3.new(5, 3.6, 5), C3(70, 74, 86), CFrame.new(0, -3.4, 0))
		cargoOff = CFrame.new(0, -3.4, 0)
		stripe = add(Vector3.new(5.2, 0.7, 5.2), C3(196, 108, 44), CFrame.new(0, -3.4, 0))
	end
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

	local function posAt(t: number): Vector3
		if t < tIn then
			return a:Lerp(hover, easeOut(t / tIn))
		elseif t < tIn + hold then
			return hover + Vector3.new(0, math.sin((t - tIn) * 3) * 0.4, 0)
		end
		local u = t - tIn - hold
		return hover + leaveDir * (u * u * 28 + u * 6)
	end

	-- Air Defence side objective (server/Objectives/SideAirDefence.luau): d.kill = seconds after the start when an AA
	-- missile from d.aa hits the ship; the hull breaks up and falls, the cargo pod never drops.
	local killT = tonumber(d.kill)
	local aa: Vector3? = if typeof(d.aa) == "Vector3" then d.aa else nil
	local MISSILE_T = 1.1
	local missile: Part? = nil
	local shotDown = false
	if killT then
		dropT = math.huge
		local launchIn = math.max(0, killT - MISSILE_T)
		task.delay(launchIn, function()
			if not model.Parent or not aa then
				return
			end
			local m = mk(Vector3.new(0.7, 0.7, 2.6), C3(255, 170, 70), CFrame.new(aa), nil, Enum.Material.Neon, 0, MISSILE_T + 1)
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, 0, 1.2)
			a0.Parent = m
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(0, 0, 0.6)
			a1.Parent = m
			local tr = Instance.new("Trail")
			tr.Attachment0, tr.Attachment1 = a0, a1
			tr.Lifetime = 0.9
			tr.WidthScale = NumberSequence.new(1, 3.5)
			tr.Color = ColorSequence.new(C3(235, 225, 210))
			tr.Transparency = NumberSequence.new(0.2, 1)
			tr.FaceCamera = true
			tr.Parent = m
			missile = m
			if Audio then
				Audio.play("MissileLaunch", aa)
			end
			if Fx and Fx.burst then
				Fx.burst("dust", aa, 10, { scale = 1.2 })
			end
		end)
	end

	addActor(function()
		local t = os.clock() - startT
		-- AA missile homing on the ship (arcs up first)
		local m = missile
		if m and m.Parent and killT and aa then
			local u = math.clamp((t - (killT - MISSILE_T)) / MISSILE_T, 0, 1)
			local tgt = posAt(math.min(t, killT))
			local p = aa:Lerp(tgt, u ^ 1.3) + Vector3.new(0, math.sin(u * math.pi) * 18, 0)
			local ahead = aa:Lerp(tgt, math.min(1, u + 0.05) ^ 1.3) + Vector3.new(0, math.sin(math.min(1, u + 0.05) * math.pi) * 18, 0)
			if (ahead - p).Magnitude > 0.01 then
				m.CFrame = CFrame.lookAt(p, ahead)
			end
		end
		if killT and t >= killT and not shotDown then
			shotDown = true
			if m then
				m:Destroy()
			end
			local at = lastCF.Position
			if Fx then
				if Fx.explosion then
					Fx.explosion(at, { size = "L", style = "fire" })
				end
				if Fx.debris then
					Fx.debris(at, { n = 16, style = "scrap", speed = 1.3, up = 0.6, scale = 1.3 })
				end
			end
			-- the hull breaks apart and tumbles to the ground, a last small blast where the big piece lands
			for i, r in rel do
				local piece = r.part
				if piece.Parent then
					local off = Vector3.new(math.random(-14, 14), 0, math.random(-14, 14))
					local gp = at + off
					local hit = if Fx and Fx.groundAt then Fx.groundAt(gp, 0, 400) else nil
					local land = if hit then hit else Vector3.new(gp.X, b.Y, gp.Z)
					local fall = 1.3 + math.random() * 0.6
					tween(piece, fall, {
						CFrame = CFrame.new(land + Vector3.new(0, 0.6, 0))
							* CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6),
					}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
					if i == 1 then
						task.delay(fall, function()
							if Fx and Fx.explosion then
								Fx.explosion(land, { size = "M", style = "fire" })
							end
						end)
					end
					task.delay(fall + 1.5, function()
						tween(piece, 1, { Transparency = 1 }, Linear)
					end)
				end
			end
			total = math.min(total, t + 4.5)
		end
		if shotDown then
			if t > total then
				model:Destroy()
				return true
			end
			return false
		end
		local pos = posAt(t)
		local cf = CFrame.lookAt(pos, pos + flatDir) * CFrame.Angles(0, 0, 0)
		lastCF = cf
		local hookU = math.clamp((t - dropT) / 0.4, 0, 1) -- mesh ship: the hooks let go as the cargo drops
		for _, r in rel do
			if r.part.Parent and not (dropped and (r.part == cargo or r.part == stripe)) then
				local hk = hooks[r.part]
				if hk and hookU > 0 then
					r.part.CFrame = cf * CallInModels.hinge(hk.pivot, CFrame.Angles(0, 0, hk.sign * math.rad(55) * hookU)) * r.off
				else
					r.part.CFrame = cf * r.off
				end
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

-- Muzzle charge-up: a glow ball (hot core + soft shell, small light) grows at the muzzle over the shot's wind-up and
-- follows the enemy. Parts are pooled; parked parts sit outside the workspace.
local CHARGE_KINDS = { bolt = true, burst = true, cannon = true, needle = true }
local FACTION_CHARGE = { COG = C3(255, 110, 50), LUMEN = C3(110, 235, 255), BROOD = ACID }
local MAX_CHARGES = 14
local MAX_LIT_CHARGES = 6
local GUESS_PARTS = { "Muzzle", "Gun", "BarrelL", "Barrel", "CannonA", "Eye" }
local charges = 0
local litCharges = 0
local chargePool: { Part } = {}

local function chargePart(color: Color3, alpha: number, life: number): Part
	while #chargePool > 0 do
		local p = table.remove(chargePool) :: Part
		local ok = pcall(function()
			p.Parent = getFolder()
		end)
		if ok then
			expire(p, life)
			p.Color = color
			p.Transparency = alpha
			return p
		end
	end
	return mk(Vector3.one * 0.2, color, CFrame.new(), Enum.PartType.Ball, nil, alpha, life)
end

local function releaseCharge(p: Part)
	expiry[p] = nil
	local l = p:FindFirstChildOfClass("PointLight")
	if l then
		l.Enabled = false
	end
	local ok = pcall(function()
		p.Parent = nil
	end)
	if ok and #chargePool < 24 then
		table.insert(chargePool, p)
	elseif ok then
		p:Destroy()
	end
end

-- local muzzle offset (in muzzleFrame) for a fresh charge-up
local function guessMuzzle(m: Model, kind: any, def: any, frame: CFrame): Vector3
	local cached = muzzleCache[kind]
	if cached then
		return cached.off
	end
	for _, name in GUESS_PARTS do
		local part = m:FindFirstChild(name, true)
		if part and part:IsA("BasePart") then
			local s = part.Size
			local front = part.Position + frame.LookVector * math.max(s.X, s.Y, s.Z) * 0.5
			return frame:PointToObjectSpace(front)
		end
	end
	local size = if def and type(def.size) == "number" then def.size else 2
	return Vector3.new(0, size * 1.2, -size * 0.6)
end

local lastChargeCueReg = 0
local lastChargeCueHeavy = 0
local function chargeUp(d: any)
	local windup = tonumber(d.t) or 0
	if windup < 0.12 then
		return
	end
	windup = math.min(windup, 3)
	if charges >= MAX_CHARGES then
		return
	end
	local m = modelById(d.id)
	if not m then
		return
	end
	local kind = if type(d.e) == "string" then d.e else kindOf(m, d.id)
	local def = if type(kind) == "string" then EnemyDefs.get(kind) else nil
	local heavy = d.kind == "cannon" or (def ~= nil and (def.class == "heavy" or def.class == "behemoth"))
	local frame = muzzleFrame(m)
	local off: Vector3
	-- bolt / burst volleys send the muzzle point as p; other kinds send the enemy root there
	local sent: Vector3? = if typeof(d.m) == "Vector3" then d.m
		elseif (d.kind == "bolt" or d.kind == "burst") and typeof(d.p) == "Vector3" then d.p
		else nil
	if sent and (sent - frame.Position).Magnitude < 60 then
		off = frame:PointToObjectSpace(sent)
	else
		off = guessMuzzle(m, kind, def, frame)
	end
	local start = frame * off
	local dist = if Fx and Fx.camDistance then Fx.camDistance(start) else 0
	if dist > (if heavy then 260 else 170) then
		return
	end
	-- Brief crisp audio cue before firing (rate-limited so packs stay clean)
	if Audio then
		local nowT = os.clock()
		if heavy and dist < 200 and nowT - lastChargeCueHeavy > 0.35 then
			lastChargeCueHeavy = nowT
			Audio.play("EMPPulse", start, { volume = 0.65, pitch = 0.78, priority = 3 })
			Audio.play("Telegraph", start, { volume = 0.5, pitch = 0.64, priority = 3 })
		elseif not heavy and dist < 95 and nowT - lastChargeCueReg > 0.24 then
			lastChargeCueReg = nowT
			Audio.play("ShotVolt", start, { volume = 0.22, pitch = 1.65, priority = 1 })
		end
	end
	local cached = muzzleCache[kind]
	local col: Color3 = if cached then cached.col
		elseif d.kind == "cannon" then ORANGE
		else (def and FACTION_CHARGE[def.faction]) or FACTION_CHARGE.COG
	local hq = if Fx and type(Fx.quality) == "number" then Fx.quality else 1
	local coreMax = if heavy then 1.9 else 0.9
	local shellMax = if heavy then 4.2 else 2.0
	-- far away the glow grows a little so it still reads
	local far = math.clamp(dist / 80, 1, 1.6)
	coreMax *= far
	shellMax *= far
	local life = windup + 0.6
	charges += 1
	local core = chargePart(col:Lerp(BOLT_HOT, 0.55), 0.15, life)
	local shell: Part? = if hq >= 0.45 then chargePart(col, 0.85, life) else nil
	local lit = false
	if hq >= 0.75 and litCharges < MAX_LIT_CHARGES then
		litCharges += 1
		lit = true
		local l = core:FindFirstChildOfClass("PointLight")
		if not l then
			local nl = Instance.new("PointLight")
			nl.Shadows = false
			nl.Parent = core
			l = nl
		end
		local pl = l :: PointLight
		pl.Color = col
		pl.Range = if heavy then 16 else 9
		pl.Brightness = 0
		pl.Enabled = true
	end
	local t0 = os.clock()
	local finished = false
	local function done()
		if finished then
			return
		end
		finished = true
		charges -= 1
		if lit then
			litCharges -= 1
		end
		releaseCharge(core)
		if shell then
			releaseCharge(shell)
		end
	end
	addActor(function()
		local u = (os.clock() - t0) / windup
		if u >= 1.08 or not core.Parent or not m.Parent then
			done()
			return true
		end
		local pos = if m.Parent then muzzleFrame(m) * off else start
		local e = math.clamp(u, 0, 1)
		e = e * e
		-- last tenth: a quick flicker so the release moment reads
		local flick = if u > 0.9 then 1 + 0.18 * math.sin(os.clock() * 70) else 1
		local cf = CFrame.new(pos)
		core.Size = Vector3.one * (0.15 + (coreMax - 0.15) * e) * flick
		core.CFrame = cf
		if shell then
			shell.Size = Vector3.one * (0.3 + (shellMax - 0.3) * e) * flick
			shell.Transparency = 0.85 - 0.4 * e
			shell.CFrame = cf
		end
		if lit then
			local l = core:FindFirstChildOfClass("PointLight")
			if l then
				l.Brightness = (if heavy then 5 else 2.5) * e
			end
		end
		return false
	end, done)
end

local function onEnemyAttack(d: any)
	local kind = d.kind
	local e = d.e
	local p = d.p
	if kind == "sweepBeam" then
		onSweepBeam(d)
		return
	end
	if CHARGE_KINDS[kind] then
		local ok, err = pcall(chargeUp, d)
		if not ok then
			stepWarn("charge", err)
		end
	end
	if not Audio then
		return
	end
	if kind == "step" then
		local behemoth = e == "COLOSSUS" or e == "TITAN" or e == "SPIRE"
		local heavyStep = behemoth or e == "BULWARK" or e == "CHARGER" or e == "LANCER" or e == "BASTION"
		if behemoth then
			Audio.play("RobotStep", p, { volume = 1.35, pitch = 0.52, priority = 3 })
			Audio.play("Land", p, { volume = 1.15, pitch = 0.52, priority = 3 })
			if Juice then
				if Juice.thump then
					Juice.thump(0.78, 0.34, p, 115)
				else
					Juice.shake(0.65, 0.3, p, 115)
				end
			end
		elseif heavyStep then
			Audio.play("RobotStep", p, { volume = 1.05, pitch = 0.68, priority = 2 })
			Audio.play("Land", p, { volume = 0.78, pitch = 0.64, priority = 2 })
			if Juice then
				if Juice.thump then
					Juice.thump(0.38, 0.22, p, 62)
				else
					Juice.shake(0.32, 0.2, p, 62)
				end
			end
		else
			Audio.play("RobotStep", p)
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
	-- side faces only (2026-11-15: a crack on the back was never seen; the front is often a shield)
	local n = if r:NextNumber() < 0.5 then Vector3.xAxis else -Vector3.xAxis
	local w = if n.X ~= 0 then S.Z else S.X
	local L = math.clamp(math.min(w, S.Y) * 0.8, 1.2, 9)
	local u = r:NextNumber(-0.2, 0.2) * w
	local v = r:NextNumber(-0.25, 0.1) * S.Y
	local depth = if n.X ~= 0 then S.X / 2 else S.Z / 2
	local pos = n * depth + Vector3.new(if n.X ~= 0 then 0 else u, v, if n.X ~= 0 then u else 0)
	local faceCF = CFrame.lookAt(pos, pos + n) -- local -Z = outward normal; the crack lies in local XY
	local base = body.CFrame * faceCF
	local thick = math.clamp(L * 0.1, 0.25, 0.7) * math.clamp(I, 0.6, 1.4)
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
		-- 2026-11-15 playtest: "no effects at all" -> thicker, darker, bigger plume (lit less by the sun so it reads dark)
		emitter(addAtt(s, body, topAt()), {
			Texture = SMOKE_TEX,
			Color = ColorSequence.new(col[1], col[2]),
			LightInfluence = 0.4,
			Size = NumberSequence.new({ kp(0, (1.2 + stage * 0.3) * k), kp(1, (4 + stage * 1.5) * k) }),
			Transparency = NumberSequence.new({ kp(0, 0.15), kp(0.6, 0.45), kp(1, 1) }),
			Lifetime = NumberRange.new(1.8, 2.6 + stage * 0.4),
			Rate = (6 + stage * 6) * I * q,
			Speed = NumberRange.new(4, 7),
			SpreadAngle = Vector2.new(12, 12),
			Acceleration = Vector3.new(0.8, 2, 0),
			EmissionDirection = Enum.NormalId.Top,
		})
		-- stage 1 already shows a small crack; 2 a big one; 3 one on each side
		if stage == 1 then
			crack(s, body, BREACH_ORANGE, I * 0.7, r)
		end
		if stage >= 2 then
			local faceCF = crack(s, body, BREACH_ORANGE, I, r)
			if stage >= 3 then
				crack(s, body, BREACH_ORANGE, I, r)
			end
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
					Size = NumberSequence.new({ kp(0, 2.2 * k), kp(1, 0.3 * k) }),
					Transparency = NumberSequence.new({ kp(0, 0.05), kp(1, 1) }),
					Lifetime = NumberRange.new(0.6, 1.0),
					Rate = 24 * I * q,
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
	if d.cookoff == true then
		return -- heavy COG cook-off flings burning plates on CookOffBoom after 1.0 s
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

-- LOOT RUNNER (server/Enemies/LootRunner.luau) ------------------------------------------
-- Marker while a runner lives: a gold billboard over it (name, distance, seconds left) and a gold pip on the compass tape
-- (Compass.setExtra). Fx "LootBurst" {p, f}: glitter + a short ka-ching (Pickup, pitched up). Fx "LootEscape" {p, f}: a puff.
local LOOT_GOLD = C3(255, 211, 74)
type LootMark = { gui: BillboardGui, info: TextLabel, key: string, metres: number, secs: number }
local lootMarks: { [Model]: LootMark } = {}
local LootStyle: any = nil
local LootCompass: any = nil

local function lootRemove(m: Instance)
	local mk = lootMarks[m :: Model]
	if not mk then
		return
	end
	lootMarks[m :: Model] = nil
	if LootCompass then
		LootCompass.setExtra(mk.key, nil)
	end
	mk.gui:Destroy()
end

local function lootAdd(m: Instance)
	if not m:IsA("Model") or lootMarks[m] or not LootStyle then
		return
	end
	local kind = m:GetAttribute("Kind")
	local def = type(kind) == "string" and EnemyData.get(kind) or nil
	if not def or not def.loot then
		return
	end
	local lp = game:GetService("Players").LocalPlayer
	local gui = Instance.new("BillboardGui")
	gui.Name = "LootMark"
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Size = UDim2.fromOffset(150, 36)
	gui.StudsOffset = Vector3.new(0, 5.5, 0)
	gui.Adornee = m.PrimaryPart
	gui.Parent = lp:WaitForChild("PlayerGui")
	LootStyle.label({
		Name = "Title",
		Text = "LOOT RUNNER",
		TextSize = 15,
		Color = LOOT_GOLD,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 16),
		Parent = gui,
	})
	local info = LootStyle.label({
		Name = "Info",
		Text = "",
		TextSize = 13,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 16),
		Size = UDim2.new(1, 0, 0, 14),
		Parent = gui,
	})
	local id = m:GetAttribute("EnemyId")
	lootMarks[m] = { gui = gui, info = info, key = "loot" .. tostring(id), metres = -1, secs = -1 }
end

local function lootStep()
	if next(lootMarks) == nil then
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	for m, mk in lootMarks do
		local root = m.PrimaryPart
		if not m.Parent then
			lootRemove(m)
			continue
		end
		if not root then
			continue
		end
		if mk.gui.Adornee ~= root then
			mk.gui.Adornee = root
		end
		if LootCompass then
			LootCompass.setExtra(mk.key, root.Position + Vector3.new(0, 3, 0), LOOT_GOLD)
		end
		local metres = math.floor((root.Position - cam.CFrame.Position).Magnitude + 0.5)
		local ends = m:GetAttribute("LootEnds")
		local secs = if type(ends) == "number" then math.max(math.ceil(ends - workspace:GetServerTimeNow()), 0) else -1
		if metres ~= mk.metres or secs ~= mk.secs then
			mk.metres = metres
			mk.secs = secs
			mk.info.Text = if secs >= 0 then string.format("%d m  -  %d s", metres, secs) else string.format("%d m", metres)
		end
	end
end

local function onLootBurst(d: any)
	if typeof(d.p) ~= "Vector3" or not Fx then
		return
	end
	local p: Vector3 = d.p
	if Fx.burst then
		Fx.burst("sparks", p, 40, { color = LOOT_GOLD, scale = 1.4, speed = 1.1 })
	end
	if Fx.debris then
		Fx.debris(p, { n = 22, style = "ember", speed = 42, up = 1.6, scale = 1.6, life = 1.6 })
	end
	if Audio and Audio.play then
		Audio.play("Pickup", p, { pitch = 1.5 })
		task.delay(0.12, function()
			Audio.play("Pickup", p, { pitch = 2.0, volume = 0.8 })
		end)
	end
end

local function onLootEscape(d: any)
	if typeof(d.p) ~= "Vector3" or not Fx or not Fx.burst then
		return
	end
	Fx.burst("puff", d.p, 18, { scale = 1.6 })
	Fx.burst("dust", d.p, 14, { scale = 1.4 })
end

local function startLoot()
	local okS, style = pcall(function()
		return require(script.Parent.Parent.UI.HudStyle)
	end)
	if okS then
		LootStyle = style
	end
	local okC, compass = pcall(function()
		return require(script.Parent.Parent.UI.Compass)
	end)
	if okC then
		LootCompass = compass
	end
	if not LootStyle then
		return
	end
	RunService.RenderStepped:Connect(lootStep)
	task.spawn(function()
		local folder = workspace:WaitForChild("Enemies", 120)
		if not folder then
			return
		end
		for _, m in folder:GetChildren() do
			lootAdd(m)
		end
		folder.ChildAdded:Connect(function(m)
			task.defer(lootAdd, m)
		end)
		folder.ChildRemoved:Connect(lootRemove)
	end)
end

-- ELITES (server/Enemies/Elites.luau) ----------------------------------------------------
-- Enemy models with the attribute Elite = "Plated" | "Volatile" | "Swift" get a coloured outline (Highlight, no fill) and a small
-- icon + name over the head. Both are local children of the model, so they go away with it (nothing to pool or clean up).
local ELITE_LOOK = {
	Plated = { color = C3(110, 165, 235), letter = "P" }, -- steel blue
	Volatile = { color = C3(255, 140, 40), letter = "V" }, -- orange
	Swift = { color = C3(90, 230, 110), letter = "S" }, -- green
}

local function eliteMark(m: Instance)
	if not m:IsA("Model") or m:FindFirstChild("EliteOutline") then
		return
	end
	local look = ELITE_LOOK[m:GetAttribute("Elite")]
	local root = m.PrimaryPart
	if not look or not root then
		return
	end
	local hl = Instance.new("Highlight")
	hl.Name = "EliteOutline"
	hl.Adornee = m
	hl.FillTransparency = 1
	hl.OutlineColor = look.color
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.Parent = m

	local boxCF, boxSize = m:GetBoundingBox()
	local up = math.max(boxCF.Position.Y + boxSize.Y / 2 - root.Position.Y, 2) + 1.4
	local gui = Instance.new("BillboardGui")
	gui.Name = "EliteIcon"
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = 130
	gui.Size = UDim2.fromOffset(80, 44)
	gui.StudsOffset = Vector3.new(0, up, 0)
	gui.Adornee = root
	local icon = Instance.new("Frame")
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.Position = UDim2.fromScale(0.5, 0)
	icon.Size = UDim2.fromOffset(26, 26)
	icon.BackgroundColor3 = C3(14, 16, 20)
	icon.BackgroundTransparency = 0.25
	icon.BorderSizePixel = 0
	icon.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = icon
	local stroke = Instance.new("UIStroke")
	stroke.Color = look.color
	stroke.Thickness = 2
	stroke.Parent = icon
	local letter = Instance.new("TextLabel")
	letter.BackgroundTransparency = 1
	letter.Size = UDim2.fromScale(1, 1)
	letter.Font = Enum.Font.GothamBlack
	letter.Text = look.letter
	letter.TextColor3 = look.color
	letter.TextSize = 17
	letter.Parent = icon
	local word = Instance.new("TextLabel")
	word.BackgroundTransparency = 1
	word.AnchorPoint = Vector2.new(0.5, 0)
	word.Position = UDim2.new(0.5, 0, 0, 28)
	word.Size = UDim2.new(1, 0, 0, 14)
	word.Font = Enum.Font.GothamBold
	word.Text = string.upper(tostring(m:GetAttribute("Elite")))
	word.TextColor3 = look.color
	word.TextSize = 11
	word.TextStrokeTransparency = 0.4
	word.Parent = gui
	gui.Parent = root
end

local function startElites()
	task.spawn(function()
		local folder = workspace:WaitForChild("Enemies", 120)
		if not folder then
			return
		end
		local function watch(m: Instance)
			if not m:IsA("Model") then
				return
			end
			if m:GetAttribute("Elite") then
				eliteMark(m)
			else
				local conn
				conn = m:GetAttributeChangedSignal("Elite"):Connect(function()
					if m:GetAttribute("Elite") then
						conn:Disconnect()
						eliteMark(m)
					end
				end)
			end
		end
		for _, m in folder:GetChildren() do
			watch(m)
		end
		folder.ChildAdded:Connect(function(m)
			task.defer(watch, m)
		end)
	end)
end

-- Heavy COG 1.0 s flaming cook-off + secondary sky-flashing 4-beat detonation -------------------------------------------
local function onCookOff(d: any)
	if type(d) ~= "table" or typeof(d.p) ~= "Vector3" or not Fx then
		return
	end
	local p: Vector3 = d.p
	local dur = math.clamp(tonumber(d.dur) or 1.0, 0.4, 2.0)
	local isBehemoth = d.class == "behemoth"
	local sz = math.clamp(tonumber(d.size) or (if isBehemoth then 12 else 5), 3, 14)
	local k = math.clamp(sz / 5, 0.8, 2.6)
	local q = quality()
	local dist = if Fx.camDistance then Fx.camDistance(p) else 0
	if dist > 450 then
		return
	end

	-- Rising danger whine + crackling cook-off audio
	if Audio and Audio.play then
		pcall(Audio.play, "LanceCharge", p, { volume = 1.05, pitch = 1.15, priority = 5 })
		pcall(Audio.play, "DeathScrap", p, { volume = 0.85, pitch = 0.72, priority = 4 })
	end
	if Juice and Juice.shake then
		pcall(Juice.shake, 0.7 * k, dur, p, 90)
	end

	-- Violent flame + black charcoal smoke + flickering orange PointLight anchored at the dying hulk
	local host = mk(Vector3.one * 0.6, C3(255, 140, 30), CFrame.new(p), Enum.PartType.Block, Enum.Material.SmoothPlastic, 1, dur + 2.8)
	local flames = emitter(host, {
		Texture = FIRE_TEX,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, C3(255, 251, 224)),
			ColorSequenceKeypoint.new(0.35, C3(255, 130, 28)),
			ColorSequenceKeypoint.new(1, C3(210, 42, 12)),
		}),
		LightEmission = 1,
		LightInfluence = 0,
		EmissionDirection = Enum.NormalId.Top,
		SpreadAngle = Vector2.new(65, 65),
		Size = NumberSequence.new({ kp(0, 2.2 * k), kp(0.45, 4.6 * k), kp(1, 0.8 * k) }),
		Transparency = NumberSequence.new({ kp(0, 0.05), kp(0.7, 0.35), kp(1, 1) }),
		Lifetime = NumberRange.new(0.25, 0.5),
		Speed = NumberRange.new(14 * k, 28 * k),
		Rate = math.max(18, math.floor(42 * q)),
	})
	local soot = emitter(host, {
		Texture = SMOKE_TEX,
		Color = ColorSequence.new(C3(31, 27, 24), C3(74, 67, 60)),
		LightEmission = 0,
		LightInfluence = 0.4,
		EmissionDirection = Enum.NormalId.Top,
		SpreadAngle = Vector2.new(35, 35),
		Size = NumberSequence.new({ kp(0, 2.4 * k), kp(1, 7.5 * k) }),
		Transparency = NumberSequence.new({ kp(0, 0.15), kp(0.65, 0.45), kp(1, 1) }),
		Lifetime = NumberRange.new(1.1, 1.9),
		Speed = NumberRange.new(10 * k, 20 * k),
		Acceleration = Vector3.new(1.5, 6, 0.8),
		Rate = math.max(10, math.floor(24 * q)),
	})
	local sparks = emitter(host, {
		Texture = SPARK_TEX,
		Color = ColorSequence.new(C3(255, 248, 210), C3(255, 130, 30)),
		LightEmission = 1,
		LightInfluence = 0,
		SpreadAngle = Vector2.new(180, 180),
		Size = NumberSequence.new({ kp(0, 0.65 * k), kp(1, 0) }),
		Transparency = NumberSequence.new({ kp(0, 0), kp(1, 1) }),
		Lifetime = NumberRange.new(0.25, 0.55),
		Speed = NumberRange.new(22, 52),
		Acceleration = Vector3.new(0, -65, 0),
		Rate = math.max(16, math.floor(36 * q)),
	})
	local glow = Instance.new("PointLight")
	glow.Color = C3(255, 140, 26)
	glow.Range = math.clamp(30 * k, 30, 60)
	glow.Brightness = 4.5
	glow.Shadows = false
	glow.Parent = host

	-- Violent hull shudder + rising danger pops at t = 0.25, 0.55, 0.82 s
	local model: Model? = if typeof(d.model) == "Instance" and d.model:IsA("Model") then d.model else nil
	local basePivot = if model and model.Parent then model:GetPivot() else nil
	local t0 = os.clock()
	local popTimes = { dur * 0.24, dur * 0.54, dur * 0.82 }
	local nextPop = 1
	addActor(function()
		local elapsed = os.clock() - t0
		if elapsed >= dur or not host.Parent then
			flames.Enabled = false
			soot.Enabled = false
			sparks.Enabled = false
			glow.Enabled = false
			return true
		end
		local u = elapsed / dur
		-- escalating flicker + sputter
		glow.Brightness = (3.5 + 5.0 * u) * (0.65 + 0.55 * math.random())
		if model and model.Parent and basePivot then
			local j = (0.18 + 0.42 * u) * k
			local off = Vector3.new((math.random() - 0.5) * j, (math.random() - 0.5) * j * 0.5, (math.random() - 0.5) * j)
			local tilt = CFrame.Angles((math.random() - 0.5) * 0.08 * u, 0, (math.random() - 0.5) * 0.08 * u)
			model:PivotTo(basePivot * CFrame.new(off) * tilt)
		end
		if nextPop <= #popTimes and elapsed >= popTimes[nextPop] then
			nextPop += 1
			local popOff = Vector3.new((math.random() - 0.5) * 3 * k, math.random() * 2.5 * k, (math.random() - 0.5) * 3 * k)
			flash(p + popOff, C3(255, 238, 175), 5.5 * k, 0.14)
			if Fx.burst then
				Fx.burst("sparks", p + popOff, 14, { scale = 1.0 * k, speed = 1.3 })
				Fx.burst("fire", p + popOff, 6, { scale = 0.9 * k, speed = 1.1 })
			end
			if Audio and Audio.play then
				pcall(Audio.play, "ExplosionSmall", p, { volume = 0.85, pitch = 1.05 + 0.2 * u, priority = 4 })
			end
		end
		return false
	end)
end

local function onCookOffBoom(d: any)
	if type(d) ~= "table" or typeof(d.p) ~= "Vector3" or not Fx then
		return
	end
	local p: Vector3 = d.p
	local isBehemoth = d.class == "behemoth"
	local sz = math.clamp(tonumber(d.size) or (if isBehemoth then 12 else 5), 4, 14)

	-- Secondary sky-flashing 4-beat detonation + audio ducking + chunky dark burning shrapnel
	if Fx.explosion then
		Fx.explosion(p, {
			size = if isBehemoth then "XL" else "L",
			r = if isBehemoth then 24 else 15,
			k = if isBehemoth then 3.2 else 2.2,
			style = "fire",
			cookoff = true,
		})
	end
	if Audio and Audio.play then
		pcall(Audio.play, "DeathBig", p, { volume = 1.2, priority = 5 })
	end
	if Juice then
		if Juice.flashAt then
			pcall(Juice.flashAt, C3(255, 251, 224), if isBehemoth then 0.8 else 0.62, 0.36, p, 850)
		end
		if Juice.kill then
			local mine = d.by == PlayersService.LocalPlayer.UserId
			pcall(Juice.kill, if isBehemoth then 3 else 2, mine, p)
		end
	end
	if Fx.debris then
		Fx.debris(p + Vector3.new(0, 1.5, 0), {
			n = if isBehemoth then 12 else 10,
			style = "shrapnel",
			speed = 46 + sz * 1.8,
			up = 1.9,
			scale = if isBehemoth then 1.65 else 1.25,
			life = 1.4,
			dir = if typeof(d.dir) == "Vector3" then d.dir else nil,
			bias = 0.6,
		})
	end
	-- Also fling burning COG armor plates
	onHeavyDeath({ p = p, kind = d.kind, dir = d.dir, fodder = false, cookoff = false })
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
	Fx.register("CookOff", onCookOff)
	Fx.register("CookOffBoom", onCookOffBoom)
	Fx.register("LootBurst", onLootBurst)
	Fx.register("LootEscape", onLootEscape)
	startStaged()
	startDrones() -- foundry drones: rotor blur / wing flutter
	startLoot()
	startElites()
end

return EnemyFx
