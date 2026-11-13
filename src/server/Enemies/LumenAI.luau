-- LUMEN CONCORD behaviours (faction "LUMEN"). Not a service: EnemyAI requires it and calls the hooks below.
--
-- Hooks (all called from EnemyAI.luau, each marked "-- LUMEN hook"):
--   LumenAI.init(S)                         from EnemyAI.init
--   LumenAI.install(H)                      once, hands over EnemyAI's attack tables + helpers; adds the attack kinds
--   LumenAI.eligible(e, atk, dist, aimErr, los, now) -> boolean   for attack kinds EnemyAI does not know
--   LumenAI.register(e) / LumenAI.unregister(e)
--   LumenAI.update(e, dt, now)              every Heartbeat for enemies with e.lumen (blink, nodes, shield)
--
-- Attack kinds (Data/Enemies):
--   needle  volley of hard-light needles (server Projectiles, style "bolt", violet). count / interval / spread.
--   beam    Prism Lancer: locks a straight line, Telegraph line + LumenCharge for `windup`, then an instant LumenBeam
--           hitting everyone within `radius` of the line. Stops at walls and Shield Domes.
--   pulse   Choir Spire: Telegraph circle of `radius` for `windup`, then a LumenPulse ring that hits everyone inside.
--   rift    Choir Spire: opens a RiftGate beside itself during the wind-up, then `count` x `unit` warp in.
-- Passive:
--   blink   (def.blink) Warden: a player holding their aim on it for def.blink.aim seconds makes it Blink sideways.
--   nodes   (def.nodes) Spire: parts named Node* open (Neon violet, Zone "node") and close (ceramic, Zone "body").
--   shield  parts in Zone "shield" fade out while the unit is stunned (EMP), matching EnemyService.resolveZone.
--
-- Fx sent (client/Fx/LumenFx.luau): LumenCharge, LumenBeam, LumenPulse, Blink, RiftGate (+ Telegraph via EnemyAI).

local LumenAI = {}

local S: { [string]: any } = {}
local H: any = nil
local rng = Random.new()

local VIOLET = Color3.fromRGB(192, 96, 255)
local NEEDLE = Color3.fromRGB(214, 150, 255)
local NODE_OPEN = Color3.fromRGB(200, 110, 255)
local NODE_SHUT = Color3.fromRGB(196, 186, 176)

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function LumenAI.init(s: { [string]: any })
	S = s
end

-- Attacks ----------------------------------------------------------------------------------
local function needleShot(e: any, a: any, atk: any, k: number)
	local t = H.targetEntry(e)
	if not t then
		return false
	end
	local from = H.muzzleWorld(e)
	local speed = atk.speed or 140
	local pt = H.aimPoint(from, t, speed, 0.5)
	local dir = (pt - from)
	if dir.Magnitude < 0.1 then
		return false
	end
	dir = dir.Unit
	local n = atk.count or 1
	local spread = atk.spread or 2
	-- big volleys fan out evenly left-to-right; small ones jitter
	if n >= 5 then
		local frac = if n > 1 then (k - 1) / (n - 1) - 0.5 else 0
		dir = CFrame.Angles(0, math.rad(spread * frac * 2), 0) * dir
		dir = H.spreadDir(dir, 1)
	else
		dir = H.spreadDir(dir, spread)
	end
	S.Projectiles.fire({
		a = from,
		v = dir * speed,
		style = "bolt",
		c = NEEDLE,
		damage = atk.damage,
		hitRadius = 2,
		life = atk.range / speed + 0.5,
		kind = "needle",
		owner = e,
	})
	return true
end

