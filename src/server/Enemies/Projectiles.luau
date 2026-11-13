-- S.Projectiles: server-simulated enemy projectiles (data only, no parts).
-- Clients render them from Fx "Bolt" {id, a, v, g, style, c, life} and "BoltEnd" {id, p, style, r, pd?, miss?}.
-- Position at time t after spawn:  a + v*t - (0, 0.5*g*t^2, 0)   (g >= 0, studs/s^2 downward)
--
-- Projectiles.fire(spec) -> id?
--   spec = {
--     a: Vector3, v: Vector3, g: number?,           -- origin, velocity, gravity
--     style: string?,                               -- "bolt" | "cannon" | "mortar" | "acid"  (client look)
--     c: Color3?, damage: number,
--     radius: number?,                              -- splash radius (0/nil = direct hit only)
--     hitRadius: number?,                           -- thickness vs. players (default 2.4)
--     knockback: number?, life: number?, kind: string?,
--     puddle: { r: number, dur: number, dps: number }?,
--     shake: number?,                               -- camera-shake magnitude on impact
--     owner: any?,
--   }
-- Projectiles.count(), Projectiles.clear()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Damage = require(Shared.Damage)

local MAX_LIVE = 120

local Projectiles = {}

local S: { [string]: any } = {}
local live: { any } = {}
local puddles: { any } = {}
local nextId = 0
local conn: RBXScriptConnection? = nil
local puddleTimer = 0

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.RespectCanCollide = true
params.IgnoreWater = true

local function rebuildFilter()
	local list: { Instance } = {}
	local enemies = workspace:FindFirstChild("Enemies")
	if enemies then
		table.insert(list, enemies)
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	params.FilterDescendantsInstances = list
end

local function getRoot(p: Player): BasePart?
	if S.Players and S.Players.getRoot then
		return S.Players.getRoot(p)
	end
	local ch = p.Character
	return ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function aliveRoots(): { { p: Player, pos: Vector3 } }
	local out = {}
	local list = if S.Players and S.Players.getAlive then S.Players.getAlive() else Players:GetPlayers()
	for _, p in list do
		local r = getRoot(p)
		if r then
			table.insert(out, { p = p, pos = r.Position })
		end
	end
	return out
end

local function closestOnSegment(a: Vector3, b: Vector3, p: Vector3): (Vector3, number)
	local ab = b - a
	local denom = ab:Dot(ab)
	local t = 0
	if denom > 1e-6 then
		t = math.clamp((p - a):Dot(ab) / denom, 0, 1)
	end
	local q = a + ab * t
	return q, t
end

local function damagePlayer(p: Player, amount: number, from: Vector3, knock: number?, kind: string?)
	if S.Players and S.Players.damage then
		S.Players.damage(p, amount, from, { knockback = knock, kind = kind or "enemy" })
	end
end

local function finish(i: number, pr: any, pos: Vector3, hitPlayer: Player?, blocked: boolean, miss: boolean)
	-- remove (swap-remove)
	local n = #live
	live[i] = live[n]
	live[n] = nil

	local radius = pr.radius or 0
	if not blocked and not miss then
		if radius > 0 then
			for _, e in aliveRoots() do
				local d = (e.pos - pos).Magnitude
				if d < radius + 1.2 then
					local f = Damage.falloff(math.max(d - 1.2, 0), radius * 0.35, radius)
					if f > 0 then
						damagePlayer(e.p, pr.damage * f, pos, (pr.knockback or 0) * f, pr.kind)
					end
				end
			end
		elseif hitPlayer then
			damagePlayer(hitPlayer, pr.damage, pr.prev or pr.a, pr.knockback, pr.kind)
		end
		if pr.puddle then
			table.insert(puddles, {
				p = pos,
				r = pr.puddle.r,
				untilT = os.clock() + pr.puddle.dur,
				dps = pr.puddle.dps,
			})
		end
	end

	local fx = S.Fx
	if fx then
		local data: any = { id = pr.id, p = pos, style = pr.style, r = radius }
		if pr.puddle and not blocked and not miss then
			data.pd = pr.puddle.dur
		end
		if blocked then
			data.blocked = true
		end
		if miss then
			data.miss = true
		end
		fx.play("BoltEnd", data)
		if radius >= 3 and not blocked and not miss and (pr.style == "cannon" or pr.style == "mortar") then
			fx.play("Explosion", { p = pos, r = radius, size = radius >= 6 and "L" or "M", style = "fire" })
		end
		if pr.shake and pr.shake > 0 and not blocked and not miss then
			fx.playU("Shake", { p = pos, mag = pr.shake, r = 70 })
		end
	end
end

