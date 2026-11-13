-- S.Enemies: enemy registry, damage model (zones / armour / fatal zones), statuses and queries.
-- Enemies are anchored Models in workspace.Enemies moved with PivotTo by EnemyAI.
--
-- Beyond docs/architecture.md:
--   S.Enemies.setDifficulty(d)       HP scale from Config.DifficultyHpScale (Director.start calls this)
--   S.Enemies.despawn(enemy)         silent removal (no kill credit, no Death fx)
--   S.Enemies.getById(id)            -> Enemy?
--   S.Enemies.countByClass()         -> {regular=, medium=, heavy=, behemoth=}
--   S.Enemies.kills                  total kills this mission (reset by clear())
--   spawn opts: { dest: Vector3?, home: Vector3?, patrol: boolean?, aggro: boolean?, target: Player?, hpScale: number?, group: any? }
--   explode opts.status entries: number (duration) | { d: number, m: number?, noBehemoth: boolean? }
--   hit() returns result = "none" when the part no longer belongs to a live enemy.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Damage = require(Shared.Damage)
local EnemyData = require(Shared.Data.Enemies)

local EnemyModels = require(script.Parent.EnemyModels)
local EnemyAI = require(script.Parent.EnemyAI)
local Dismember = require(script.Parent.Dismember) -- limb loss (hooks in hit / explode / init)

local EnemyService = {}

local S: { [string]: any } = {}
local enemies: { [number]: any } = {}
local liveCount = 0
local nextId = 0
local difficulty = 1
local conn: RBXScriptConnection? = nil
local folder: Folder? = nil

EnemyService.kills = 0

local SIZE_LETTER = { regular = "S", medium = "M", heavy = "L", behemoth = "XL" }

local function now(): number
	return workspace:GetServerTimeNow()
end

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = workspace:FindFirstChild("Enemies")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Enemies"
		f.Parent = workspace
	end
	folder = f :: Folder
	return folder :: Folder
end

local function ensureConn()
	if conn then
		return
	end
	conn = RunService.Heartbeat:Connect(function(dt)
		EnemyAI.step(dt, enemies)
	end)
end

local function bodyArmor(e: any): number
	return e.def.zones.body.armor
end

-- Spawning --------------------------------------------------------------------------
function EnemyService.setDifficulty(d: number)
	difficulty = math.clamp(math.floor(d or 1), 1, #Config.DifficultyHpScale)
end

function EnemyService.spawn(kindId: string, cf: CFrame, opts: any?)
	local def = EnemyData.get(kindId)
	assert(def, "unknown enemy kind " .. tostring(kindId))
	opts = opts or {}
	nextId += 1
	local id = nextId

	local model, rig = EnemyModels.build(kindId, id)
	local zones: { [string]: { hp: number? } } = {}
	for name, z in def.zones do
		zones[name] = { hp = z.fatal }
	end
	local scale = opts.hpScale or Config.DifficultyHpScale[difficulty] or 1
	local hp = def.hp * scale
	-- fatal zones scale with difficulty too, so eye shots stay proportionate
	for _, z in zones do
		if z.hp then
			z.hp *= scale
		end
	end

	local e: any = {
		id = id,
		kind = kindId,
		def = def,
		model = model,
		root = model.PrimaryPart,
		rig = rig,
		hp = hp,
		maxHp = hp,
		zones = zones,
		faction = def.faction,
		class = def.class,
		status = {},
		alive = true,
		spawnedAt = now(),
	}
	enemies[id] = e
	liveCount += 1

	-- never spawn inside another enemy (patrol groups are laid out by the Director; this catches stacked wave spawns)
	if e.class ~= "behemoth" then
		local p = cf.Position
		for _ = 1, 8 do
			local push: Vector3? = nil
			for _, o in enemies do
				if o ~= e and o.alive and o.pos then
					local d = Vector3.new(p.X - o.pos.X, 0, p.Z - o.pos.Z)
					local need = (def.size + o.def.size) * 0.7 + 0.6
					if d.Magnitude < need then
						local dir = if d.Magnitude > 0.05 then d.Unit else Vector3.new(math.cos(id * 2.399), 0, math.sin(id * 2.399))
						push = dir * (need - d.Magnitude + 0.3)
						break
					end
				end
			end
			if not push then
				break
			end
			p += push
		end
		if p ~= cf.Position then
			cf = CFrame.new(p) * cf.Rotation
		end
	end

	model:PivotTo(cf)
	model.Parent = getFolder()
	EnemyAI.register(e, cf, opts)
	ensureConn()
	return e
end

-- Death ------------------------------------------------------------------------------
local function removeEnemy(e: any)
	if not e.alive then
		return false
	end
	e.alive = false
	if enemies[e.id] then
		enemies[e.id] = nil
		liveCount -= 1
	end
	EnemyAI.unregister(e)
	return true
end

local function kill(e: any, source: any?)
	local center = e.root.Position + Vector3.new(0, e.def.size * 0.7, 0)
	if not removeEnemy(e) then
		return
	end
	EnemyService.kills += 1
	local faction = EnemyData.Factions[e.faction]
	if S.Fx then
		-- dir = which way the killing blow was travelling (clients fling debris / goo along it), by = killer's userId (kill
		-- streak HUD), src = "bullet" | "explosion" | ... (bullet kills already get their cue from HitConfirm)
		local sKind = source and source.kind or "objective"
		S.Fx.play("Death", {
			p = center,
			faction = e.faction,
			class = e.class,
			style = faction and faction.deathStyle or "scrap",
			size = SIZE_LETTER[e.class] or "M",
			kind = e.kind,
			dir = e.lastDir,
			by = if source and source.player then source.player.UserId else nil,
			src = sKind,
			weak = e.lastWeak == true,
			blast = sKind == "explosion" or sKind == "callin" or e.lastBlast == true,
		})
	end
	e.model:Destroy()
	local mission = S.Mission
	if mission and mission.onKill then
		local ok, err = pcall(mission.onKill, e, source or { kind = "objective" })
		if not ok then
			warn("[Enemies] Mission.onKill failed:", err)
		end
	end