local function installAttacks()
	local PREP, FIRE, ACTIVE = H.PREP, H.FIRE, H.ACTIVE

	-- needle ----------------------------------------------------------------------------
	FIRE.needle = function(e, a, atk, now)
		a.phase = "active"
		a.k = 0
		a.nextShot = now
	end
	ACTIVE.needle = function(e, a, atk, dt, now)
		if now >= a.nextShot then
			a.k += 1
			local ok = needleShot(e, a, atk, a.k)
			a.nextShot = now + (atk.interval or 0.12)
			if not ok or a.k >= (atk.count or 1) then
				e.act = nil
			end
		end
		return false
	end

	-- beam ------------------------------------------------------------------------------
	PREP.beam = function(e, a, atk, now)
		local t = H.targetEntry(e)
		if not t then
			return
		end
		local dir = flat(t.pos - e.pos)
		dir = if dir.Magnitude > 0.1 then dir.Unit else H.heading(e.yaw)
		local len = atk.range
		local origin = H.muzzleWorld(e, "lens")
		local hit = workspace:Raycast(origin, dir * len, H.envParams)
		if hit then
			len = math.max((hit.Position - origin).Magnitude, 6)
		end
		a.dir = dir
		a.len = len
		a.lockFace = true
		e.faceDirOverride = dir
		local w = (atk.radius or 2.6) * 2
		H.telegraphLine(e.pos, e.pos + dir * len, w, atk.windup or 1.2)
		S.Fx.play("LumenCharge", { p = origin, t = atk.windup or 1.2, s = 1.6, id = e.id })
	end
	FIRE.beam = function(e, a, atk, now)
		if not a.dir then
			e.act = nil
			return
		end
		local origin = H.muzzleWorld(e, "lens")
		local dir: Vector3 = a.dir
		local len: number = a.len
		local endG = e.pos + dir * len
		local b = Vector3.new(endG.X, H.groundAt(endG.X, endG.Z, e.pos.Y) + 2.5, endG.Z)
		-- Shield Dome (call-in) stops hard light like any projectile
		local ci = S.CallIns
		if ci and ci.blocksProjectile then
			local ok, stop = pcall(ci.blocksProjectile, origin, b)
			if ok and typeof(stop) == "Vector3" then
				b = stop
				len = flat(stop - e.pos).Magnitude
			end
		end
		local r = (atk.radius or 2.6) + 0.8
		for _, t in H.targets do
			local rel = flat(t.pos - e.pos)
			local along = rel:Dot(dir)
			if along > 0 and along < len then
				local perp = (rel - dir * along).Magnitude
				if perp <= r and math.abs(t.pos.Y - e.pos.Y) < 9 then
					H.damagePlayer(t.p, atk.damage, e.pos, 50, "laser")
				end
			end
		end
		S.Fx.play("LumenBeam", { a = origin, b = b, w = (atk.radius or 2.6) * 0.8, t = 0.5 })
		S.Fx.playU("Shake", { p = b, mag = 0.6, r = 50 })
		-- brief recoil: holds still for a moment (the opening to shoot the lens)
		a.phase = "active"
		a.endAt = now + 0.7
	end
	ACTIVE.beam = function(e, a, atk, dt, now)
		if now >= a.endAt then
			e.act = nil
		end
		return false
	end

	-- pulse -----------------------------------------------------------------------------
	PREP.pulse = function(e, a, atk, now)
		H.telegraphCircle(e.pos, atk.radius or 26, atk.windup or 1.6)
		S.Fx.play("LumenCharge", { p = H.muzzleWorld(e, "core"), t = atk.windup or 1.6, s = 5, id = e.id })
	end
	FIRE.pulse = function(e, a, atk, now)
		local r = atk.radius or 26
		for _, t in H.targets do
			if flat(t.pos - e.pos).Magnitude <= r and math.abs(t.pos.Y - e.pos.Y) < 12 then
				H.damagePlayer(t.p, atk.damage, e.pos, 55, "pulse")
			end
		end
		S.Fx.play("LumenPulse", { p = e.pos + Vector3.new(0, 0.6, 0), r = r })
		S.Fx.playU("Shake", { p = e.pos, mag = 1.4, r = 90 })
		e.act = nil
	end

	-- rift ------------------------------------------------------------------------------
	PREP.rift = function(e, a, atk, now)
		local t = H.targetEntry(e)
		local toward = if t then flat(t.pos - e.pos) else H.heading(e.yaw)
		toward = if toward.Magnitude > 0.1 then toward.Unit else H.heading(e.yaw)
		local side = Vector3.new(-toward.Z, 0, toward.X) * (if rng:NextNumber() < 0.5 then 1 else -1)
		local p = H.clampMap(e.pos + (toward * 0.6 + side).Unit * (e.def.size + 7))
		p = Vector3.new(p.X, H.groundAt(p.X, p.Z, e.pos.Y), p.Z)
		a.gate = p
		S.Fx.play("RiftGate", { p = p, r = 4.5, t = (atk.windup or 1.4) + 1.0 })
	end
	FIRE.rift = function(e, a, atk, now)
		local gate: Vector3? = a.gate
		e.act = nil
		if not gate then
			return
		end
		local room = H.liveCap() - S.Enemies.count()
		local n = math.max(math.min(atk.count or 4, room), 0)
		local target = e.target
		for k = 1, n do
			local ang = (k / math.max(n, 1)) * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
			local p = H.clampMap(gate + Vector3.new(math.cos(ang), 0, math.sin(ang)) * rng:NextNumber(2, 4.5))
			p = Vector3.new(p.X, H.groundAt(p.X, p.Z, gate.Y), p.Z)
			S.Enemies.spawn(atk.unit or "SHARDLING", CFrame.new(p) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), {
				aggro = true,
				target = target,
				patrol = true,
			})
		end
	end

	-- tuning tables (movement lock while winding up / firing, default wind-ups)
	H.NOMOVE.beam = true
	H.NOMOVE.pulse = true
	H.NOMOVE.rift = true
	H.DEFAULT_WINDUP.needle = 0.25
	H.DEFAULT_WINDUP.beam = 1.2
	H.DEFAULT_WINDUP.pulse = 1.6
	H.DEFAULT_WINDUP.rift = 1.4
