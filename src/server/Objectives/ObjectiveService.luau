-- S.Objectives: runs the main objective (MissileLaunch / UplinkRelay) plus side objectives for one mission.
--   S.Objectives.start(map, {main = "MISSILE"|"UPLINK", sides = {"NEST","SAMPLES"}, faction = "COG"|"BROOD"})
--   S.Objectives.stop()
--   S.Objectives.onMainComplete = function() end      (set by the Mission)
--   S.Objectives.onExplosion(pos, radius)             (call from every explosion: destroys nests within 8 studs)
--   S.Objectives.getState() -> list (same shape as the "objectives" state)
--   S.Objectives.getSamples() / getSidesDone() / getMainSteps()
-- Sub-modules (MissileLaunch, UplinkRelay, SideObjectives) get a shared `ctx` built here.
-- Everything spawned lives in workspace.ObjectiveObjects (cleared on stop).

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local MissileLaunch = require(script.Parent.MissileLaunch)
local UplinkRelay = require(script.Parent.UplinkRelay)
local SideObjectives = require(script.Parent.SideObjectives)

local ObjectiveService = {}
ObjectiveService.onMainComplete = nil :: (() -> ())?

local S: any = nil

local entries: { any } = {}
local controllers: { any } = {}
local cleanups: { () -> () } = {}
local folder: Folder? = nil
local runId = 0
local running = false
local dirty = false
local mainEntry: any = nil
local mainFired = false
local samplesCtl: any = nil
local beacon: Part? = nil
local finalStats: { samples: number, sides: number, steps: number }? = nil -- kept after stop() so rewards can still read it

