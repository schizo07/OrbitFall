-- Side objective CONVOY (COG planets only): Strider Colossus walkers cross the map on a fixed route, edge to edge in about
-- 3.5 minutes, and keep shooting at troopers in range. Stop every walker before one reaches the far border.
--   SideConvoy.start(ctx, index) -> controller { entry, stop, debugSolve } or nil (BROOD planet / spawn failed)
-- The walkers come from S.Enemies.spawn (kill credit, call-ins and wrecks work as usual). Their route is the per-enemy fields
-- e.routeTo (next waypoint, Vector3) and e.routeSpeed (0..1 of def.speed), honoured by server/Enemies/EnemyAI.think.
-- One walker (red blinking antenna) carries a call-in jammer: S.Jammers.add(id, getPos, radius) while it lives (server/Jammers,
-- guarded by pcall so a missing module no-ops).
-- Failure: when a walker reaches the last waypoint the remaining walkers leave, the step reads "missed" and the entry stays
-- not done, so it earns no side-objective reward.
-- Studio A/B "CONVOY" (client/Variants, server = mirrored): workspace attribute Feel_ConvoyCount = nil (A 3) | 2 | 5, read at start.
-- Studio: workspace attribute QuickStartSides = "CONVOY".

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local EnemyData = require(Shared.Data.Enemies)

local SideConvoy = {}

local WALKER = "COLOSSUS"
local CROSS_SECONDS = 210 -- target time for one walker to cover the whole route
local HP_FRAC = 0.6 -- share of the usual Colossus health (x difficulty scale): three of them in one crossing
local REACH = 16 -- studs: waypoint reached
local SPACING = 22 -- studs between walkers at the start
local JAM_RADIUS = 40
local TICK = 0.5

-- (x, z) waypoints; the first leg is long enough to line up five walkers. Each route can also run in reverse.
local ROUTES: { { Vector2 } } = {
	{ Vector2.new(-228, 70), Vector2.new(-110, 45), Vector2.new(-30, 62), Vector2.new(35, 28), Vector2.new(110, 52), Vector2.new(190, 22), Vector2.new(232, 30) },
	{ Vector2.new(-40, -232), Vector2.new(-62, -120), Vector2.new(-20, -50), Vector2.new(-62, 22), Vector2.new(8, 110), Vector2.new(-30, 178), Vector2.new(-14, 232) },
}

local RED = Color3.fromRGB(255, 52, 40)
local MAST = Color3.fromRGB(70, 74, 86)

local function walkerCount(): number
	local v = workspace:GetAttribute("Feel_ConvoyCount")
	if type(v) == "number" then
		return math.clamp(math.floor(v), 1, 6)
	end
	return 3
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- red blinking antenna on top of the walker's hull (welded to the root, so it follows every PivotTo)
local function addAntenna(e: any): BasePart?
	local model: Model = e.model
	local root: BasePart = e.root
	if not model or not root then
		return nil
	end
	local bbCF, bbSize = model:GetBoundingBox()
	local top = root.CFrame:PointToObjectSpace(bbCF.Position + Vector3.new(0, bbSize.Y / 2, 0))
	local function mk(size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material, shape: Enum.PartType?): Part
		local p = Instance.new("Part")
		p.Size = size
		p.Color = color
		p.Material = mat
		p.Anchored = false
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.CastShadow = false
		if shape then
			p.Shape = shape
		end
		p.CFrame = root.CFrame * cf
		local w = Instance.new("WeldConstraint")
		w.Part0 = root
		w.Part1 = p
		w.Parent = p
		p.Parent = model
		return p
	end
	mk(Vector3.new(0.7, 9, 0.7), CFrame.new(0, top.Y + 3, 0), MAST, Enum.Material.Metal)
	local ball = mk(Vector3.new(3.2, 3.2, 3.2), CFrame.new(0, top.Y + 8, 0), RED, Enum.Material.Neon, Enum.PartType.Ball)
	local l = Instance.new("PointLight")
	l.Color = Color3.fromRGB(255, 120, 100)
	l.Range = 30
	l.Brightness = 1.4
	l.Shadows = false
	l.Parent = ball
	return ball
end