end

function LumenAI.install(h: any)
	H = h
	installAttacks()
end

function LumenAI.eligible(e: any, atk: any, dist: number, aimErr: number, los: boolean, now: number): boolean
	local k = atk.kind
	if k == "needle" then
		return dist <= atk.range * 0.95 and aimErr < 0.6 and los
	elseif k == "beam" then
		return dist >= 12 and dist <= atk.range * 0.9 and aimErr < 0.45 and los
	elseif k == "pulse" then
		return dist <= (atk.radius or atk.range) * 0.95
	elseif k == "rift" then
		return dist <= atk.range and S.Enemies.count() < H.liveCap() - 4
	end
	return false
end

-- Registration -----------------------------------------------------------------------------
function LumenAI.register(e: any)
	if e.faction ~= "LUMEN" then
		return
	end
	local L: any = { aimT = 0, blinkAt = 0, nodes = {}, shields = {}, shieldOff = false }
	for _, d in e.model:GetDescendants() do
		if d:IsA("BasePart") then
			if string.sub(d.Name, 1, 4) == "Node" then
				table.insert(L.nodes, d)
			elseif d:GetAttribute("Zone") == "shield" then
				table.insert(L.shields, { part = d, t = d.Transparency })
			end
		end
	end
	local nd = e.def.nodes
	if nd and #L.nodes > 0 then
		L.nodeOpen = true
		L.nodeNext = workspace:GetServerTimeNow() + nd.open * rng:NextNumber(0.4, 1)
	end
	e.lumen = L
end

function LumenAI.unregister(e: any)
	e.lumen = nil
end

