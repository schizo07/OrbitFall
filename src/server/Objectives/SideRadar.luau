-- Side objective RADAR: a radar dish on a mast (COG planets: a captured COG relay; BROOD planets: an abandoned colony radar)
-- on a spare nest site. Hold the generator prompt (4 s) to restart it, then tune the dish (client/UI/RadarTune.luau).
--   SideRadar.start(ctx, index) -> controller { entry, stop, onMinigame, debugSolve } | nil (no spare site)
-- While the radar stands:
--   * every side objective marker is shown. Before the radar is up, the other sides' markers stay hidden until a living
--     player comes within REVEAL_DIST of them (once seen, a marker stays shown);
--   * every ping period (Studio A/B Feel_RadarPing: nil = 20 s, number = seconds, "off") it broadcasts
--     Fx "RadarPing" { blips = { {p = Vector3, n = enemies, src = bool?} }, t = seconds shown, o = dish position };
--   * workspace attribute RadarOnline = true (client/UI/Compass "RADAR ONLINE" tag).
-- Enemies standing at the radar wear it down (WRECK_RADIUS, HP_MAX); a wrecked radar takes a repair hold to come back.
-- Tune modes (Studio A/B Feel_RadarTune): nil = sweep, 3 hits; "sweep2" = 2 hits; "hold" = a 4 s hold, no mini-game.
-- Tune protocol (server authoritative): Fx "RadarTune" to the tuner
--   { state = "open", obj, t0, period, c, h, need, timeout }   needle = triangle sweep 0..1..0 over `period` s from t0
--                                                              (workspace:GetServerTimeNow time); green band c +- h
--   { state = "hit", n } | { state = "reject" } | { state = "done" } | { state = "close", why }
-- The client reports each tap with Action "minigame"(obj, { hit = serverTime }) or (obj, { cancel = true }); the server
-- checks the tap time against its own sweep.

local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local SetPieces = require(script.Parent.SetPieces)

local SideRadar = {}

local REVEAL_DIST = 60
local DEFAULT_PING = 20
local PING_SHOW = 6
local TUNE_TIMEOUT = 15
local HP_MAX = 100
local WRECK_RADIUS = 14
local WRECK_DPS = 3 -- per enemy at the radar (max 5 counted)
local BAND_H = 0.1 -- half width of the green band (sweep 0..1)
local GRID = 50 -- enemy blips: one per GRID x GRID stud cell

local OFF_COL = Color3.fromRGB(255, 70, 50)
local TUNE_COL = Color3.fromRGB(255, 190, 60)
local ON_COL = Color3.fromRGB(80, 255, 140)

local function tuneMode(): string
	local a = Workspace:GetAttribute("Feel_RadarTune")
	if a == "sweep2" or a == "hold" then
		return a
	end
	return "sweep3"
end

local function pingPeriod(): number
	local a = Workspace:GetAttribute("Feel_RadarPing")
	if a == "off" then
		return 0
	end
	if type(a) == "number" and a > 0 then
		return a
	end
	return DEFAULT_PING
end

local function sweepAt(t: number, t0: number, period: number): number
	local u = ((t - t0) / period) % 1
	return 1 - math.abs(2 * u - 1)
end