function SideConvoy.start(ctx: any, index: number): any
	local S = ctx.S
	if ctx.faction ~= "COG" or not S or not S.Enemies then
		return nil
	end
	local map = ctx.map
	local rng = ctx.rng
	local count = walkerCount()

	-- pick a route and a direction
	local src = ROUTES[rng:NextInteger(1, #ROUTES)]
	local reverse = rng:NextInteger(0, 1) == 1
	local route: { Vector3 } = {}
	for i = 1, #src do
		local v = src[if reverse then #src + 1 - i else i]
		local y = if map.groundY then map.groundY(v.X, v.Y) else 0
		route[i] = Vector3.new(v.X, y, v.Y)
	end
	local cum: { number } = { 0 }
	for i = 2, #route do
		cum[i] = cum[i - 1] + flat(route[i] - route[i - 1]).Magnitude
	end
	local total = cum[#route]
	local def = EnemyData.get(WALKER)
	local speedFrac = math.clamp(total / (CROSS_SECONDS * def.speed), 0.15, 1)

	local d0 = flat(route[2] - route[1]).Unit
	local side = Vector3.new(-d0.Z, 0, d0.X)
	local walkers: { any } = {}
	local jammerIdx = if count >= 2 then 2 else 1
	for i = 1, count do
		-- walkers[1] leads; the rest line up behind it, a little to alternate sides
		local fwd = (count - i) * SPACING
		local lateral = if count == 1 then 0 else (if i % 2 == 0 then 9 else -9)
		local p = route[1] + d0 * fwd + side * lateral
		local gy = if map.groundY then map.groundY(p.X, p.Z) else p.Y
		p = Vector3.new(p.X, gy, p.Z)
		local scale = (Config.DifficultyHpScale[math.clamp(math.floor(ctx.difficulty or 1), 1, #Config.DifficultyHpScale)] or 1) * HP_FRAC
		local ok, e = pcall(S.Enemies.spawn, WALKER, CFrame.lookAt(p, p + d0), { hpScale = scale, aggro = false })
		if ok and e then
			e.routeTo = route[2]
			e.routeSpeed = speedFrac
			e.model:SetAttribute("ConvoyWalker", true)
			local w: any = { e = e, idx = 2, dead = false, jammer = i == jammerIdx }
			if w.jammer then
				w.lamp = addAntenna(e)
			end
			walkers[#walkers + 1] = w
		else
			warn("[Convoy] walker spawn failed:", e)
		end
	end
	if #walkers == 0 then
		return nil
	end
	count = #walkers

	local id = if index > 1 then "CONVOY" .. index else "CONVOY"
	local entry = ctx.newEntry({ id = id, title = "Stop the Strider Convoy", main = false, steps = { string.format("Stop the convoy  0/%d", count) } })
	local ctl: any = { entry = entry }

	-- jammer registration (agent-independent: no-ops when the module is missing)
	local jamId = "convoy" .. index
	local jamWalker: any = nil
	for _, w in walkers do
		if w.jammer then
			jamWalker = w
		end
	end
	local jamActive = false
	local function jamOff()
		if jamActive then
			jamActive = false
			local J = S.Jammers
			if J and J.remove then
				pcall(J.remove, jamId)
			end
		end
	end
	if jamWalker then
		local J = S.Jammers
		if J and J.add then
			local e = jamWalker.e
			local ok = pcall(J.add, jamId, function(): Vector3?
				if e.alive and e.pos then
					return e.pos
				end
				return nil
			end, JAM_RADIUS)
			jamActive = ok
		end
	end

	local finished = false
	local killed = 0
	local warned = false
	local alive = true

	local function setText(text: string)
		local st = entry.steps[1]
		st.text = text
		st.progress = killed / count
	end

	local function leadWalker(): any
		local best, bestProg = nil, -1
		for _, w in walkers do
			if not w.dead and w.e.alive then
				local prog = cum[w.idx] - flat(route[w.idx] - w.e.pos).Magnitude
				if prog > bestProg then
					bestProg = prog
					best = w
				end
			end
		end
		return best
	end

	local function fail()
		finished = true
		jamOff()
		for _, w in walkers do
			if w.e.alive then
				pcall(S.Enemies.despawn, w.e)
			end
		end
		local st = entry.steps[1]
		st.text = "The convoy crossed the border (missed)"
		st.active = false
		st.done = false
		st.progress = nil
		ctx.setMarker(entry, nil)
		ctx.notify("A convoy walker crossed the border - objective missed", Config.Colors.Danger)
		ctx.sound("Alarm", nil)
		ctx.changed(true)
	end

	ctx.notify(string.format("COG convoy crossing the map: stop all %d walkers. The one with the red antenna jams call-ins.", count), Config.Colors.Danger)
	ctx.setMarker(entry, walkers[1].e.pos)

	task.spawn(function()
		local tick = 0
		while alive and ctx.alive() and not finished do
			task.wait(TICK)
			tick += 1
			local newKills = 0
			for _, w in walkers do
				local e = w.e
				if not w.dead then
					if not e.alive then
						w.dead = true
						newKills += 1
						if w.jammer then
							jamOff()
							ctx.notify("Jammer walker down - call-ins are back", Config.Colors.Friendly)
						end
					else
						local wp = route[w.idx]
						if flat(wp - e.pos).Magnitude < REACH then
							if w.idx >= #route then
								fail()
								return
							end
							w.idx += 1
							e.routeTo = route[w.idx]
						end
						-- jammer lamp blink
						if w.lamp and tick % 2 == 0 then
							w.lamp.Transparency = if w.lamp.Transparency > 0.5 then 0 else 0.7
						end
					end
				end
			end
			if newKills > 0 then
				killed += newKills
				if killed >= count then
					finished = true
					jamOff()
					local st = entry.steps[1]
					st.text = string.format("Stop the convoy  %d/%d", killed, count)
					ctx.completeStep(entry, 1, "Convoy destroyed!")
					ctx.setMarker(entry, nil)
					return
				end
				setText(string.format("Stop the convoy  %d/%d", killed, count))
				ctx.notify(string.format("Convoy walker down (%d/%d)", killed, count), Config.Colors.Gold)
				ctx.changed(true)
			end
			local lead = leadWalker()
			if lead then
				if tick % 2 == 0 then
					ctx.setMarker(entry, lead.e.pos)
				end
				if not warned and cum[lead.idx] - flat(route[lead.idx] - lead.e.pos).Magnitude > total - 90 then
					warned = true
					ctx.notify("The convoy is nearing the border!", Config.Colors.Danger)
				end
			end
		end
	end)

	-- Studio / DebugHook "solve": kill every walker that is left
	function ctl.debugSolve(_player: Player): boolean
		if finished then
			return false
		end
		for _, w in walkers do
			if w.e.alive then
				pcall(S.Enemies.damage, w.e, 1e9, 99, { kind = "objective" }, "body")
			end
		end
		return true
	end

	function ctl.stop()
		alive = false
		jamOff()
		for _, w in walkers do
			if w.e.alive then
				pcall(S.Enemies.despawn, w.e)
			end
		end
	end

	return ctl
end

return SideConvoy