end

function EnemyService.despawn(e: any)
	if removeEnemy(e) then
		e.model:Destroy()
	end
end

-- Damage -----------------------------------------------------------------------------
-- Direction the damage travelled (unit, world): from the blast centre, else from the shooter to the hit point.
local function damageDir(e: any, source: any?, hitPos: Vector3?, blastFrom: Vector3?): Vector3?
	local d: Vector3? = nil
	if blastFrom then
		d = (e.root.Position + Vector3.new(0, e.def.size * 0.7, 0)) - blastFrom
	elseif source and source.player and S.Players and S.Players.getRoot then
		local root = S.Players.getRoot(source.player)
		if root then
			d = (hitPos or e.root.Position) - root.Position
		end
	end
	if d and d.Magnitude > 0.05 then
		return d.Unit
	end
	return nil
end

-- Client flinch (EnemyAnim watches HitSeq). Damage taken inside the throttle window is accumulated and flushed in one
-- update, so a gatling does not flood attribute replication and a shotgun volley still reads as ONE hard hit.
--   HitMag     0.35 .. 3.2  flinch strength (sqrt-ish of damage / 30, weak spots x1.4, blasts >= 2.4)
--   HitDir     Vector3      direction the damage travelled
--   HitWeak    bool         weak-spot hit (bigger snap)
--   HitStagger bool         heavy hit: long stagger pose (and a brief slow here so it matters)
local FLINCH_WINDOW = 0.07
local function flushFlinch(e: any)
	e.flinchPending = false
	if not e.alive or not e.model or not e.model.Parent then
		return
	end
	local acc = e.hitAcc or 0
	e.hitAcc = 0
	if acc < 4 then
		return -- burn / gas ticks: no flinch
	end
	e.lastHitFx = os.clock()
	local mag = math.clamp((acc / 30) ^ 0.6, 0.35, 3.2)
	if e.hitWeakAcc then
		mag = math.min(mag * 1.4, 3.6)
	end
	if e.hitBlastAcc then
		mag = math.max(mag, 2.4)
	end
	local stagger = (mag >= 2.1 or (e.hitBlastAcc and acc >= e.maxHp * 0.06)) and e.class ~= "behemoth"
	e.hitSeq = (e.hitSeq or 0) + 1
	local m = e.model
	m:SetAttribute("HitMag", mag)
	if e.lastDir then
		m:SetAttribute("HitDir", e.lastDir)
	end
	m:SetAttribute("HitWeak", e.hitWeakAcc == true)
	m:SetAttribute("HitStagger", stagger)
	m:SetAttribute("HitSeq", e.hitSeq)
	e.hitWeakAcc = nil
	e.hitBlastAcc = nil
	if stagger and EnemyService.applyStatus then
		-- brief slow (not a stun: attacks are not interrupted) so heavy hits visibly stop an advancing enemy
		EnemyService.applyStatus(e, "slow", 0.45, 0.6)
	end
