-- S.Projectiles: server-simulated enemy projectiles (data only, no parts).
-- Clients render them from Fx "Bolt" {id, a, v, g, style, c, life, o?} and "BoltEnd" {id, p, style, r, pd?, miss?, hit?}.
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
--     spare: Player?,                               -- never hits this player (enemy warning shots, EnemyAI.shootBolt)
--   }
-- Projectiles.count(), Projectiles.clear()
-- Projectiles.speedMul(kind?, style?) -> number   speed factor fire() applies to straight shots (aim lead can use it)
--
-- Straight (g == 0) shots are slowed per kind / style (SPEED_MUL) so they can be sidestepped at mid range; life is
-- stretched by the same factor, so range is unchanged. The Bolt payload carries the final velocity, so the client
-- draws exactly what the server hit-tests. Bolt payload extra (optional): o = owner enemy id (client muzzle cache).
-- Studio A/B: workspace attribute Feel_BoltSpeed (number, default 1) scales every SPEED_MUL entry.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Damage = require(Shared.Damage)
local Decoys = require(script.Parent.Parent.Decoys) -- Holo Decoy targets: shots / splash damage them, no player API involved

local MAX_LIVE = 120

-- by spec.kind first, then spec.style. High-velocity ballistic speeds: Tinker 155, Rivet 165, Bulwark 130, Bastion 125.
local SPEED_MUL: { [string]: number } = { bolt = 1.0, cannon = 1.0 }
local IS_STUDIO = RunService:IsStudio()

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

local function finish(i: number, pr: any, pos: Vector3, hitPlayer: Player?, blocked: boolean, miss: boolean, hitDecoy: any?)
	-- remove (swap-remove)
	local n = #live
	live[i] = live[n]
	live[n] = nil

	local radius = pr.radius or 0
	-- explosive projectiles go through the shared blast (server/Explosions.luau) for trooper damage, falloff, god mode,
	-- and knockdown, with no enemy damage or onBlast listeners (acid splash skips the fireball Blast fx)
	local isBlastVisual = radius >= 3 and (pr.style == "cannon" or pr.style == "mortar")
	local useExplosions = radius > 0 and S.Explosions ~= nil and S.Explosions.blast ~= nil
	if not blocked and not miss then
		if radius > 0 then
			if useExplosions then
				S.Explosions.blast(pos, {
					radius = radius,
					core = radius * 0.35,
					damage = 0,
					noDamage = true,
					noEmit = true,
					noFx = not isBlastVisual,
					playerDamage = pr.damage,
					playerKind = pr.kind or "enemy",
					knock = pr.knockback or 0,
					size = if radius >= 6 then "L" else "M",
					style = "fire",
				}, { kind = pr.kind or "enemy" })
			else
				local falloff = if S.Explosions and S.Explosions.playerFalloff then S.Explosions.playerFalloff else Damage.falloff
				for _, e in aliveRoots() do
					local d = (e.pos - pos).Magnitude
					if d < radius then
						local f = falloff(d, radius * 0.35, radius)
						if f > 0 then
							damagePlayer(e.p, pr.damage * f, pos, (pr.knockback or 0) * f, pr.kind)
						end
					end
				end
			end
		elseif hitPlayer then
			damagePlayer(hitPlayer, pr.damage, pr.prev or pr.a, pr.knockback, pr.kind)
		end
		if Decoys.count() > 0 then
			-- hologram: direct hit damages it, a splash hurts every decoy in range (falloff like troopers); nothing else happens
			if radius > 0 then
				local falloff = if S.Explosions and S.Explosions.playerFalloff then S.Explosions.playerFalloff else Damage.falloff
				for _, d in Decoys.list do
					local dd = (d.pos - pos).Magnitude
					if d.alive and dd < radius + 1.2 then
						local f = falloff(math.max(dd - 1.2, 0), radius * 0.35, radius)
						if f > 0 then
							Decoys.damage(d, pr.damage * f)
						end
					end
				end
			elseif hitDecoy then
				Decoys.damage(hitDecoy, pr.damage)
			end
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
		local data: any = { id = pr.id, p = pos, style = pr.style, r = radius, cls = pr.cls, hv = pr.heavy }
		if pr.puddle and not blocked and not miss then
			data.pd = pr.puddle.dur
		end
		if blocked then
			data.blocked = true
		end
		if miss then
			data.miss = true
		end
		if (hitPlayer or hitDecoy) and not blocked and not miss then
			data.hit = true -- struck a trooper / decoy: the client plays the bigger impact
		end
		fx.play("BoltEnd", data)
		if not useExplosions and isBlastVisual and not blocked and not miss then
			fx.play("Explosion", { p = pos, r = radius, size = radius >= 6 and "L" or "M", style = "fire" })
		end
		if pr.shake and pr.shake > 0 and not blocked and not miss then
			fx.playU("Shake", { p = pos, mag = pr.shake, r = if pr.heavy or isBlastVisual then 115 else 75 })
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
					if e.p == pr.spare then
						continue -- warning shot: flies past this player on purpose
					end
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
				-- Holo Decoys (a hit that is nearer than any trooper / wall wins; the shot then ends there)
				local hitDecoy: any = nil
				if Decoys.count() > 0 then
					for _, d in Decoys.list do
						if d.alive then
							local q = closestOnSegment(prev, nextPos, d.pos)
							if (d.pos - q).Magnitude <= hr + d.hitRadius then
								local dist = (q - prev).Magnitude
								if dist < bestDist then
									bestDist = dist
									hitDecoy = d
									hitPlayer = nil
									hitPos = q
								end
							end
						end
					end
				end
				if hitPlayer or hitDecoy or worldHit then
					finish(i, pr, hitPos, hitPlayer, false, false, hitDecoy)
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