local function step(dt: number)
	local n = #live
	if n == 0 then
		return
	end
	local roots = aliveRoots()
	local blocker = S.CallIns and S.CallIns.blocksProjectile
	local i = n
	while i >= 1 do
		local pr = live[i]
		pr.t += dt
		local t = pr.t
		local prev = pr.pos
		local nextPos = pr.a + pr.v * t
		if pr.g > 0 then
			nextPos -= Vector3.new(0, 0.5 * pr.g * t * t, 0)
		end
		pr.prev = prev

		local seg = nextPos - prev
		local segLen = seg.Magnitude
		local done = false

		if segLen > 1e-4 then
			-- Shield dome etc.
			if blocker then
				local bp = blocker(prev, nextPos)
				if bp then
					finish(i, pr, bp, nil, true, false)
					done = true
				end
			end

			if not done then
				local worldHit = workspace:Raycast(prev, seg, params)
				local bestDist = if worldHit then (worldHit.Position - prev).Magnitude else math.huge
				local hitPlayer: Player? = nil
				local hitPos = if worldHit then worldHit.Position else nextPos
				local hr = pr.hitRadius
				for _, e in roots do
					local q = closestOnSegment(prev, nextPos, e.pos)
					if (e.pos - q).Magnitude <= hr then
						local d = (q - prev).Magnitude
						if d < bestDist then
							bestDist = d
							hitPlayer = e.p
							hitPos = q
						end
					end
				end
				if hitPlayer or worldHit then
					finish(i, pr, hitPos, hitPlayer, false, false)
					done = true
				end
			end
		end

		if not done then
			pr.pos = nextPos
			if t >= pr.life then
				finish(i, pr, nextPos, nil, false, true)
			end
		end
		i -= 1
	end
end

local function tickPuddles(dt: number)
	if #puddles == 0 then
		return
	end
	puddleTimer += dt
	local now = os.clock()
	if puddleTimer < 0.4 then
		-- still expire promptly
		for i = #puddles, 1, -1 do
			if puddles[i].untilT <= now then
				table.remove(puddles, i)
			end
		end
		return
	end
	local tickDt = puddleTimer
	puddleTimer = 0
	local roots = aliveRoots()
	for i = #puddles, 1, -1 do
		local pd = puddles[i]
		if pd.untilT <= now then
			table.remove(puddles, i)
		else
			for _, e in roots do
				local d = Vector3.new(e.pos.X - pd.p.X, 0, e.pos.Z - pd.p.Z).Magnitude
				if d <= pd.r and math.abs(e.pos.Y - pd.p.Y) <= 5 then
					damagePlayer(e.p, pd.dps * tickDt, pd.p, 0, "acid")
				end
			end
		end
	end
end

local function connect()
	if conn then
		return
	end
	conn = RunService.Heartbeat:Connect(function(dt)
		step(dt)
		tickPuddles(dt)
	end)
end

function Projectiles.fire(spec: any): number?
	if #live >= MAX_LIVE then
		return nil
	end
	nextId += 1
	local id = nextId
	local pr = {
		id = id,
		a = spec.a,
		pos = spec.a,
		prev = spec.a,
		v = spec.v,
		g = spec.g or 0,
		t = 0,
		life = spec.life or 5,
		style = spec.style or "bolt",
		c = spec.c,
		damage = spec.damage or 0,
		radius = spec.radius or 0,
		hitRadius = spec.hitRadius or 2.4,
		knockback = spec.knockback,
		kind = spec.kind,
		puddle = spec.puddle,
		shake = spec.shake,
		owner = spec.owner,
	}
	table.insert(live, pr)
	if S.Fx then
		S.Fx.play("Bolt", { id = id, a = pr.a, v = pr.v, g = pr.g, style = pr.style, c = pr.c, life = pr.life, r = pr.radius })
	end
	return id
end

function Projectiles.count(): number
	return #live
end

function Projectiles.clear()
	if S.Fx then
		for _, pr in live do
			S.Fx.play("BoltEnd", { id = pr.id, p = pr.pos, style = pr.style, r = 0, miss = true })
		end
	end
	table.clear(live)
	table.clear(puddles)
end

-- Ballistic helper: velocity that carries a projectile from a to b in T seconds under gravity g.
function Projectiles.solveArc(a: Vector3, b: Vector3, T: number, g: number): Vector3
	local d = b - a
	return Vector3.new(d.X / T, d.Y / T + 0.5 * g * T, d.Z / T)
end

function Projectiles.init(s: { [string]: any })
	S = s
	rebuildFilter()
	Players.PlayerAdded:Connect(function(p)
		p.CharacterAdded:Connect(function()
			task.defer(rebuildFilter)
		end)
		rebuildFilter()
	end)
	for _, p in Players:GetPlayers() do
		p.CharacterAdded:Connect(function()
			task.defer(rebuildFilter)
		end)
	end
	Players.PlayerRemoving:Connect(function()
		task.defer(rebuildFilter)
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			rebuildFilter()
		end
	end)
	connect()
end

function Projectiles.start()
	connect()
end

return Projectiles