-- Passive behaviours ---------------------------------------------------------------------------
local function setNodes(e: any, open: boolean)
	local L = e.lumen
	L.nodeOpen = open
	for _, p in L.nodes do
		if p.Parent then
			p:SetAttribute("Zone", if open then "node" else "body")
			p.Material = if open then Enum.Material.Neon else Enum.Material.SmoothPlastic
			p.Color = if open then NODE_OPEN else NODE_SHUT
		end
	end
	if open then
		S.Fx.play("LumenCharge", { p = e.pos + Vector3.new(0, e.def.size * 1.3, 0), t = 0.35, s = 3, id = e.id })
	end
end

-- Warden blink: sideways relative to whoever is aiming at it, never through walls / off cliffs
local function tryBlink(e: any, from: Vector3, now: number): boolean
	local away = flat(e.pos - from)
	away = if away.Magnitude > 0.1 then away.Unit else H.heading(e.yaw)
	local side = Vector3.new(-away.Z, 0, away.X)
	local sign = if rng:NextNumber() < 0.5 then 1 else -1
	local dist = e.def.blink.dist * rng:NextNumber(0.8, 1.15)
	local eye = e.pos + Vector3.new(0, 3, 0)
	for attempt = 1, 4 do
		local s = if attempt % 2 == 1 then sign else -sign
		local d = dist * (if attempt > 2 then 0.6 else 1)
		local dir = (side * s + away * rng:NextNumber(-0.25, 0.25)).Unit
		local want = H.clampMap(e.pos + dir * d)
		if workspace:Raycast(eye, (want + Vector3.new(0, 3, 0)) - eye, H.envParams) == nil then
			local gy = H.groundAt(want.X, want.Z, e.pos.Y)
			if math.abs(gy - e.pos.Y) < 8 then
				local a = e.pos
				e.pos = Vector3.new(want.X, gy, want.Z)
				e.vel = Vector3.zero
				e.needSnap = true
				e.strafeDir = -(e.strafeDir or 1)
				local h = math.min(e.def.size, 3) + 1.5
				S.Fx.play("Blink", { a = a + Vector3.new(0, h, 0), b = e.pos + Vector3.new(0, h, 0), s = e.def.size })
				return true
			end
		end
	end
	return false
end

function LumenAI.update(e: any, dt: number, now: number)
	local L = e.lumen
	if not L then
		return
	end
	local stunned = e.status.stun ~= nil and e.status.stun.untilT > now

	-- hard-light shield drops while stunned (EnemyService.resolveZone already lets shots through)
	if #L.shields > 0 and stunned ~= L.shieldOff then
		L.shieldOff = stunned
		for _, s in L.shields do
			if s.part.Parent then
				s.part.Transparency = if stunned then 1 else s.t
			end
		end
	end

	-- resonance nodes
	local nd = e.def.nodes
	if nd and L.nodeNext and now >= L.nodeNext then
		local open = not L.nodeOpen
		L.nodeNext = now + (if open then nd.open else nd.closed)
		setNodes(e, open)
	end

	-- blink when aimed at
	local bl = e.def.blink
	if bl and not stunned then
		local aimer: Vector3? = nil
		for _, t in H.targets do
			local look = flat(t.root.CFrame.LookVector)
			if look.Magnitude < 0.05 then
				continue
			end
			look = look.Unit
			local rel = flat(e.pos - t.pos)
			local along = rel:Dot(look)
			if along > 4 and along < 130 then
				local perp = (rel - look * along).Magnitude
				if perp < e.def.size * 1.1 + 0.8 then
					aimer = t.pos
					break
				end
			end
		end
		if aimer then
			L.aimT += dt
		else
			L.aimT = math.max(L.aimT - dt * 0.5, 0)
		end
		local busy = e.act ~= nil and e.act.phase == "active"
		if aimer and L.aimT >= bl.aim and now >= L.blinkAt and not busy then
			L.aimT = 0
			if tryBlink(e, aimer, now) then
				L.blinkAt = now + bl.cooldown
			else
				L.blinkAt = now + 0.8
			end
		end
	end
end

return LumenAI