-- ---------------------------------------------------------------- state
local function snapshot(): { any }
	local out = {}
	for _, e in entries do
		local steps = {}
		for _, st in e.steps do
			steps[#steps + 1] = { text = st.text, done = st.done, active = st.active, progress = st.progress }
		end
		out[#out + 1] = { id = e.id, title = e.title, main = e.main, done = e.done, steps = steps, marker = e.marker }
	end
	return out
end

local function flush()
	dirty = false
	if S and S.State then
		S.State.broadcast("objectives", snapshot())
	end
end

-- ---------------------------------------------------------------- generic helpers (exposed through ctx)
local function getRoot(player: Player): BasePart?
	if S and S.Players and S.Players.getRoot then
		local ok, r = pcall(S.Players.getRoot, player)
		if ok then
			return r
		end
		return nil
	end
	local ch = player.Character
	return ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function isAlive(player: Player): boolean
	if S and S.Players and S.Players.isAlive then
		return S.Players.isAlive(player) and true or false
	end
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

local function alivePlayers(): { Player }
	if S and S.Players and S.Players.getAlive then
		return S.Players.getAlive()
	end
	local out = {}
	for _, p in Players:GetPlayers() do
		if isAlive(p) then
			out[#out + 1] = p
		end
	end
	return out
end

local function playersNear(pos: Vector3, radius: number): { Player }
	local out = {}
	for _, p in alivePlayers() do
		local r = getRoot(p)
		if r and (r.Position - pos).Magnitude <= radius then
			out[#out + 1] = p
		end
	end
	return out
end

local function makePart(parent: Instance, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = mat or Enum.Material.Metal
	p.CastShadow = size.Magnitude > 14
	if opts then
		for k, v in opts do
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

local function buildCtx(map: any, faction: string): any
	local myRun = runId
	local ctx: any = {}
	ctx.S = S
	ctx.map = map
	ctx.faction = faction
	ctx.folder = folder
	ctx.rng = Random.new()

	function ctx.alive(): boolean
		return running and runId == myRun
	end

	function ctx.changed(urgent: boolean?)
		dirty = true
		if urgent then
			flush()
		end
	end

	function ctx.newEntry(def: any): any
		local steps = {}
		for i, text in def.steps do
			steps[i] = { text = text, done = false, active = i == 1, progress = nil }
		end
		local e = { id = def.id, title = def.title, main = def.main == true, done = false, steps = steps, marker = nil }
		entries[#entries + 1] = e
		dirty = true
		return e
	end

	function ctx.setBeacon(pos: Vector3?)
		if not beacon then
			return
		end
		if pos then
			beacon.Position = pos + Vector3.new(0, 30, 0)
			beacon.Transparency = 0.6
		else
			beacon.Transparency = 1
		end
	end

	function ctx.setMarker(entry: any, pos: Vector3?)
		entry.marker = pos and (pos + Vector3.new(0, 5, 0)) or nil
		if entry.main then
			ctx.setBeacon(pos)
		end
		ctx.changed()
	end

	function ctx.notify(text: string, color: Color3?)
		if S and S.State then
			S.State.notify(nil, text, color or Config.Colors.Friendly)
		end
	end

	function ctx.sound(key: string, pos: Vector3?)
		if S and S.Fx then
			S.Fx.play("Sound", { k = key, p = pos })
		end
	end

	function ctx.fx(kind: string, data: any)
		if S and S.Fx then
			S.Fx.play(kind, data)
		end
	end

	function ctx.completeStep(entry: any, idx: number, announce: string?)
		local st = entry.steps[idx]
		if not st or st.done then
			return
		end
		st.done = true
		st.active = false
		st.progress = nil
		local nxt = entry.steps[idx + 1]
		if nxt then
			nxt.active = true
		else
			entry.done = true
		end
		ctx.notify(announce or ("Objective: " .. st.text .. " - complete"), Config.Colors.Friendly)
		ctx.sound("ObjectiveDone", nil)
		ctx.changed(true)
		-- pacing: finishing main steps heats the field up; the last-but-one step (the launch / upload) forces a breach
		if entry.main and nxt then
			ctx.intensity(if idx >= #entry.steps - 1 then "FINAL_STEPS" else "MAIN_STEP")
		elseif not entry.main and entry.done then
			ctx.intensity("SIDE_DONE")
		end
	end

	-- Director.objectiveEvent(name): see shared/Data/Intensity.luau Events (DEFEND_START, MAIN_STEP, FINAL_STEPS, SAMPLE, SIDE_DONE, LOUD)
	function ctx.intensity(name: string)
		local d = S and S.Director
		if d and d.objectiveEvent then
			local ok, err = pcall(d.objectiveEvent, name)
			if not ok then
				warn("[Objectives] objectiveEvent failed:", err)
			end
		end
	end

	ctx.players = alivePlayers
	ctx.playersNear = playersNear
	ctx.getRoot = getRoot
	ctx.isAlive = isAlive
	ctx.part = makePart

	function ctx.glow(parent: Instance, size: Vector3, cf: CFrame, color: Color3, opts: { [string]: any }?): Part
		local o: { [string]: any } = { CanCollide = false, CanQuery = false, CanTouch = false }
		if opts then
			for k, v in opts do
				o[k] = v
			end
		end
		return makePart(parent, size, cf, color, Enum.Material.Neon, o)
	end

	-- vertical cylinder (Roblox cylinders run along X)
	function ctx.cyl(parent: Instance, diameter: number, height: number, cf: CFrame, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
		local p = makePart(parent, Vector3.new(height, diameter, diameter), cf * CFrame.Angles(0, 0, math.pi / 2), color, mat, opts)
		p.Shape = Enum.PartType.Cylinder
		return p
	end

	function ctx.ball(parent: Instance, diameter: number, cf: CFrame, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
		local p = makePart(parent, Vector3.new(diameter, diameter, diameter), cf, color, mat, opts)
		p.Shape = Enum.PartType.Ball
		return p
	end

	function ctx.light(parent: Instance, color: Color3, range: number, brightness: number): PointLight
		local l = Instance.new("PointLight")
		l.Color = color
		l.Range = range
		l.Brightness = brightness
		l.Shadows = false
		l.Parent = parent
		return l
	end

	function ctx.tween(inst: Instance, seconds: number, goal: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
		local tw = TweenService:Create(inst, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.InOut), goal)
		tw:Play()
		return tw
	end

	function ctx.onCleanup(fn: () -> ())
		cleanups[#cleanups + 1] = fn
	end

	function ctx.wave(center: Vector3, budget: number)
		local d = S and S.Director
		if d and d.spawnWave then
			local n = math.max(1, #alivePlayers())
			local scaled = math.floor(budget * (0.75 + 0.25 * n) + 0.5)
			local ok, err = pcall(d.spawnWave, center, scaled)
			if not ok then
				warn("[Objectives] spawnWave failed:", err)
			end
		end
	end

	-- ProximityPrompt with server-side validation (alive + in range)
	function ctx.prompt(parent: BasePart, opts: any): ProximityPrompt
		local pp = Instance.new("ProximityPrompt")
		local dist = opts.distance or Config.InteractRange
		pp.ActionText = opts.action or "Interact"
		pp.ObjectText = opts.object or ""
		pp.HoldDuration = opts.hold or 0
		pp.MaxActivationDistance = dist
		pp.RequiresLineOfSight = false
		pp.KeyboardKeyCode = Enum.KeyCode.E
		pp.Enabled = opts.enabled ~= false
		if opts.style then
			pp.Style = opts.style
		end
		local function handle(player: Player, force: boolean?)
			if not ctx.alive() or not pp.Enabled then
				return
			end
			if not isAlive(player) then
				return
			end
			local root = getRoot(player)
			if not force and (not root or (root.Position - parent.Position).Magnitude > dist + 8) then
				return
			end
			opts.onTrigger(player)
		end
		pp.Triggered:Connect(handle)
		-- test hook: Main's DebugHook "trigger" fires this to skip walking + holding
		local dbg = Instance.new("BindableEvent")
		dbg.Name = "DebugTrigger"
		dbg.Event:Connect(function(player)
			handle(player, true)
		end)
		dbg.Parent = pp
		pp.Parent = parent
		return pp
	end

	-- Timed defend phase. opts = {center, radius, duration, wavePeriod, waveBudget, onTick(p01, paused), onDone()}
	-- Progress only advances while a living player is within `radius` of `center`.
	function ctx.defend(opts: any): { cancel: () -> () }
		local cancelled = false
		ctx.intensity("DEFEND_START") -- generator spin-up / upload: a breach comes for it
		task.spawn(function()
			local t = 0
			local waveT = opts.wavePeriod * 0.55
			while not cancelled and ctx.alive() do
				local dt = 0.2
				task.wait(dt)
				if cancelled or not ctx.alive() then
					return
				end
				local near = #playersNear(opts.center, opts.radius) > 0
				if near then
					t += dt
					waveT += dt
				end
				local p = math.clamp(t / opts.duration, 0, 1)
				if opts.onTick then
					opts.onTick(p, not near)
				end
				if waveT >= opts.wavePeriod then
					waveT = 0
					ctx.wave(opts.center, opts.waveBudget * (0.8 + 0.6 * p))
				end
				if t >= opts.duration then
					opts.onDone()
					return
				end
			end
		end)
		return {
			cancel = function()
				cancelled = true
			end,
		}
	end

	return ctx
end

-- ---------------------------------------------------------------- API
local function fireMain()
	if mainFired then
		return
	end
	mainFired = true
	local cb = ObjectiveService.onMainComplete
	if cb then
		local ok, err = pcall(cb)
		if not ok then
			warn("[Objectives] onMainComplete error:", err)
		end
	end
end

function ObjectiveService.debugSolve(player: Player): boolean
	for _, c in controllers do
		if c.debugSolve and c.debugSolve(player) then
			return true
		end
	end
	return false
end

function ObjectiveService.init(registry: any)
	S = registry
	if S.Actions and S.Actions.on then
		S.Actions.on("minigame", function(player: Player, objectiveId: any, payload: any)
			if typeof(objectiveId) ~= "string" then
				return
			end
			for _, c in controllers do
				if c.onMinigame then
					c.onMinigame(player, objectiveId, payload)
				end
			end
		end)
	end
end

local function liveStats()
	local sides, steps = 0, 0
	for _, e in entries do
		if not e.main and e.done then
			sides += 1
		end
	end
	if mainEntry then
		for _, st in mainEntry.steps do
			if st.done then
				steps += 1
			end
		end
	end
	local samples = 0
	if samplesCtl and samplesCtl.getCount then
		samples = samplesCtl.getCount()
	end
	return { samples = samples, sides = sides, steps = steps }
end

function ObjectiveService.stop()
	if running then
		finalStats = liveStats()
	end
	runId += 1
	running = false
	for _, c in controllers do
		if c.stop then
			pcall(c.stop)
		end
	end
	for _, fn in cleanups do
		pcall(fn)
	end
	table.clear(controllers)
	table.clear(cleanups)
	table.clear(entries)
	samplesCtl = nil
	mainEntry = nil
	beacon = nil
	if folder then
		folder:Destroy()
		folder = nil
	end
	local old = Workspace:FindFirstChild("ObjectiveObjects")
	if old then
		old:Destroy()
	end
	if S and S.State then
		S.State.broadcast("objectives", {})
	end
end

function ObjectiveService.start(map: any, cfg: any)
	ObjectiveService.stop()
	finalStats = nil
	running = true
	mainFired = false
	cfg = cfg or {}
	local faction = cfg.faction or map.faction or "COG"

	local f = Instance.new("Folder")
	f.Name = "ObjectiveObjects"
	f.Parent = Workspace
	folder = f

	local bp = Instance.new("Part")
	bp.Name = "ObjectiveBeacon"
	bp.Anchored = true
	bp.CanCollide = false
	bp.CanQuery = false
	bp.CanTouch = false
	bp.CastShadow = false
	bp.Material = Enum.Material.Neon
	bp.Color = Color3.fromRGB(255, 214, 160) -- warm: the teal column added to the green tint around objectives
	bp.Size = Vector3.new(0.8, 70, 0.8)
	bp.Transparency = 1
	bp.Parent = f
	beacon = bp

	local ctx = buildCtx(map, faction)

	local mainKind = cfg.main or "MISSILE"
	local ctl
	if mainKind == "UPLINK" then
		ctl = UplinkRelay.start(ctx, function()
			fireMain()
		end)
	else
		ctl = MissileLaunch.start(ctx, function()
			fireMain()
		end)
	end
	mainEntry = ctl.entry
	controllers[#controllers + 1] = ctl

	-- sides
	local counts: { [string]: number } = {}
	local nestSites = { "nest1", "nest2", "nest3", "nest4" }
	for i = #nestSites, 2, -1 do
		local j = ctx.rng:NextInteger(1, i)
		nestSites[i], nestSites[j] = nestSites[j], nestSites[i]
	end
	local nestIdx = 0
	for _, kind in cfg.sides or {} do
		counts[kind] = (counts[kind] or 0) + 1
		local c
		if kind == "NEST" then
			nestIdx += 1
			local site = nestSites[nestIdx]
			if site and map.sites[site] then
				c = SideObjectives.startNest(ctx, site, counts[kind])
			end
		elseif kind == "SAMPLES" then
			c = SideObjectives.startSamples(ctx, counts[kind])
			samplesCtl = c
		end
		if c then
			c.isSide = true
			controllers[#controllers + 1] = c
		end
	end

	flush()
	local myRun = runId
	task.spawn(function()
		while running and runId == myRun do
			task.wait(0.25)
			if dirty then
				flush()
			end
		end
	end)
end

function ObjectiveService.onExplosion(pos: Vector3, radius: number)
	if not running then
		return
	end
	SideObjectives.onExplosion(pos, radius)
end

function ObjectiveService.getState(): { any }
	return snapshot()
end

function ObjectiveService.getSamples(): number
	return (if running or not finalStats then liveStats() else finalStats).samples
end

function ObjectiveService.getSidesDone(): number
	return (if running or not finalStats then liveStats() else finalStats).sides
end

function ObjectiveService.getMainSteps(): number
	return (if running or not finalStats then liveStats() else finalStats).steps
end

return ObjectiveService
