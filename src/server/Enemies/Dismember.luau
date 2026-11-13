-- Dismemberment (server). Limb HP per detachable limb (Shared/Data/Limbs), fed by bullet hits and explosions from
-- EnemyService (hook lines in hit() and explode()). When a limb's HP runs out:
--   * the limb part and every part hanging below it in the Motor6D tree get Transparency 1 + CanQuery false
--     (part attrs Lost = true, LostT = original transparency), model attr "Lost_<Part>" = true;
--   * gameplay: move speed multiplier (legs), ranged attack swapped for a melee fallback (weapon arm / spitter head),
--     attack damage weakened (mandibles) or body armour lowered (plates). The enemy gets its own shallow copy of `def`
--     the first time (e.def), so EnemyAI reads the change with no extra hooks;
--   * Fx "Dismember" {id, part, parts, stump, p, v, f, k} to all clients (client/Fx/DismemberFx.luau).
-- Only rigged mesh models (model attr Rigged) lose limbs. Kills skip this (the death break-up handles the body; it only
-- clones visible parts, so hidden limbs are never duplicated).
--
-- API (used by EnemyService):
--   Dismember.init(S)
--   Dismember.onHit(e, part, dmg, ap, zdef, hitPos, source) -> boolean   true when this hit took a limb off
--   Dismember.onExplode(e, pos, radius, core, dmg, ap)                     dmg = pre-falloff damage (kindMult applied)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Damage = require(Shared.Damage)
local EnemyData = require(Shared.Data.Enemies)
local Limbs = require(Shared.Data.Limbs)

local EnemyAI = require(script.Parent.EnemyAI)

local Dismember = {}

local S: { [string]: any } = {}

local EXPLO_MULT = 0.8 -- explosions vs limbs
local MAX_PER_BLAST = 2 -- limbs one explosion may take off one enemy
local MIN_SPEED = 0.3
local RANGED = { bolt = true, burst = true, cannon = true, mortar = true, sweep = true, spit = true }

type Layout = {
	owner: { [string]: number }, -- part name -> limb index (sub-tree aware)
	subtree: { [number]: { string } }, -- limb index -> part names that come off with it
	stump: { [number]: string }, -- limb index -> parent part name (the stump)
}
local layouts: { [string]: Layout } = {}

local function motorParent(part: BasePart): BasePart?
	local m = part:FindFirstChild(part.Name)
	if m and m:IsA("Motor6D") then
		local p0 = m.Part0
		if p0 and p0:IsA("BasePart") then
			return p0
		end
	end
	return nil
end

-- built once per kind from the first rigged model (all rigged models of a kind share the same tree)
local function layoutOf(e: any): Layout?
	local cached = layouts[e.kind]
	if cached then
		return cached
	end
	local list = Limbs.get(e.kind)
	if not list or e.model:GetAttribute("Rigged") ~= true then
		return nil
	end
	local index: { [string]: number } = {}
	for i, l in list do
		index[l.part] = i
	end
	local lay: Layout = { owner = {}, subtree = {}, stump = {} }
	for i in list do
		lay.subtree[i] = {}
	end
	for _, ch in e.model:GetChildren() do
		if ch:IsA("BasePart") then
			local p: BasePart? = ch
			local hops = 0
			while p and hops < 8 do
				local i = index[p.Name]
				if i then
					lay.owner[ch.Name] = i
					table.insert(lay.subtree[i], ch.Name)
					break
				end
				p = motorParent(p)
				hops += 1
			end
		end
	end
	for i, l in list do
		local part = e.model:FindFirstChild(l.part)
		local par = if part and part:IsA("BasePart") then motorParent(part) else nil
		lay.stump[i] = if par then par.Name else "Body"
	end
	layouts[e.kind] = lay
	return lay
end

local function hpScale(e: any): number
	local base = EnemyData.get(e.kind)
	return if base and base.hp > 0 then e.maxHp / base.hp else 1
end

-- the enemy's own copy of def (shared catalogue entries are never mutated)
local function ownDef(e: any): any
	if not e.ownDef then
		local d = table.clone(e.def)
		d.attacks = table.clone(d.attacks)
		d.zones = table.clone(d.zones)
		e.def = d
		e.ownDef = true
	end
	return e.def
end

local function applyEffects(e: any, l: Limbs.Limb)
	local base = EnemyData.get(e.kind)
	if not base then
		return
	end
	if l.speed then
		e.limbSpeed = math.max((e.limbSpeed or 1) * l.speed, MIN_SPEED)
		ownDef(e).speed = base.speed * e.limbSpeed
	end
	if l.disarm and l.melee then
		local def = ownDef(e)
		local m = l.melee
		local swapped = false
		for i, atk in def.attacks do
			if table.find(l.disarm, atk.kind) then
				def.attacks[i] = { kind = "melee", damage = m.damage, range = m.range, cooldown = m.cooldown, windup = m.windup }
				swapped = true
			end
		end
		if swapped then
			local ranged = false
			local melee = math.huge
			for _, atk in def.attacks do
				if RANGED[atk.kind] then
					ranged = true
				elseif atk.kind ~= "charge" and atk.kind ~= "summon" then
					melee = math.min(melee, atk.range)
				end
			end
			if not ranged then
				def.keepDistance = nil -- nothing left to shoot with: close in
				e.stopDist = if melee < math.huge then melee * 0.7 + def.size * 0.6 else def.size * 2
				e.los = true
			end
			if e.act and table.find(l.disarm, e.act.kind) then
				EnemyAI.interrupt(e) -- the arm that was aiming is gone
			end
		end
	end
	if l.weaken then
		local def = ownDef(e)
		for i, atk in def.attacks do
			if atk.kind == l.weaken.kind then
				local a = table.clone(atk)
				a.damage *= l.weaken.mult
				def.attacks[i] = a
			end
		end
	end
	if l.armor then
		local def = ownDef(e)
		local body = table.clone(def.zones.body)
		body.armor = math.min(body.armor, l.armor)
		def.zones.body = body
	end
