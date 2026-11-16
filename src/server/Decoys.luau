-- Holo Decoys (call-in DECOY): extra, non-player targets for enemies. State only, no services needed, so EnemyAI, Projectiles and
-- the call-in effect all require it directly.
--
--   Decoys.add(spec) -> decoy      spec = { part, pos, hp, radius, preference }
--   Decoys.list                    live decoys (array). Empty most of the time: every enemy branch that reads it checks Decoys.count().
--   Decoys.count()
--   Decoys.damage(d, amount)       hp -= amount (does nothing once dead)
--   Decoys.damageNear(pos, r, amount, maxDy?)   flat-distance area hit on every live decoy inside r
--   Decoys.remove(d)
--   Decoys.clear()
--
-- decoy = { part: BasePart, pos: Vector3 (chest height), hp, maxHp, radius (studs, enemies inside it prefer the decoy),
--           preference (distance multiplier, 0.4 = "looks 2.5x closer"), alive, hitRadius }
-- The effect owns the model and watches `alive` / `hp`; enemies only ever damage the decoy through Decoys.damage.

local Decoys = {}

export type Decoy = {
	part: BasePart,
	pos: Vector3,
	hp: number,
	maxHp: number,
	radius: number,
	preference: number,
	alive: boolean,
	hitRadius: number,
}

local list: { Decoy } = {}
Decoys.list = list

function Decoys.count(): number
	return #list
end

function Decoys.add(spec: { part: BasePart, pos: Vector3, hp: number, radius: number, preference: number? }): Decoy
	local d: Decoy = {
		part = spec.part,
		pos = spec.pos,
		hp = spec.hp,
		maxHp = spec.hp,
		radius = spec.radius,
		preference = spec.preference or 0.4,
		alive = true,
		hitRadius = 2.2,
	}
	table.insert(list, d)
	return d
end

function Decoys.remove(d: Decoy)
	d.alive = false
	local i = table.find(list, d)
	if i then
		table.remove(list, i)
	end
end

function Decoys.damage(d: Decoy, amount: number)
	if not d.alive then
		return
	end
	d.hp -= math.max(amount, 0)
end

function Decoys.damageNear(pos: Vector3, r: number, amount: number, maxDy: number?)
	for _, d in list do
		if d.alive then
			local dx, dz = d.pos.X - pos.X, d.pos.Z - pos.Z
			if math.sqrt(dx * dx + dz * dz) <= r and math.abs(d.pos.Y - pos.Y) <= (maxDy or 12) then
				Decoys.damage(d, amount)
			end
		end
	end
end

function Decoys.clear()
	for _, d in list do
		d.alive = false
	end
	table.clear(list)
end

return Decoys