end

-- Subtract hp (+ zone hp); kill on hp <= 0 or fatal zone <= 0. Returns killed.
-- fx = { hitPos: Vector3?, weak: boolean?, blastFrom: Vector3? } feeds the flinch / death direction.
local function inflict(e: any, amount: number, source: any?, zoneName: string?, part: BasePart?, fx: any?): boolean
	if amount > 0 then
		e.hp -= amount
		local z = zoneName and e.zones[zoneName]
		local fatal = false
		if z and z.hp then
			z.hp -= amount
			fatal = z.hp <= 0
		end
		if part then
			EnemyModels.flash(part)
		end
		local dir = damageDir(e, source, fx and fx.hitPos, fx and fx.blastFrom)
		if dir then
			e.lastDir = dir
		end
		e.lastWeak = fx and fx.weak == true
		e.lastBlast = fx and fx.blastFrom ~= nil
		e.hitAcc = (e.hitAcc or 0) + amount
		if fx and fx.weak then
			e.hitWeakAcc = true
		end
		if fx and fx.blastFrom then
			e.hitBlastAcc = true
		end
		local clock = os.clock()
		if clock - (e.lastHitFx or 0) > FLINCH_WINDOW then
			flushFlinch(e)
		elseif not e.flinchPending then
			e.flinchPending = true
			task.delay(FLINCH_WINDOW - (clock - (e.lastHitFx or 0)) + 0.005, flushFlinch, e)
		end
		if source and source.player then
			e.lastHitBy = source.player
			e.alerted = true
		else
			e.alerted = true
		end
		if e.hp <= 0 or fatal then
			kill(e, source)
			return true
		end
	end
	return false
end

local function resolveZone(e: any, zoneName: string?): (string, any)
	local name = zoneName or "body"
	local z = e.def.zones[name]
	if not z then
		name = "body"
		z = e.def.zones.body
	end
	-- EMP / stun knocks out riot shields
	if z.blocks and name == "shield" and e.status.stun then
		return "body", e.def.zones.body
	end
	return name, z
end

function EnemyService.hit(part: BasePart, dmg: number, ap: number, source: any?, hitPos: Vector3?)
	local id = part:GetAttribute("EnemyId")
	local e = id and enemies[id]
	if not e or not e.alive then
		return { result = "none", dealt = 0, killed = false, weak = false }
	end
	local zoneName, zdef = resolveZone(e, part:GetAttribute("Zone"))
	local dealt, result = Damage.compute(dmg, ap, zdef.armor, zdef.mult)
	if zdef.blocks and result == "pen" and dealt <= 0 then
		result = "partial" -- absorbed by the plate
	end
	local killed = false
	local isWeak = zdef.mult >= 2 and result ~= "deflect"
	if dealt > 0 then
		killed = inflict(e, dealt, source, zoneName, part, { hitPos = hitPos, weak = isWeak })
	end
	-- dismemberment hook (Dismember.luau): limb HP; true when this hit took a limb off
	local limb = not killed and Dismember.onHit(e, part, dmg, ap, zdef, hitPos, source)
	return {
		result = result,
		dealt = dealt,
		killed = killed,
		weak = zdef.mult >= 2 and result ~= "deflect",
		limb = limb == true,
	}
end

-- Direct damage ignoring block zones (lance, gas, burn). zone defaults to "body".
function EnemyService.damage(e: any, dmg: number, ap: number, source: any?, zone: string?)
	if not e or not e.alive then
		return { result = "none", dealt = 0, killed = false, weak = false }
	end
	local zoneName = zone or "body"
	local zdef = e.def.zones[zoneName] or e.def.zones.body
	if not e.def.zones[zoneName] then
		zoneName = "body"
	end
	local dealt, result = Damage.compute(dmg, ap, zdef.armor, zdef.mult)
	local killed = false
	if dealt > 0 then
		killed = inflict(e, dealt, source, zoneName, nil)
	end
	return { result = result, dealt = dealt, killed = killed, weak = zdef.mult >= 2 and result ~= "deflect" }
end