function SideRadar.start(ctx: any, index: number): any
	if index > 1 then
		return nil -- one radar per mission
	end
	local siteName = ctx.takeSite and ctx.takeSite("radar")
	local siteCF: CFrame? = siteName and ctx.map.sites[siteName]
	if not siteCF then
		return nil
	end
	local S = ctx.S
	local brood = ctx.faction == "BROOD"
	local base = SetPieces.groundCF(ctx.map, siteCF :: CFrame, 8)
	local pos = base.Position

	local entry = ctx.newEntry({
		id = "RADAR",
		title = if brood then "Restore the Colony Radar" else "Hijack the COG Radar",
		main = false,
		steps = { "Restart the radar generator", "Tune the radar dish" },
	})
	local ctl: any = { entry = entry }
	local alive = true
	local state = "POWER" -- POWER -> TUNE -> ONLINE <-> BROKEN
	local hp = HP_MAX
	local warned = false
	local session: any = nil

	-- ------------------------------------------------------------ build
	local f = Instance.new("Model")
	f.Name = "Radar"
	f.Parent = ctx.folder

	local metal = if brood then Color3.fromRGB(150, 128, 98) else Color3.fromRGB(96, 102, 114)
	local dark = if brood then Color3.fromRGB(70, 60, 50) else Color3.fromRGB(38, 42, 52)
	local trim = if brood then Color3.fromRGB(214, 176, 60) else Color3.fromRGB(220, 60, 46)
	local metalMat = if brood then Enum.Material.CorrodedMetal else Enum.Material.Metal

	ctx.part(f, Vector3.new(18, 1.4, 18), base * CFrame.new(0, 0.2, 0), dark, Enum.Material.Concrete)
	ctx.part(f, Vector3.new(18.4, 0.3, 1), base * CFrame.new(0, 1, -9), trim, Enum.Material.SmoothPlastic, { CanCollide = false })
	-- mast: core tube + three splayed legs
	local mastCF = base * CFrame.new(0, 0, 3)
	ctx.cyl(f, 1.8, 16, mastCF * CFrame.new(0, 8.5, 0), metal, metalMat)
	for k = 1, 3 do
		local a = k / 3 * math.pi * 2
		ctx.part(f, Vector3.new(0.8, 11, 0.8), mastCF * CFrame.new(math.cos(a) * 2.6, 5.5, math.sin(a) * 2.6) * CFrame.Angles(math.sin(a) * 0.28, 0, -math.cos(a) * 0.28), dark, metalMat, { CanCollide = false })
	end
	ctx.cyl(f, 3.2, 1, mastCF * CFrame.new(0, 16.2, 0), dark, metalMat)

	-- dish assembly: welded to an anchored hub that sweeps left / right while the radar runs
	local hubCF = mastCF * CFrame.new(0, 17.2, 0)
	local hub = ctx.part(f, Vector3.new(2.6, 1.6, 2.6), hubCF, dark, metalMat, { Name = "DishHub" })
	local function dishPart(p: BasePart)
		p.Anchored = false
		p.Massless = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		local w = Instance.new("WeldConstraint")
		w.Part0 = hub
		w.Part1 = p
		w.Parent = p
	end
	local tilt = hubCF * CFrame.new(0, 2.6, 0) * CFrame.Angles(math.rad(-55), 0, 0)
	dishPart(ctx.part(f, Vector3.new(1, 3, 1), hubCF * CFrame.new(0, 1.4, 0), metal, metalMat))
	dishPart(ctx.cyl(f, 12, 0.7, tilt, Color3.fromRGB(205, 208, 214), if brood then Enum.Material.CorrodedMetal else Enum.Material.SmoothPlastic))
	local rim = ctx.cyl(f, 12.8, 0.35, tilt * CFrame.new(0, -0.15, 0), trim, Enum.Material.SmoothPlastic)
	dishPart(rim)
	dishPart(ctx.part(f, Vector3.new(0.4, 5, 0.4), tilt * CFrame.new(0, 2.6, 0), metal, metalMat))
	local tip = ctx.ball(f, 1.3, tilt * CFrame.new(0, 5.2, 0), OFF_COL, Enum.Material.Neon)
	dishPart(tip)
	local beaconLight = ctx.light(hub, OFF_COL, 22, 1.2)

	-- console (tune) and generator (power)
	local conCF = base * CFrame.new(-5.5, 0, -5)
	ctx.part(f, Vector3.new(5, 3.2, 2.6), conCF * CFrame.new(0, 2.4, 0), dark, metalMat)
	local screen = ctx.glow(f, Vector3.new(4.2, 1.8, 0.3), conCF * CFrame.new(0, 3.4, -1.35) * CFrame.Angles(math.rad(-15), 0, 0), OFF_COL)
	local conBox = ctx.part(f, Vector3.new(5, 4, 3), conCF * CFrame.new(0, 2.5, 0), dark, metalMat, { Transparency = 1, CanCollide = false, CanQuery = false, Name = "ConsoleHit" })

	local genCF = base * CFrame.new(6, 0, -4)
	local gen = ctx.part(f, Vector3.new(4.4, 3.4, 4.4), genCF * CFrame.new(0, 2.5, 0), metal, metalMat, { Name = "Generator" })
	ctx.part(f, Vector3.new(4.6, 0.4, 4.6), genCF * CFrame.new(0, 4.3, 0), trim, Enum.Material.SmoothPlastic, { CanCollide = false })
	local exhaust = ctx.cyl(f, 1, 2.6, genCF * CFrame.new(1.2, 5.6, 1.2), dark, metalMat, { CanCollide = false })
	local genLamp = ctx.glow(f, Vector3.new(0.6, 0.6, 0.3), genCF * CFrame.new(0, 3, -2.3), OFF_COL)
	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Rate = 5
	smoke.Lifetime = NumberRange.new(1.5, 2.5)
	smoke.Speed = NumberRange.new(3, 5)
	smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 3) })
	smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
	smoke.Color = ColorSequence.new(Color3.fromRGB(70, 68, 68))
	smoke.EmissionDirection = Enum.NormalId.Right -- cylinders run along X: Right = up
	smoke.Enabled = false
	smoke.Parent = exhaust

	if brood then
		-- the colony left in a hurry: Brood goo creeping up the pad
		for k = 1, 4 do
			local a = k * 1.7 + 0.3
			ctx.ball(f, ctx.rng:NextNumber(2.5, 4.5), base * CFrame.new(math.cos(a) * 8, 0.4, math.sin(a) * 8), Color3.fromRGB(110, 70, 120), Enum.Material.Mud, { CanCollide = false })
		end
	end

	local function setColour(c: Color3)
		tip.Color = c
		screen.Color = c
		genLamp.Color = c
		beaconLight.Color = c
	end
	setColour(OFF_COL)
	ctx.setMarker(entry, pos)

	-- dish sweep: one looping tween on the anchored hub (the welded dish follows)
	local sweepTween: Tween? = nil
	local function setSweep(on: boolean)
		if sweepTween then
			sweepTween:Cancel()
			sweepTween = nil
		end
		if on then
			hub.CFrame = hubCF * CFrame.Angles(0, math.rad(-70), 0)
			local tw = TweenService:Create(hub, TweenInfo.new(3.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { CFrame = hubCF * CFrame.Angles(0, math.rad(70), 0) })
			tw:Play()
			sweepTween = tw
		end
	end

	-- ------------------------------------------------------------ marker gate (hide other sides until seen / radar up)
	local rawSetMarker = ctx.setMarker
	local tracked: { [any]: boolean } = {}
	local real: { [any]: Vector3? } = {}
	local seen: { [any]: boolean } = {}
	local shownAt: { [any]: Vector3? } = {}
	local function gated(e: any): boolean
		return e ~= entry and not e.main
	end
	local function apply(e: any)
		local p = real[e]
		if p and not seen[e] and #ctx.playersNear(p, REVEAL_DIST) > 0 then
			seen[e] = true
		end
		local want = if p and (state == "ONLINE" or seen[e]) then p else nil
		if want ~= shownAt[e] or (want == nil and e.marker ~= nil) then
			shownAt[e] = want
			rawSetMarker(e, want)
		end
	end
	local function track(e: any)
		if tracked[e] or not gated(e) then
			return
		end
		tracked[e] = true
		real[e] = if e.marker then e.marker - Vector3.new(0, 5, 0) else nil -- setMarker stores pos + 5 up
		shownAt[e] = real[e]
		apply(e)
	end
	ctx.setMarker = function(e: any, p: Vector3?)
		if not alive or not gated(e) then
			return rawSetMarker(e, p)
		end
		tracked[e] = true
		real[e] = p
		apply(e)
	end
	local function gateAll()
		for _, e in ctx.entries or {} do
			if tracked[e] then
				apply(e)
			else
				track(e)
			end
		end
	end
	gateAll()

	-- ------------------------------------------------------------ state changes
	local genPrompt: ProximityPrompt
	local tunePrompt: ProximityPrompt
	local repairPrompt: ProximityPrompt

	local function endSession(why: string?)
		local s = session
		if not s then
			return
		end
		session = nil
		if why and S and S.Fx and s.player.Parent then
			S.Fx.to(s.player, "RadarTune", { state = "close", why = why })
		end
		if state == "TUNE" then
			tunePrompt.Enabled = true
		end
	end

	local function goOnline()
		if state == "ONLINE" then
			return
		end
		local first = state == "TUNE"
		state = "ONLINE"
		hp = HP_MAX
		warned = false
		tunePrompt.Enabled = false
		repairPrompt.Enabled = false
		setColour(ON_COL)
		setSweep(true)
		Workspace:SetAttribute("RadarOnline", true)
		if first then
			ctx.completeStep(entry, 2, "Radar online - side objectives revealed!")
		else
			ctx.notify("Radar back online!", Config.Colors.Friendly)
		end
		rawSetMarker(entry, nil)
		ctx.sound("ObjectiveDone", pos)
		gateAll()
		ctx.changed(true)
		ctl.pingIn = 2 -- first ping right away
	end

	local function wreck()
		if state ~= "ONLINE" then
			return
		end
		state = "BROKEN"
		setSweep(false)
		hub.CFrame = hubCF * CFrame.Angles(math.rad(35), math.rad(25), math.rad(-20)) -- dish slumps on its mount
		setColour(OFF_COL)
		smoke.Enabled = true
		Workspace:SetAttribute("RadarOnline", false)
		repairPrompt.Enabled = true
		ctx.fx("Debris", { p = hubCF.Position, n = 18, c = metal, style = "scrap" })
		ctx.fx("Shake", { p = pos, mag = 0.8, r = 90 })
		ctx.sound("Alarm", pos)
		ctx.notify("The radar was wrecked! Repair it to restore the map.", Config.Colors.Danger)
		rawSetMarker(entry, pos)
		gateAll()
		ctx.changed(true)
	end

	genPrompt = ctx.prompt(gen, {
		action = "Restart Generator",
		object = "Radar",
		hold = 4,
		distance = 10,
		onTrigger = function()
			if state ~= "POWER" then
				return
			end
			state = "TUNE"
			genPrompt.Enabled = false
			smoke.Enabled = true
			setColour(TUNE_COL)
			ctx.completeStep(entry, 1, "Generator running - tune the dish at the console.")
			ctx.intensity("LOUD")
			tunePrompt.Enabled = true
		end,
	})

	tunePrompt = ctx.prompt(conBox, {
		action = "Tune Radar",
		object = "Radar Console",
		hold = 0.3,
		distance = 10,
		enabled = false,
		onTrigger = function(player: Player)
			if state ~= "TUNE" then
				return
			end
			local mode = tuneMode()
			if mode == "hold" then
				goOnline()
				return
			end
			if session then
				return
			end
			local now = Workspace:GetServerTimeNow()
			session = {
				player = player,
				t0 = now,
				period = ctx.rng:NextNumber(1.5, 1.9),
				c = ctx.rng:NextNumber(0.22, 0.78),
				h = BAND_H,
				need = if mode == "sweep2" then 2 else 3,
				hits = 0,
				last = -math.huge,
				expires = now + TUNE_TIMEOUT,
			}
			tunePrompt.Enabled = false
			if S and S.Fx then
				local s = session
				S.Fx.to(player, "RadarTune", { state = "open", obj = entry.id, t0 = s.t0, period = s.period, c = s.c, h = s.h, need = s.need, timeout = TUNE_TIMEOUT })
			end
		end,
	})

	repairPrompt = ctx.prompt(gen, {
		action = "Repair Radar",
		object = "Radar",
		hold = 5,
		distance = 10,
		enabled = false,
		onTrigger = function()
			if state ~= "BROKEN" then
				return
			end
			smoke.Enabled = true
			goOnline()
		end,
	})

	-- the hold-only preset is a long hold on the console; the sweep presets a short press that opens the mini-game
	local function syncTuneHold()
		local want = if tuneMode() == "hold" then 4 else 0.3
		if tunePrompt.HoldDuration ~= want then
			tunePrompt.HoldDuration = want
		end
	end
	syncTuneHold()

	-- ------------------------------------------------------------ tune validation
	function ctl.onMinigame(player: Player, objectiveId: string, payload: any)
		if objectiveId ~= entry.id then
			return
		end
		local s = session
		if not s or s.player ~= player or state ~= "TUNE" then
			return
		end
		if type(payload) ~= "table" or payload.cancel then
			endSession(nil)
			return
		end
		local t = payload.hit
		local now = Workspace:GetServerTimeNow()
		if type(t) ~= "number" or t ~= t then
			return
		end
		local root = ctx.getRoot(player)
		local ok = root ~= nil
			and (root.Position - conBox.Position).Magnitude <= 30
			and t >= s.t0
			and t <= now + 0.25
			and t >= now - 1.2
			and t >= s.last + 0.2 -- the client locks input 0.25 s after a hit (os.clock vs server time: a little slack)
			and math.abs(sweepAt(t, s.t0, s.period) - s.c) <= s.h + 0.03
		if not ok then
			if S and S.Fx then
				S.Fx.to(player, "RadarTune", { state = "reject" })
			end
			return
		end
		s.hits += 1
		s.last = t
		if S and S.Fx then
			S.Fx.to(player, "RadarTune", { state = "hit", n = s.hits })
		end
		if s.hits >= s.need then
			session = nil
			if S and S.Fx then
				S.Fx.to(player, "RadarTune", { state = "done" })
			end
			goOnline()
		end
	end

	-- test hook: finish the open tune session
	function ctl.debugSolve(player: Player): boolean
		local s = session
		if not s or s.player ~= player then
			return false
		end
		session = nil
		if S and S.Fx then
			S.Fx.to(player, "RadarTune", { state = "done" })
		end
		goOnline()
		return true
	end

	-- ------------------------------------------------------------ ping
	local function ping()
		local cells: { [string]: { sum: Vector3, n: number } } = {}
		local enemies = S and S.Enemies and S.Enemies.getAll and S.Enemies.getAll() or {}
		for _, e in enemies do
			local r = e.root
			if r and r.Parent then
				local p = r.Position
				local key = math.floor(p.X / GRID) .. ":" .. math.floor(p.Z / GRID)
				local c = cells[key]
				if c then
					c.sum += p
					c.n += 1
				else
					cells[key] = { sum = p, n = 1 }
				end
			end
		end
		local blips = {}
		for _, c in cells do
			table.insert(blips, { p = c.sum / c.n, n = c.n })
		end
		table.sort(blips, function(a, b)
			return a.n > b.n
		end)
		while #blips > 16 do
			table.remove(blips)
		end
		local d = S and S.Director
		if d and d.getSources then
			local ok, list = pcall(d.getSources)
			if ok and type(list) == "table" then
				for _, src in list do
					if typeof(src.pos) == "Vector3" and #blips < 22 then
						table.insert(blips, { p = src.pos, n = 0, src = true })
					end
				end
			end
		end
		if S and S.Fx then
			S.Fx.play("RadarPing", { blips = blips, t = PING_SHOW, o = hubCF.Position })
		end
	end

	-- ------------------------------------------------------------ main loop
	ctl.pingIn = DEFAULT_PING
	task.spawn(function()
		local waveT = 0
		local gateT = 0
		while alive and ctx.alive() do
			local dt = 0.5
			task.wait(dt)
			if not alive or not ctx.alive() then
				break
			end
			gateT += dt
			if gateT >= 1 then
				gateT = 0
				gateAll()
			end
			syncTuneHold()
			local s = session
			if s and (Workspace:GetServerTimeNow() > s.expires or not s.player.Parent or not ctx.isAlive(s.player)) then
				endSession("SIGNAL LOST - try again")
			end
			-- defenders while the squad works on it
			if state ~= "ONLINE" and #ctx.playersNear(pos, 70) > 0 then
				waveT += dt
				if waveT >= 30 then
					waveT = 0
					ctx.wave(pos, 3)
				end
			end
			if state == "ONLINE" then
				local near = S and S.Enemies and S.Enemies.getInRadius and S.Enemies.getInRadius(pos, WRECK_RADIUS) or {}
				local n = math.min(#near, 5)
				if n > 0 then
					hp -= WRECK_DPS * n * dt
					if hp <= HP_MAX * 0.5 and not warned then
						warned = true
						ctx.notify("The radar is under attack!", Config.Colors.Danger)
					end
					if hp <= 0 then
						wreck()
					end
				end
				local period = pingPeriod()
				if period > 0 then
					ctl.pingIn = math.min(ctl.pingIn - dt, period)
					if ctl.pingIn <= 0 then
						ctl.pingIn = period
						ping()
					end
				end
			end
		end
	end)

	function ctl.stop()
		alive = false
		endSession("close")
		setSweep(false)
		ctx.setMarker = rawSetMarker
		Workspace:SetAttribute("RadarOnline", nil)
	end

	return ctl
end

return SideRadar
