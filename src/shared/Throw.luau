--!strict
-- Throw ballistics shared by the server (CallInService beacon throw, WeaponService grenades) and the client throw arc
-- (client/ThrowArc), so the predicted path is the one the server launches.
local Config = require(script.Parent.Config)

local Throw = {}

Throw.BEACON_MAX_RANGE = 45 -- beacons land at most this far from the root
Throw.BEACON_GRAVITY_SCALE = 0.35 -- beacons fly on a floaty arc (a VectorForce cancels the rest of gravity)
Throw.GRENADE_SPEED = 55 -- horizontal studs/s
Throw.GRENADE_MIN = 4 -- flat throw distance clamp
Throw.GRENADE_MAX = 40

export type Launch = {
	origin: Vector3, -- where the projectile starts
	velocity: Vector3, -- launch velocity
	gravity: number, -- effective downward acceleration (studs/s^2)
	dirFlat: Vector3, -- flat throw direction (unit)
	time: number?, -- beacon: planned flight time to `target`
	target: Vector3?, -- beacon: planned landing point
}

-- Beacon: aims straight at the clamped aim point, arriving after T seconds.
-- rootPos / look: HumanoidRootPart position and LookVector; handPos: right hand (nil -> above the root).
function Throw.beacon(rootPos: Vector3, look: Vector3, handPos: Vector3?, aim: Vector3, worldGravity: number): Launch
	local delta = aim - rootPos
	if delta.Magnitude > Throw.BEACON_MAX_RANGE then
		delta = delta.Unit * Throw.BEACON_MAX_RANGE
	end
	local target = rootPos + delta
	local dirFlat = Vector3.new(delta.X, 0, delta.Z)
	if dirFlat.Magnitude < 0.1 then
		dirFlat = Vector3.new(look.X, 0, look.Z)
		if dirFlat.Magnitude < 0.1 then
			dirFlat = Vector3.zAxis
		end
	end
	dirFlat = dirFlat.Unit
	local origin = (handPos or (rootPos + Vector3.new(0, 2, 0))) + dirFlat * 1.2
	local g = worldGravity * Throw.BEACON_GRAVITY_SCALE
	local toTarget = target - origin
	local T = math.clamp(toTarget.Magnitude / math.max(Config.BeaconThrowSpeed, 1), 0.2, 1.2)
	local v0 = toTarget / T + Vector3.new(0, 0.5 * g * T, 0)
	return { origin = origin, velocity = v0, gravity = g, dirFlat = dirFlat, time = T, target = target }
end

-- Grenade: fixed horizontal speed, vertical speed solved for the aim height (clamped). origin = Aim.origin(character).
function Throw.grenade(origin: Vector3, aim: Vector3, worldGravity: number): Launch
	local d = aim - origin
	local startPos = origin + (if d.Magnitude > 0.01 then d.Unit else Vector3.zero) * 2
	local flat = Vector3.new(d.X, 0, d.Z)
	local dist = math.clamp(flat.Magnitude, Throw.GRENADE_MIN, Throw.GRENADE_MAX)
	local speed = Throw.GRENADE_SPEED
	local tFlight = dist / speed
	local vy = (d.Y + 0.5 * worldGravity * tFlight * tFlight) / tFlight
	vy = math.clamp(vy, -10, 60)
	local dirFlat = if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, -1)
	return { origin = startPos, velocity = dirFlat * speed + Vector3.new(0, vy, 0), gravity = worldGravity, dirFlat = dirFlat }
end

-- Position along a launch after t seconds.
function Throw.at(l: Launch, t: number): Vector3
	return l.origin + l.velocity * t - Vector3.new(0, 0.5 * l.gravity * t * t, 0)
end

return Throw