-- Statuses ---------------------------------------------------------------------------
function EnemyService.applyStatus(e: any, name: string, duration: number, magnitude: number?, source: any?)
	if not e or not e.alive then
		return
	end
	local d = duration
	if e.class == "behemoth" then
		d *= 0.5
	end
	local untilT = now() + d
	local cur = e.status[name]
	if cur and cur.untilT > untilT then
		cur.mag = math.max(cur.mag or 0, magnitude or 0)
		return
	end
	e.status[name] = { untilT = untilT, mag = magnitude, source = source }
	if name == "stun" then
		EnemyAI.interrupt(e)
	end
end

-- Queries ----------------------------------------------------------------------------
local function centerOf(e: any): Vector3
	return e.root.Position + Vector3.new(0, e.def.size * 0.8, 0)
end

function EnemyService.getInRadius(pos: Vector3, r: number): { any }
	local out = {}
	for _, e in enemies do
		local d = (centerOf(e) - pos).Magnitude - e.def.size * 0.8
		if d <= r then
			table.insert(out, e)
		end
	end
	return out
end

function EnemyService.getAll(): { any }
	local out = {}
	for _, e in enemies do
		table.insert(out, e)
	end
	return out
end

function EnemyService.getById(id: number): any?
	return enemies[id]
end

function EnemyService.count(): number
	return liveCount
end

function EnemyService.countByClass(): { [string]: number }
	local c = { regular = 0, medium = 0, heavy = 0, behemoth = 0 }
	for _, e in enemies do
		c[e.class] += 1
	end
	return c
end

-- Explosions -------------------------------------------------------------------------
function EnemyService.explode(pos: Vector3, radius: number, core: number, dmg: number, ap: number, source: any?, opts: any?)
	opts = opts or {}
	if S.Objectives and S.Objectives.onExplosion then
		pcall(S.Objectives.onExplosion, pos, radius)
	end
	local killedCount = 0
	local snapshot = {}
	for _, e in enemies do
		table.insert(snapshot, e)
	end
	for _, e in snapshot do
		if e.alive then
			local dist = math.max((centerOf(e) - pos).Magnitude - e.def.size * 0.8, 0)
			if dist < radius then
				local f = Damage.falloff(dist, core, radius)
				if dmg > 0 and f > 0 then
					local d = dmg * f
					if opts.kindMult then
						d *= opts.kindMult[e.faction] or 1
					end
					local dealt = Damage.compute(d, ap, bodyArmor(e), 1)
					if dealt > 0 then
						if inflict(e, dealt, source, "body", nil, { blastFrom = pos }) then
							killedCount += 1
						end
					end
					-- dismemberment hook (Dismember.luau): blast vs each limb, own falloff per limb
					if e.alive then
						Dismember.onExplode(e, pos, radius, core, dmg * (if opts.kindMult then opts.kindMult[e.faction] or 1 else 1), ap)
					end
				end
				if e.alive and opts.status then
					for name, v in opts.status do
						if type(v) == "number" then
							EnemyService.applyStatus(e, name, v, nil, source)
						elseif type(v) == "table" then
							if not (v.noBehemoth and e.class == "behemoth") then
								EnemyService.applyStatus(e, name, v.d or 3, v.m, source)
							end
						end
					end
				end
			end
		end
	end

	-- players: knock only (damage only with friendly fire)
	local players = S.Players
	if players and players.getAlive then
		for _, p in players.getAlive() do
			local root = players.getRoot(p)
			if root then
				local dist = (root.Position - pos).Magnitude
				if dist < radius then
					local f = Damage.falloff(dist, core, radius)
					if players.knock and f > 0 then
						players.knock(p, pos, 25 + 45 * f)
					end
					if Config.FriendlyFire and dmg > 0 and source and source.player and f > 0 then
						players.damage(p, dmg * f * 0.5, pos, { kind = "friendly" })
					end
				end
			end
		end
	end
	return { killed = killedCount }
end

-- Lifecycle --------------------------------------------------------------------------
function EnemyService.clear()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	for _, e in enemies do
		e.alive = false
		EnemyAI.unregister(e)
		if e.model then
			e.model:Destroy()
		end
	end
	table.clear(enemies)
	liveCount = 0
	EnemyService.kills = 0
	EnemyAI.clear()
	if S.Projectiles and S.Projectiles.clear then
		S.Projectiles.clear()
	end
	local f = workspace:FindFirstChild("Enemies")
	if f then
		f:ClearAllChildren()
	end
end

function EnemyService.init(s: { [string]: any })
	S = s
	getFolder()
	EnemyAI.init(s)
	Dismember.init(s) -- dismemberment
end

function EnemyService.start()
	if liveCount > 0 then
		ensureConn()
	end
end

return EnemyService