end

local function detach(e: any, lay: Layout, i: number, vel: Vector3)
	local list = Limbs.get(e.kind)
	local l = list and list[i]
	if not l then
		return
	end
	e.lostLimbs = e.lostLimbs or {}
	e.lostLimbs[i] = true
	local model = e.model
	local main = model:FindFirstChild(l.part)
	if not (main and main:IsA("BasePart")) then
		return
	end
	local names = lay.subtree[i]
	-- Fx first, so the client still sees the parts visible when it clones them
	if S.Fx then
		S.Fx.play("Dismember", {
			id = e.id,
			part = l.part,
			parts = names,
			stump = lay.stump[i],
			p = main.Position,
			v = vel,
			f = e.faction,
			k = e.kind,
		})
	end
	for _, n in names do
		local p = model:FindFirstChild(n)
		if p and p:IsA("BasePart") then
			p:SetAttribute("LostT", p.Transparency)
			p:SetAttribute("Lost", true)
			p.Transparency = 1
			p.CanQuery = false
		end
	end
	model:SetAttribute("Lost_" .. l.part, true)
	applyEffects(e, l)
end

-- Adds limb damage; returns the overflow (>= 0) when the limb is depleted, nil otherwise.
local function damageLimb(e: any, i: number, l: Limbs.Limb, amount: number): number?
	e.limbHp = e.limbHp or {}
	local hp = e.limbHp[i] or l.hp * hpScale(e)
	hp -= amount
	e.limbHp[i] = hp
	if hp <= 0 then
		return -hp
	end
	return nil
end

local function shooterDir(source: any?, at: Vector3): Vector3?
	local p = source and source.player
	if p and S.Players and S.Players.getRoot then
		local root = S.Players.getRoot(p)
		if root then
			local d = at - root.Position
			if d.Magnitude > 0.1 then
				return d.Unit
			end
		end
	end
	return nil
end

function Dismember.onHit(e: any, part: BasePart, dmg: number, ap: number, zdef: any, hitPos: Vector3?, source: any?): boolean
	if not e.alive or not part.Parent then
		return false
	end
	local lay = layoutOf(e)
	if not lay then
		return false
	end
	local i = lay.owner[part.Name]
	if not i or (e.lostLimbs and e.lostLimbs[i]) then
		return false
	end
	local list = Limbs.get(e.kind)
	local l = list and list[i]
	if not l then
		return false
	end
	local amount = Damage.compute(dmg, ap, zdef and zdef.armor or 0, 1)
	if amount <= 0 or not damageLimb(e, i, l, amount) then
		return false
	end
	local dir = shooterDir(source, part.Position)
	if not dir and hitPos then
		local d = part.Position - hitPos
		dir = if d.Magnitude > 0.05 then d.Unit else nil
	end
	dir = dir or Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit
	local flat = Vector3.new(dir.X, 0, dir.Z)
	flat = if flat.Magnitude > 0.05 then flat.Unit else Vector3.xAxis
	detach(e, lay, i, flat * 14 + Vector3.new(0, 12, 0))
	return true
end

function Dismember.onExplode(e: any, pos: Vector3, radius: number, core: number, dmg: number, ap: number)
	if not e.alive or dmg <= 0 then
		return
	end
	local lay = layoutOf(e)
	local list = Limbs.get(e.kind)
	if not lay or not list then
		return
	end
	local popped: { { i: number, over: number, v: Vector3 } } = {}
	for i, l in list do
		if e.lostLimbs and e.lostLimbs[i] then
			continue
		end
		local part = e.model:FindFirstChild(l.part)
		if not (part and part:IsA("BasePart")) then
			continue
		end
		local s = part.Size
		local off = part.Position - pos
		local dist = math.max(off.Magnitude - math.max(s.X, s.Y, s.Z) * 0.5, 0)
		if dist >= radius then
			continue
		end
		local f = Damage.falloff(dist, core, radius)
		local zone = part:GetAttribute("Zone")
		local z = (type(zone) == "string" and e.def.zones[zone]) or e.def.zones.body
		local amount = Damage.compute(dmg * f * EXPLO_MULT, ap, z.armor, 1)
		if amount > 0 then
			local over = damageLimb(e, i, l, amount)
			if over then
				local flat = Vector3.new(off.X, 0, off.Z)
				flat = if flat.Magnitude > 0.05 then flat.Unit else Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit
				table.insert(popped, { i = i, over = over, v = flat * (12 + 22 * f) + Vector3.new(0, 18 + 14 * f, 0) })
			end
		end
	end
	if #popped == 0 then
		return
	end
	table.sort(popped, function(a, b)
		return a.over > b.over
	end)
	for n, pp in popped do
		if n <= MAX_PER_BLAST then
			detach(e, lay, pp.i, pp.v)
		else
			e.limbHp[pp.i] = 1 -- hanging on by a bolt: the next hit takes it
		end
	end
end

function Dismember.init(s: { [string]: any })
	S = s
end

return Dismember