function Projectiles.speedMul(kind: string?, style: string?): number
	local m = (kind and SPEED_MUL[kind]) or (style and SPEED_MUL[style])
	if not m then
		return 1
	end
	if IS_STUDIO then
		local k = workspace:GetAttribute("Feel_BoltSpeed")
		if type(k) == "number" and k > 0 then
			m *= math.clamp(k, 0.3, 3)
		end
	end
	return m
end

function Projectiles.fire(spec: any): number?
	if #live >= MAX_LIVE then
		return nil
	end
	nextId += 1
	local id = nextId
	local v: Vector3 = spec.v
	local life: number = spec.life or 5
	if (spec.g or 0) <= 0 then
		local m = Projectiles.speedMul(spec.kind, spec.style or "bolt")
		if m ~= 1 then
			v *= m
			life /= m
		end
	end
	local owner = spec.owner
	local oid = if type(owner) == "table" then owner.id else nil
	local cls = if type(owner) == "table" then owner.class else nil
	local ek = if type(owner) == "table" then owner.kind else nil
	local heavy = spec.heavy == true or spec.style == "cannon" or spec.style == "mortar" or cls == "heavy" or cls == "behemoth"
	local pr = {
		id = id,
		a = spec.a,
		pos = spec.a,
		prev = spec.a,
		v = v,
		g = spec.g or 0,
		t = 0,
		life = life,
		style = spec.style or "bolt",
		c = spec.c,
		damage = spec.damage or 0,
		radius = spec.radius or 0,
		hitRadius = spec.hitRadius or 2.4,
		knockback = spec.knockback,
		kind = spec.kind,
		puddle = spec.puddle,
		shake = spec.shake,
		owner = owner,
		cls = cls,
		ek = ek,
		heavy = heavy,
		spare = spec.spare,
	}
	table.insert(live, pr)
	if S.Fx then
		S.Fx.play("Bolt", {
			id = id, a = pr.a, v = pr.v, g = pr.g, style = pr.style, c = pr.c, life = pr.life, r = pr.radius,
			o = oid, cls = cls, ek = ek, hv = if heavy then true else nil,
		})
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
