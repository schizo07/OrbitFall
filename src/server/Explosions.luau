-- S.Explosions: one entry point for player-made explosions (grenades, launcher rounds, bomb / strafe / cluster / barrage
-- call-ins, mines). Footage pass 2026-11-14.
--
--   Explosions.blast(pos, spec, source) -> { killed = n }
--     1. damage: S.Enemies.explode(pos, radius, core, damage, ap, source, { noPlayerKnock = true })
--        (+ a second core-only explode when spec.coreDamage is set: the Half-Ton's armour-ignoring centre)
--     2. troopers: knockdown / shove out to radius * Blasts.KnockRadiusMult, no damage unless Config.FriendlyFire
--     3. client effect: Fx "Blast" (client/Fx/Blast.luau), sized by spec.vis
--     4. listeners: every onBlast fn gets the BlastInfo below
--   spec: radius, core, damage, ap, size ("S"|"M"|"L"|"XL"), style ("fire"|"emp"|...), vis, knock, power, shake,
--         shakeRadius, coreDamage?, coreAp?, legacy? = { shake, shakeR, shockwave, crater } (replayed only by the
--         "Current" explosion look in Studio A/B), noDamage? (effect + knock only), skipPlayer? (a Player never
--         knocked by this blast, e.g. the trooper inside a landing drop pod), noEmit? (skip onBlast listeners: enemy
--         shells must not stagger their own side), noFx? (skip Blast fx), playerDamage? (enemy blast dmg to players),
--         playerKind? (damage kind for playerDamage)
--   Troopers in god mode (S.Players.isGod, God/GodMode attrs, ArenaGod/QuickStartGod) are never knocked or damaged.
--   S.Explosions.playerFalloff(dist, core, radius) -> splash share for troopers (steeper than Damage.falloff)
--
-- Listener API (for enemy stagger / fling):
--   local off = S.Explosions.onBlast(function(info: BlastInfo) ... end)   -- returns a disconnect function
--   info = { pos: Vector3, radius: number, core: number, power: number, damage: number, ap: number,
--            size: string, style: string, id: string?, source: any?, time: number }
--   S.Explosions.powerAt(info, at) -> number   power at a point: power inside core, falling to power * Blasts.KnockEdge
--                                              at radius * Blasts.KnockRadiusMult, 0 beyond
--   S.Explosions.emit(info)                    notify listeners about a blast made elsewhere (no damage, no fx)
-- Listeners run after the damage pass (so `e.alive` is already settled), each in pcall.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Damage = require(Shared:WaitForChild("Damage"))
local Blasts = require(Shared:WaitForChild("Data"):WaitForChild("Blasts"))
local CallInData = require(Shared:WaitForChild("Data"):WaitForChild("CallIns"))

local Explosions = {}
local S: any = nil

-- Cryo Bomb shatter: enemies whose model FrozenUntil (server time) lies ahead take this multiple of bullet / blast
-- damage (bonus applied here for blasts, in WeaponService for bullets).
local cryoDef = CallInData.get("CRYO")
local SHATTER = cryoDef and cryoDef.params.shatter or 2
local SHATTER_FX_CAP = 6 -- "Shatter" effects sent per blast

function Explosions.frozenMult(e: any): number
	local m = e and e.model
	local fu = m and m:GetAttribute("FrozenUntil")
	if type(fu) == "number" and fu > workspace:GetServerTimeNow() then
		return SHATTER
	end
	return 1
end

export type BlastInfo = {
	pos: Vector3,
	radius: number,
	core: number,
	power: number,
	damage: number,
	ap: number,
	size: string,
	style: string,
	id: string?,
	source: any?,
	time: number,
}

local listeners: { (BlastInfo) -> () } = {}

function Explosions.init(s)
	S = s
end

local function services()
	if not S then
		S = require(script.Parent:WaitForChild("Services"))
	end
	return S
end

function Explosions.onBlast(fn: (BlastInfo) -> ()): () -> ()
	table.insert(listeners, fn)
	return function()
		local i = table.find(listeners, fn)
		if i then
			table.remove(listeners, i)
		end
	end
end

function Explosions.emit(info: BlastInfo)
	for _, fn in table.clone(listeners) do
		local ok, err = pcall(fn, info)
		if not ok then
			warn("[Explosions] listener failed:", err)
		end
	end
end

-- linear knock / power falloff: full inside core, Blasts.KnockEdge at the knock edge, 0 beyond it
local function knockFrac(dist: number, core: number, radius: number): number
	local kr = radius * Blasts.KnockRadiusMult
	if dist >= kr then
		return 0
	end
	if dist <= core then
		return 1
	end
	local u = (dist - core) / math.max(kr - core, 0.001)
	return 1 - (1 - Blasts.KnockEdge) * u
end

function Explosions.powerAt(info: BlastInfo, at: Vector3): number
	return info.power * knockFrac((at - info.pos).Magnitude, info.core, info.radius)
end

-- Splash damage share for troopers. Enemies use Damage.falloff (soft: 1 -> 0.45 on a u^1.5 curve); troopers keep a
-- steeper linear 1 -> PLAYER_EDGE so the edge of a mortar / cannon ring stays survivable.
-- Studio A/B: Feel_PlayerSplash (Variants group "PLAYER SPLASH"): nil = steep, "enemy" = same curve as enemies.
local PLAYER_EDGE = 0.2
local IS_STUDIO = game:GetService("RunService"):IsStudio()
local ws: any = workspace
function Explosions.playerFalloff(dist: number, core: number, radius: number): number
	if IS_STUDIO and ws:GetAttribute("Feel_PlayerSplash") == "enemy" then
		return Damage.falloff(dist, core, radius)
	end
	if dist <= core then
		return 1
	end
	if dist >= radius then
		return 0
	end
	local u = (dist - core) / math.max(radius - core, 0.001)
	return 1 - (1 - PLAYER_EDGE) * u
end

local function isGod(players: any, p: any): boolean
	if players.isGod and players.isGod(p) then
		return true
	end
	if p:GetAttribute("God") == true or p:GetAttribute("GodMode") == true then
		return true
	end
	local ch = p.Character
	if ch and (ch:GetAttribute("God") == true or ch:GetAttribute("GodMode") == true) then
		return true
	end
	if ws:GetAttribute("ArenaGod") == true or ws:GetAttribute("QuickStartGod") == true then
		return true
	end
	return false
end

-- Troopers: knockdown (heavy) or shove (light), plus enemy/friendly splash damage when enabled.
local rng = Random.new()
local function knockPlayers(pos: Vector3, spec: any, source: any?)
	local s = services()
	local players = s.Players
	if not players or not players.getAlive then
		return
	end
	local knock = spec.knock or 0
	local radius, core = spec.radius, spec.core
	local playerDamage = spec.playerDamage or 0
	local threshold = Config.Move.KnockdownSpeed
	for _, p in players.getAlive() do
		local root = players.getRoot(p)
		if not root or p == spec.skipPlayer then
			continue
		end
		local d = root.Position - pos
		local dist = d.Magnitude
		local god = isGod(players, p)
		if knock > 0 and not god then
			local f = knockFrac(dist, core, radius)
			if f > 0 then
				local flat = Vector3.new(d.X, 0, d.Z)
				local dir = if flat.Magnitude > 0.3
					then flat.Unit
					else Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)).Unit
				local speed = knock * f
				local v = dir * speed + Vector3.new(0, speed * Blasts.KnockLift, 0)
				local m = v.Magnitude
				if m >= threshold then
					s.Fx.to(p, "Knockdown", { v = v, t = Blasts.downTime(m, threshold), from = pos })
				elseif m > 8 then
					s.Fx.to(p, "Knock", { v = v })
				end
			end
		end
		if dist < radius and players.damage and not god then
			if playerDamage > 0 then
				local f = Explosions.playerFalloff(dist, core, radius)
				if f > 0 then
					players.damage(p, playerDamage * f, pos, { kind = spec.playerKind or "enemy" })
				end
			elseif Config.FriendlyFire and (spec.damage or 0) > 0 and source and source.player then
				local f = Explosions.playerFalloff(dist, core, radius)
				if f > 0 then
					players.damage(p, spec.damage * f * 0.5, pos, { kind = "friendly" })
				end
			end
		end
	end
end

local SIZE_POWER = { S = 50, M = 75, L = 90, XL = 130 }

function Explosions.blast(pos: Vector3, spec: any, source: any?): { killed: number }
	local s = services()
	local radius = spec.radius or 6
	local core = math.min(spec.core or radius * 0.3, radius)
	local damage = spec.damage or 0
	local ap = spec.ap or 0
	local size = spec.size or "M"
	local style = spec.style or "fire"
	local killed = 0

	-- 1. damage (frozen enemies are listed first: the main pass may kill or move them)
	local frozen: { { e: any, f: number } } = {}
	if not spec.noDamage and damage > 0 and s.Enemies and s.Enemies.getInRadius then
		for _, e in s.Enemies.getInRadius(pos, radius) do
			if e.alive and e.root and Explosions.frozenMult(e) > 1 then
				table.insert(frozen, { e = e, f = Damage.falloff((e.root.Position - pos).Magnitude, core, radius) })
			end
		end
	end
	if not spec.noDamage and s.Enemies and s.Enemies.explode then
		local ok, res = pcall(s.Enemies.explode, pos, radius, core, damage, ap, source, { noPlayerKnock = true })
		if ok and type(res) == "table" then
			killed += res.killed or 0
		elseif not ok then
			warn("[Explosions] explode failed:", res)
		end
		if spec.coreDamage then
			local ok2, res2 = pcall(s.Enemies.explode, pos, core, core, spec.coreDamage, spec.coreAp or ap, source, { noPlayerKnock = true })
			if ok2 and type(res2) == "table" then
				killed += res2.killed or 0
			end
		end
	end

	-- 1b. shatter bonus on enemies that were frozen when the blast hit
	local sent = 0
	for _, fr in frozen do
		local e = fr.e
		if e.alive and fr.f > 0 then
			local bonus = damage * fr.f * (SHATTER - 1)
			local ok, res = pcall(s.Enemies.damage, e, bonus, ap, source, "body")
			if ok and type(res) == "table" and res.killed then
				killed += 1
			end
			if sent < SHATTER_FX_CAP and e.root then
				sent += 1
				s.Fx.play("Shatter", { p = e.root.Position })
			end
		end
	end

	-- 2. troopers
	knockPlayers(pos, {
		radius = radius,
		core = core,
		knock = spec.knock or 0,
		damage = damage,
		playerDamage = spec.playerDamage,
		playerKind = spec.playerKind,
		skipPlayer = spec.skipPlayer,
	}, source)

	-- 3. client effect
	if not spec.noFx then
		local lg = spec.legacy or {}
		s.Fx.play("Blast", {
			p = pos,
			r = radius,
			size = size,
			style = style,
			k = spec.vis,
			sh = spec.shake,
			shr = spec.shakeRadius,
			sk = lg.shake,
			skr = lg.shakeR,
			sw = lg.shockwave,
			cr = lg.crater,
		})
	end

	-- 3b. world hazards (shootable COG fuel barrels chain-detonate from any nearby explosion, enemy shells included)
	if s.Hazards and s.Hazards.onBlast then
		pcall(s.Hazards.onBlast, pos, radius, source)
	end

	-- 4. listeners
	if #listeners > 0 and not spec.noEmit then
		Explosions.emit({
			pos = pos,
			radius = radius,
			core = core,
			power = spec.power or (if (spec.knock or 0) > 0 then spec.knock else SIZE_POWER[size] or 75),
			damage = damage + (spec.coreDamage or 0),
			ap = ap,
			size = size,
			style = style,
			id = source and source.id or nil,
			source = source,
			time = os.clock(),
		})
	end
	return { killed = killed }
end

return Explosions
